import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/services/lifecycle_intent.dart';
import 'package:fl_clash/services/settings/settings_contract.dart';
import 'package:fl_clash/services/settings/settings_runtime.dart';
import 'package:fl_clash/services/backup/restore_service.dart';
import 'package:fl_clash/services/backup/backup_file_guard.dart';
import 'package:fl_clash/services/backup/unified_backup_service.dart';
import 'package:fl_clash/services/mihomo_config/source_config.dart';
import 'package:fl_clash/services/mihomo_config/runtime_config_commit.dart';
import 'package:fl_clash/services/profile_source_mutation.dart';
import 'package:fl_clash/services/providers/provider_readiness_service.dart';
import 'package:fl_clash/services/unified_backup_export/exporter.dart';
import 'package:fl_clash/services/unified_backup_export/models.dart';
import 'package:fl_clash/services/unified_backup_export/profile_materializer.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/dialog.dart';
import 'package:fl_clash/widgets/input.dart';
import 'package:fl_clash/widgets/surge/surge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:yaml/yaml.dart';

part 'generated/action.g.dart';

/// Real-time traffic speed for speed text display.
/// Updated every 1s. Separate from [trafficsProvider] (chart data, 2-3s).
final currentSpeedNotifier = ValueNotifier<Traffic>(const Traffic());

@visibleForTesting
Future<void> runAutoProfileRefreshLoop({
  required Iterable<Profile> capturedProfiles,
  required Future<void> Function(Profile profile) refresh,
  required void Function(Object error) onError,
}) async {
  for (final profile in capturedProfiles) {
    if (!profile.autoUpdate) continue;
    final isNotNeedUpdate = profile.lastUpdateDate
        ?.add(profile.autoUpdateDuration)
        .isBeforeNow;
    if (isNotNeedUpdate == false || profile.type == ProfileType.file) {
      continue;
    }
    try {
      await refresh(profile);
    } catch (error) {
      onError(error);
    }
  }
}

@visibleForTesting
Future<void> runAuthoritativeProfileDelete({
  required Future<void> Function() commitDatabaseDelete,
  required void Function() applyCommittedProjection,
  required FutureOr<void> Function() updateDesiredProfile,
  required Future<void> Function() cleanupResources,
}) async {
  await commitDatabaseDelete();
  applyCommittedProjection();
  await updateDesiredProfile();
  await cleanupResources();
}

@visibleForTesting
Future<void> convergeDesiredProfileAfterDelete({
  required int deletedProfileId,
  required int? currentProfileId,
  required List<Profile> remainingProfiles,
  required void Function(int? profileId) setCurrentProfileId,
  required Future<void> Function() stopLastProfile,
}) async {
  if (currentProfileId != deletedProfileId) return;
  if (remainingProfiles.isNotEmpty) {
    setCurrentProfileId(remainingProfiles.first.id);
    return;
  }
  setCurrentProfileId(null);
  await stopLastProfile();
}

final class ProfileResourceCleanupException implements Exception {
  const ProfileResourceCleanupException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class RuntimeConfigPostUpdateContext {
  const RuntimeConfigPostUpdateContext({
    required this.lease,
    required this.targetProfile,
  });

  final RuntimeConfigCommitLease lease;
  final Profile? targetProfile;

  int? get targetProfileId => targetProfile?.id;
}

@visibleForTesting
Future<bool> fetchAndPublishRuntimeProjection<T>({
  required int targetProfileId,
  required int? Function() currentProfileId,
  required Future<T> Function() fetch,
  required void Function(T value) publish,
}) async {
  if (currentProfileId() != targetProfileId) return false;
  final value = await fetch();
  if (currentProfileId() != targetProfileId) return false;
  publish(value);
  return true;
}

@visibleForTesting
Future<bool> warmUpRuntimeDelaysForProfile({
  required int targetProfileId,
  required int? Function() currentProfileId,
  required Future<void> Function(void Function(Delay delay) onDelay) warmUp,
  required void Function(Delay delay) publish,
}) async {
  if (currentProfileId() != targetProfileId) return false;
  await warmUp((delay) {
    if (currentProfileId() == targetProfileId) {
      publish(delay);
    }
  });
  return currentProfileId() == targetProfileId;
}

@visibleForTesting
void scheduleRuntimeProjectionRefresh({
  required Debouncer scheduler,
  required Object tag,
  required int? expectedProfileId,
  required int? Function() currentProfileId,
  required void Function() refresh,
  Duration? duration,
}) {
  scheduler.call(tag, () {
    if (expectedProfileId != null && currentProfileId() != expectedProfileId) {
      return;
    }
    refresh();
  }, duration: duration);
}

class BackupRestoreOutcome {
  const BackupRestoreOutcome({
    required this.committed,
    required this.activationSucceeded,
    this.activationError,
    this.providerReadinessStatus,
  });

  final bool committed;
  final bool activationSucceeded;
  final String? activationError;
  final ProviderReadinessStatus? providerReadinessStatus;
}

Future<BackupRestoreOutcome> activateCommittedRestore({
  required Future<bool> Function() applyProfile,
  required Future<void> Function() updateGroups,
}) async {
  try {
    if (!await applyProfile()) {
      return const BackupRestoreOutcome(
        committed: true,
        activationSucceeded: false,
        activationError: 'The proxy core rejected the restored profile',
      );
    }
    await updateGroups();
    return const BackupRestoreOutcome(
      committed: true,
      activationSucceeded: true,
    );
  } catch (_) {
    return const BackupRestoreOutcome(
      committed: true,
      activationSucceeded: false,
      activationError: 'The proxy core could not reload the restored profile',
    );
  }
}

/// Source import needs a usable core, but must not start a VPN session.
Future<T> runProfileSourceWithReadyCore<T>({
  required Future<bool> Function() ensureReady,
  required Future<T> Function() operation,
}) async {
  if (!await ensureReady()) {
    throw StateError('Proxy core initialization failed. Please retry.');
  }
  return operation();
}

Future<bool> ensureRestoreValidationCoreReady({
  required bool isConnected,
  required Future<bool> Function() connectCore,
  required Future<bool> Function() isCoreInitialized,
  required Future<bool> Function() initializeCore,
}) async {
  if (!isConnected && !await connectCore()) return false;
  if (await isCoreInitialized()) return true;
  return initializeCore();
}

bool shouldFullSetupOnInit({required bool isRunning, required bool autoRun}) {
  return isRunning || autoRun;
}

bool shouldClearTaskRemovalStop({
  required bool isStart,
  required bool isInit,
}) {
  return isStart && !isInit;
}

bool sessionRequiresFullSetup(String? sessionState) {
  return sessionState == 'RUNNING' || sessionState == 'STARTING';
}

bool shouldSkipConnectMinDelay(String? sessionState) {
  return sessionState == 'RUNNING';
}

bool shouldDeferInitCoreGroups(String? sessionState) {
  return sessionState == 'RUNNING';
}

@visibleForTesting
bool shouldInitCoreForceApply({
  required bool wasInitialized,
  required bool deferGroupSetup,
  required bool callerOwnsProfileActivation,
  required bool hasCurrentProfile,
  required bool groupsNeedRefresh,
}) {
  if (deferGroupSetup || callerOwnsProfileActivation || !hasCurrentProfile) {
    return false;
  }
  return !wasInitialized || groupsNeedRefresh;
}

bool shouldRestoreSmartPaused(
  String? sessionState, {
  bool smartPaused = false,
}) {
  return sessionState == 'PAUSED' || smartPaused;
}

/// PAUSED reopen must bind/init Flutter Core without starting VPN or applyProfile.
bool shouldAttachCoreWithoutVpnSetup(String? sessionState) {
  return sessionState == 'PAUSED';
}

/// Binder death from Android ServiceConnection / ServiceDelegate, not a VPN error.
@visibleForTesting
bool isRemoteServiceDisconnectMessage(String message) {
  final text = message.trim();
  if (text.isEmpty) return true;
  return text == 'Service disconnected' ||
      text == 'Service binding ended unexpectedly' ||
      text == 'Binder empty' ||
      text.startsWith('Binder is not of type ') ||
      text.startsWith('Failed to link to death');
}

/// This APK already has a session the user would notice disappearing.
@visibleForTesting
bool hasProtectableVpnSession({
  required bool vpnUiRunning,
  required bool smartPaused,
  String? nativeSession,
}) {
  if (vpnUiRunning || smartPaused) return true;
  return switch (nativeSession) {
    'RUNNING' || 'PAUSED' || 'STARTING' || 'STOPPING' => true,
    _ => false,
  };
}

/// Idle preload may bind `:remote` without a VPN. Losing that binder is noise.
@visibleForTesting
bool shouldNotifyRemoteServiceLoss({
  required String message,
  required bool hasSession,
}) {
  if (message.trim().isEmpty) return false;
  if (hasSession) return true;
  return !isRemoteServiceDisconnectMessage(message);
}

bool shouldHandleCoreCrash({
  required bool coreConnected,
  required bool hasProtectableSession,
}) {
  return coreConnected || hasProtectableSession;
}

bool shouldNotifyCoreCrash({
  required bool hasProtectableSession,
  required bool appResumed,
  required String message,
}) {
  return hasProtectableSession &&
      appResumed &&
      message.trim().isNotEmpty;
}

/// After native smartResume, startListener only when Core is already attached.
bool shouldStartListenerAfterSmartResume({
  required bool suspend,
  required bool coreReady,
}) {
  return !suspend && coreReady;
}

enum NativeSessionUiState { running, paused, stopped, pending }

@visibleForTesting
bool setupOutcomeConfirmsRuntimeActivation(SetupConfigOutcome outcome) {
  return outcome == SetupConfigOutcome.applied ||
      outcome == SetupConfigOutcome.unchanged;
}

NativeSessionUiState nativeSessionUiStateFor(String? sessionState) {
  return switch (sessionState) {
    'RUNNING' => NativeSessionUiState.running,
    'PAUSED' => NativeSessionUiState.paused,
    'STOPPED' => NativeSessionUiState.stopped,
    _ => NativeSessionUiState.pending,
  };
}

void convergeFullStopProviders({
  required void Function() clearManualOverride,
  required void Function() clearSmartStopped,
}) {
  clearManualOverride();
  clearSmartStopped();
}

/// User-tap start uses the same applyProfile → TUN order as init.
/// Differences: silence loading, stop VPN if apply/start fails, and do not seed runTime at 0.
({bool silence, bool stopOnFailure, bool seedRunTimeAtZero}) vpnStartPolicy({
  required bool isInit,
}) {
  return (silence: !isInit, stopOnFailure: !isInit, seedRunTimeAtZero: isInit);
}

bool shouldReconnectCoreOnResume({
  required bool isAndroid,
  required bool isRunning,
  required bool hasGroups,
}) {
  return isAndroid && (isRunning || !hasGroups);
}

bool hasExternalProviderDefinitions(ClashConfig config) {
  return config.proxyProviders.isNotEmpty || config.ruleProviders.isNotEmpty;
}

({bool external, bool proxy}) parseProfileProviderDefinitions(String source) {
  final document = loadYaml(source);
  if (document is! YamlMap) return (external: false, proxy: false);

  bool hasEntries(String key) {
    final value = document[key];
    return value is Map && value.isNotEmpty;
  }

  final proxy = hasEntries('proxy-providers');
  final rule = hasEntries('rule-providers');
  return (external: proxy || rule, proxy: proxy);
}

String _profileBytesFingerprint(Uint8List bytes) => sha256.convert(bytes).toString();

Future<({bool external, bool proxy})> readProfileProviderDefinitions(
  int profileId,
) async {
  final profilePath = await appPath.getProfilePath(profileId.toString());
  final source = await File(profilePath).readAsString();
  return compute(parseProfileProviderDefinitions, source);
}

@Riverpod(keepAlive: true)
class CommonAction extends _$CommonAction {
  @override
  void build() {}

  void updateStart() {
    ref
        .read(setupActionProvider.notifier)
        .updateStatus(!ref.read(isStartProvider));
  }

  void updateSpeedStatistics() {
    ref
        .read(appSettingProvider.notifier)
        .update((state) => state.copyWith(showTrayTitle: !state.showTrayTitle));
  }

  void updateMode() {
    ref.read(patchClashConfigProvider.notifier).update((state) {
      final index = Mode.values.indexWhere((item) => item == state.mode);
      if (index == -1) return state;
      final nextIndex = index + 1 > Mode.values.length - 1 ? 0 : index + 1;
      return state.copyWith(mode: Mode.values[nextIndex]);
    });
  }

  void updateRunTime() {
    final startTime = ref.read(setupActionProvider.notifier).startTime;
    if (startTime != null) {
      final startTimeStamp = startTime.millisecondsSinceEpoch;
      final nowTimeStamp = DateTime.now().millisecondsSinceEpoch;
      ref.read(runTimeProvider.notifier).value = nowTimeStamp - startTimeStamp;
    } else {
      ref.read(runTimeProvider.notifier).value = null;
    }
  }

  Future<void> updateTraffic() async {
    final onlyStatisticsProxy = ref.read(
      appSettingProvider.select((state) => state.onlyStatisticsProxy),
    );
    final snapshot = await coreController.getTrafficSnapshot(
      onlyStatisticsProxy,
    );
    ref.read(trafficsProvider.notifier).addTraffic(snapshot.traffic);
    // Diff check: only update totalTraffic if value actually changed
    final currentTotal = ref.read(totalTrafficProvider);
    if (snapshot.totalTraffic.up != currentTotal.up ||
        snapshot.totalTraffic.down != currentTotal.down) {
      ref.read(totalTrafficProvider.notifier).value = snapshot.totalTraffic;
    }
  }

  Future<void> autoCheckUpdate() async {
    if (!ref.read(appSettingProvider).autoCheckUpdate) return;
    final res = await request.checkForUpdate();
    checkUpdateResultHandle(data: res);
  }

  Future<void> checkUpdateResultHandle({
    Map<String, dynamic>? data,
    bool isUser = false,
  }) async {
    if (data != null) {
      final tagName = data['tag_name'];
      final body = data['body'];
      final submits = utils.parseReleaseBody(body);
      final res = await globalState.showCommonDialog<bool>(
        child: _UpdateAvailableDialog(
          tagName: tagName?.toString() ?? '',
          submits: submits,
          cancelText: isUser
              ? currentAppLocalizations.cancel
              : currentAppLocalizations.noLongerRemind,
        ),
      );
      if (res == true) {
        await _downloadAndInstallUpdate(data);
      } else if (!isUser && res == false) {
        ref
            .read(appSettingProvider.notifier)
            .update((state) => state.copyWith(autoCheckUpdate: false));
      }
    } else if (isUser) {
      globalState.showCommonDialog<void>(
        child: _UpdateStatusDialog(
          title: currentAppLocalizations.checkUpdate,
          message: currentAppLocalizations.checkUpdateError,
          icon: SurgeIcons.verified,
        ),
      );
    }
  }

  Map<String, dynamic>? _resolveAndroidApkAsset(Map<String, dynamic> data) {
    final assets = data['assets'];
    if (assets is! List) return null;
    final apkAssets = assets.whereType<Map<String, dynamic>>().where((asset) {
      final name = asset['name']?.toString().toLowerCase() ?? '';
      final url = asset['browser_download_url']?.toString() ?? '';
      return name.endsWith('.apk') && url.isNotEmpty;
    }).toList();
    if (apkAssets.isEmpty) return null;
    return apkAssets.firstWhere(
      (asset) =>
          asset['name']?.toString().toLowerCase().contains('arm64-v8a') == true,
      orElse: () => apkAssets.first,
    );
  }

  Future<void> _downloadAndInstallUpdate(Map<String, dynamic> data) async {
    final asset = _resolveAndroidApkAsset(data);
    if (asset == null) {
      launchUrl(Uri.parse('https://github.com/$repository/releases/latest'));
      return;
    }

    final url = asset['browser_download_url']?.toString();
    final name = asset['name']?.toString() ?? 'SlClash-update.apk';
    final expectedSha256 = githubAssetSha256(asset['digest']);
    if (url == null || url.isEmpty || expectedSha256 == null) {
      launchUrl(Uri.parse('https://github.com/$repository/releases/latest'));
      return;
    }

    final progress = ValueNotifier<double?>(0);
    final dialogContext = globalState.navigatorKey.currentContext!;
    var dialogClosed = false;
    void closeProgressDialog() {
      if (dialogClosed || !dialogContext.mounted) return;
      dialogClosed = true;
      Navigator.of(dialogContext).pop();
    }

    unawaited(
      globalState.showCommonDialog<void>(
        context: dialogContext,
        dismissible: false,
        child: _UpdateDownloadProgressDialog(progress: progress),
      ),
    );

    await globalState.safeRun<void>(
      () async {
        final cacheDir = await appPath.cacheDir.future;
        final updateDir = Directory(p.join(cacheDir.path, 'updates'));
        if (!updateDir.existsSync()) {
          updateDir.createSync(recursive: true);
        }
        for (final file in updateDir.listSync()) {
          if (file is File && file.path.endsWith('.apk')) {
            file.deleteSync();
          }
        }

        final apkPath = p.join(updateDir.path, name);
        await request.downloadUpdate(
          officialUrl: url,
          savePath: apkPath,
          expectedSha256: expectedSha256,
          onReceiveProgress: (received, total) {
            if (total > 0) {
              progress.value = (received / total).clamp(0, 1);
            } else {
              progress.value = null;
            }
          },
        );
        progress.value = 1;
        closeProgressDialog();
        final installed = await app?.installApk(apkPath) ?? false;
        if (!installed) {
          throw currentAppLocalizations.allowUnknownAppInstall;
        }
      },
      title: currentAppLocalizations.download,
      silence: false,
    );
    closeProgressDialog();
    progress.dispose();
  }
}

class _UpdateDownloadProgressDialog extends StatelessWidget {
  const _UpdateDownloadProgressDialog({required this.progress});

  final ValueNotifier<double?> progress;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    return CommonDialog(
      title: currentAppLocalizations.downloadUpdate,
      overrideScroll: true,
      child: ValueListenableBuilder<double?>(
        valueListenable: progress,
        builder: (_, value, _) {
          final percent = value == null ? null : (value * 100).floor();
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 64,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: surge.fill,
                  borderRadius: BorderRadius.circular(surge.radii.card),
                  border: Border.all(color: surge.separator, width: 0.5),
                ),
                child: Row(
                  children: [
                    SizedBox.square(
                      dimension: 36,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          CircularProgressIndicator(
                            value: value,
                            strokeWidth: 3,
                            color: surge.primary,
                            backgroundColor: surge.separator,
                          ),
                          Icon(
                            SurgeIcons.download,
                            size: 18,
                            color: surge.primary,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        percent == null
                            ? currentAppLocalizations.downloadingApk
                            : currentAppLocalizations.downloadingApkProgress(
                                percent,
                              ),
                        maxLines: 2,
                        style: context.typography.rowTitle.copyWith(
                          color: surge.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  minHeight: 8,
                  value: value,
                  color: surge.primary,
                  backgroundColor: surge.fill,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                currentAppLocalizations.apkInstallAfterDownload,
                style: context.typography.supporting.copyWith(
                  color: surge.textSecondary,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _UpdateAvailableDialog extends StatelessWidget {
  const _UpdateAvailableDialog({
    required this.tagName,
    required this.submits,
    required this.cancelText,
  });

  final String tagName;
  final List<String> submits;
  final String cancelText;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    return CommonDialog(
      title: currentAppLocalizations.discoverNewVersion,
      overrideScroll: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: surge.fill,
              borderRadius: BorderRadius.circular(surge.radii.card),
              border: Border.all(color: surge.separator, width: 0.5),
            ),
            child: Row(
              children: [
                Icon(SurgeIcons.newRelease, color: surge.primary, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    tagName.takeFirstValid([
                      currentAppLocalizations.newVersion,
                    ]),
                    maxLines: 2,
                    style: context.typography.cardTitle.copyWith(
                      color: surge.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (submits.isNotEmpty) ...[
            const SizedBox(height: 14),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: Scrollbar(
                thumbVisibility: false,
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: submits.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, index) =>
                      _UpdateChangeItem(text: submits[index]),
                ),
              ),
            ),
          ],
          const SizedBox(height: 18),
          SurgeDialogActionRow(
            cancelLabel: cancelText,
            submitLabel: currentAppLocalizations.download,
            onCancel: () => Navigator.of(context).pop(false),
            onSubmit: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
  }
}

class _UpdateStatusDialog extends StatelessWidget {
  const _UpdateStatusDialog({
    required this.title,
    required this.message,
    required this.icon,
  });

  final String title;
  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    return CommonDialog(
      title: title,
      overrideScroll: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            decoration: BoxDecoration(
              color: surge.fill,
              borderRadius: BorderRadius.circular(surge.radii.card),
              border: Border.all(color: surge.separator, width: 0.5),
            ),
            child: Row(
              children: [
                Icon(icon, color: surge.primary, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    message,
                    style: context.typography.body.copyWith(
                      color: surge.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              SurgeDialogActionButton(
                label: currentAppLocalizations.confirm,
                onPressed: () => Navigator.of(context).pop(),
                primary: true,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _UpdateChangeItem extends StatelessWidget {
  const _UpdateChangeItem({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 7),
          child: Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              color: surge.primary,
              shape: BoxShape.circle,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: context.typography.supporting.copyWith(
              color: surge.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

bool shouldRunUiStatsTimer({
  required bool appForeground,
  required bool sessionRunning,
  required bool smartPaused,
}) => appForeground && sessionRunning && !smartPaused;

enum UiStatsTimerEffect { none, start, stop }

UiStatsTimerEffect uiStatsTimerEffect({
  required bool shouldRun,
  required bool isTimerActive,
}) {
  if (shouldRun == isTimerActive) return UiStatsTimerEffect.none;
  return shouldRun ? UiStatsTimerEffect.start : UiStatsTimerEffect.stop;
}

@Riverpod(keepAlive: true)
class SetupAction extends _$SetupAction {
  final RuntimeConfigCommitOwner _runtimeConfigCommitOwner =
      RuntimeConfigCommitOwner();
  static const _tickInterval = Duration(seconds: 1);
  static const _chartUpdateInterval = Duration(seconds: 2);
  static const _totalTrafficUpdateInterval = Duration(seconds: 5);
  static const _runtimeUpdateInterval = Duration(seconds: 5);

  Timer? _updateTimer;
  DateTime? startTime;
  bool _isUpdatingUiStats = false;
  DateTime? _lastChartUpdateAt;
  DateTime? _lastTotalTrafficUpdateAt;
  DateTime? _lastRuntimeUpdateAt;

  bool get isStart => startTime != null && startTime!.isBeforeNow;

  bool get hasProtectableVpnSessionNow => hasProtectableVpnSession(
    vpnUiRunning: ref.read(isStartProvider),
    smartPaused: ref.read(isSmartStoppedProvider),
    nativeSession: _sessionState,
  );

  @override
  void build() {
    ref.listen(currentPageLabelProvider, (prev, next) {
      if (prev != next) {
        _restartUiStatsTimerIfNeeded();
      }
    });
    ref.listen(appForegroundProvider, (prev, next) {
      if (prev != next) reconcileUiStatsTimerIfNeeded();
    });
    ref.listen(isStartProvider, (prev, next) {
      if (prev != next) reconcileUiStatsTimerIfNeeded();
    });
    ref.listen(isSmartStoppedProvider, (prev, next) {
      if (prev != next) reconcileUiStatsTimerIfNeeded();
    });
    ref.onDispose(() {
      _updateTimer?.cancel();
      _updateTimer = null;
    });
  }

  bool get _isDashboardActive {
    return ref.read(currentPageLabelProvider) == PageLabel.dashboard;
  }

  static bool _shouldRun(DateTime now, DateTime? lastAt, Duration interval) {
    return lastAt == null || now.difference(lastAt) >= interval;
  }

  SetupParams get _setupParams {
    final selectedMap = ref.read(selectedMapProvider);
    final testUrl = ref.read(
      appSettingProvider.select((state) => state.testUrl),
    );
    return SetupParams(selectedMap: selectedMap, testUrl: testUrl);
  }

  Future<bool> fullSetup() async {
    if (!ref.read(initProvider)) return false;
    ref.read(delayDataSourceProvider.notifier).value = {};
    final applied = await applyProfile(force: true);
    ref.read(logsProvider.notifier).value = FixedList(500);
    ref.read(requestsProvider.notifier).value = FixedList(500);
    return applied;
  }

  Future<bool> _handleStart() async {
    if (!ref.read(suspendProvider)) {
      final started = await coreController.startListener();
      StartupTrace.mark(
        'vpn_listener_start',
        extras: {'success': started, 'source': 'setup_action'},
      );
      StartupTrace.mark('startListener');
      if (!started) {
        if (system.isAndroid) return false;
        startTime = null;
        ref.read(runTimeProvider.notifier).value = null;
        ref.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
        ref.read(realTunEnableProvider.notifier).value = false;
        return false;
      }
    }
    return true;
  }

  /// Full chain: fetch snapshot, update speed (1s), chart (2s), total (5s), runtime (5s).
  Future<void> _updateUiStats() async {
    // Visibility gate: only non-dashboard pages → skip everything except runtime at 5s
    if (!_isDashboardActive) {
      final now = DateTime.now();
      if (_shouldRun(now, _lastRuntimeUpdateAt, _runtimeUpdateInterval)) {
        ref.read(commonActionProvider.notifier).updateRunTime();
        _lastRuntimeUpdateAt = now;
      }
      return;
    }
    if (_isUpdatingUiStats) return;
    _isUpdatingUiStats = true;
    final statsIntent = _lifecycle.generation;
    final statsStartTime = startTime;
    try {
      final now = DateTime.now();

      // Fetch snapshot once per tick (FFI call)
      final onlyStatisticsProxy = ref.read(
        appSettingProvider.select((state) => state.onlyStatisticsProxy),
      );
      final snapshot = await coreController.getTrafficSnapshot(
        onlyStatisticsProxy,
      );
      if (!_lifecycle.isCurrent(statsIntent) ||
          startTime != statsStartTime || !_shouldUiStatsTimerRun) {
        return;
      }
      StartupTrace.mark(
        'ui_stats_traffic_snapshot',
        extras: {'page': ref.read(currentPageLabelProvider).name},
      );

      // 1. Speed text: every tick (1s) — lightweight ValueNotifier, no Provider rebuild
      currentSpeedNotifier.value = snapshot.traffic;

      // 2. Chart points: throttle to 2s
      if (_shouldRun(now, _lastChartUpdateAt, _chartUpdateInterval)) {
        ref.read(trafficsProvider.notifier).addTraffic(snapshot.traffic);
        _lastChartUpdateAt = now;
      }

      // 3. Total traffic: throttle to 5s + diff check
      if (_shouldRun(
        now,
        _lastTotalTrafficUpdateAt,
        _totalTrafficUpdateInterval,
      )) {
        final currentTotal = ref.read(totalTrafficProvider);
        if (snapshot.totalTraffic.up != currentTotal.up ||
            snapshot.totalTraffic.down != currentTotal.down) {
          ref.read(totalTrafficProvider.notifier).value = snapshot.totalTraffic;
        }
        _lastTotalTrafficUpdateAt = now;
      }

      // 4. Runtime: throttle to 5s
      if (_shouldRun(now, _lastRuntimeUpdateAt, _runtimeUpdateInterval)) {
        ref.read(commonActionProvider.notifier).updateRunTime();
        _lastRuntimeUpdateAt = now;
      }
    } catch (e) {
      commonPrint.log('update ui stats failed: $e', logLevel: LogLevel.warning);
    } finally {
      _isUpdatingUiStats = false;
    }
  }

  void _startUiStatsTimer() {
    _updateTimer?.cancel();
    _updateTimer = Timer.periodic(_tickInterval, (_) {
      StartupTrace.mark(
        'ui_stats_tick',
        extras: {'page': ref.read(currentPageLabelProvider).name},
      );
      unawaited(_updateUiStats());
    });
  }

  void _restartUiStatsTimerIfNeeded() {
    if (_updateTimer == null) return;
    if (!_shouldUiStatsTimerRun) {
      reconcileUiStatsTimerIfNeeded();
      return;
    }
    _startUiStatsTimer();
  }

  bool get _shouldUiStatsTimerRun => shouldRunUiStatsTimer(
    appForeground: ref.read(appForegroundProvider),
    sessionRunning: isStart,
    smartPaused: ref.read(isSmartStoppedProvider),
  );

  /// Converges the UI-only stats timer from foreground and session truth.
  /// Repeated calls are no-ops once the timer already matches the desired state.
  void reconcileUiStatsTimerIfNeeded() {
    switch (uiStatsTimerEffect(
      shouldRun: _shouldUiStatsTimerRun,
      isTimerActive: _updateTimer != null,
    )) {
      case UiStatsTimerEffect.none:
        return;
      case UiStatsTimerEffect.start:
        StartupTrace.mark('ui_stats_timer_started');
        unawaited(_updateUiStats());
        _startUiStatsTimer();
      case UiStatsTimerEffect.stop:
        _cancelUiStatsTimer();
    }
  }

  /// Stops the UI-only timer without resetting session, traffic, or Core state.
  void _cancelUiStatsTimer() {
    if (_updateTimer != null) {
      StartupTrace.mark('ui_stats_timer_stopped');
    }
    _updateTimer?.cancel();
    _updateTimer = null;
    _lastChartUpdateAt = null;
    _lastTotalTrafficUpdateAt = null;
    _lastRuntimeUpdateAt = null;
  }

  /// Compatibility semantic entry point. Foreground remains a mandatory gate.
  void resumeUiStatsTimerIfNeeded() {
    reconcileUiStatsTimerIfNeeded();
  }

  int _snapshotRead = 0;
  final _lifecycle = LifecycleIntent();

  int get lifecycleGeneration => _lifecycle.generation;
  bool isCurrentLifecycle(int generation) => _lifecycle.isCurrent(generation);

  Future<bool> _updateStartTime() async {
    final read = ++_snapshotRead;
    final intent = _lifecycle.generation;
    StartupTrace.mark('vpn_flutter_sync_begin', extras: {'source': 'app_init'});
    final observedStartTime = await service?.getRunTime();
    if (StartupTrace.enabled || system.isAndroid) {
      final observedSession = await service?.getSessionSnapshot() ?? const {};
      if (read != _snapshotRead || !_lifecycle.isCurrent(intent)) return false;
      final observedState = observedSession['state'];
      if (observedState is String) {
        _nativeSession = observedSession;
        if (observedState == 'RUNNING') {
          final startedAt = observedSession['startedAt'];
          startTime =
              (startedAt is int && startedAt > 0
                  ? DateTime.fromMillisecondsSinceEpoch(startedAt)
                  : observedStartTime);
        } else if (observedState == 'PAUSED' || observedState == 'STOPPED') {
          startTime = null;
        }
      }
      StartupTrace.mark(
        'vpn_snapshot',
        extras: {
          'layer': 'flutter',
          'session_id': _nativeSession['sessionId'] ?? 0,
          'state': _nativeSession['state'] ?? 'UNKNOWN',
          'started_at': _nativeSession['startedAt'] ?? 0,
          'smart_paused': _nativeSession['smartPaused'] ?? false,
          'flutter_is_start': startTime != null,
        },
      );
    } else {
      startTime = observedStartTime;
    }
    StartupTrace.mark(
      'vpn_flutter_sync_end',
      extras: {
        'state': _sessionState ?? 'UNKNOWN',
        'flutter_is_start': startTime != null,
      },
    );
    return true;
  }

  Map<String, dynamic> _nativeSession = const {};

  String? get _sessionState {
    final value = _nativeSession['state'];
    return value is String ? value : null;
  }

  /// Reconcile Flutter's visible state from the authoritative native session
  /// without issuing another VPN lifecycle command.
  Future<void> reconcileNativeSession() async {
    if (!system.isAndroid) return;
    if (!await _updateStartTime()) return;
    switch (nativeSessionUiStateFor(_sessionState)) {
      case NativeSessionUiState.running:
        ref.read(isSmartStoppedProvider.notifier).set(false);
        if (startTime != null) {
          ref.read(commonActionProvider.notifier).updateRunTime();
        }
        break;
      case NativeSessionUiState.paused:
        startTime = null;
        ref.read(runTimeProvider.notifier).value = null;
        ref.read(isSmartStoppedProvider.notifier).set(true);
        break;
      case NativeSessionUiState.stopped:
        startTime = null;
        reconcileUiStatsTimerIfNeeded();
        convergeFullStopProviders(
          clearManualOverride: () =>
              ref.read(smartAutoStopManualOverrideProvider.notifier).clear(),
          clearSmartStopped: () =>
              ref.read(isSmartStoppedProvider.notifier).set(false),
        );
        ref.read(trafficsProvider.notifier).clear();
        ref.read(totalTrafficProvider.notifier).value = const Traffic();
        ref.read(runTimeProvider.notifier).value = null;
        ref.read(checkIpNumProvider.notifier).add();
        break;
      case NativeSessionUiState.pending:
        break;
    }
    reconcileUiStatsTimerIfNeeded();
  }

  Future<bool> handleStop() async {
    final stopped = await coreController.stopListener();
    StartupTrace.mark(
      'vpn_listener_stop',
      extras: {'success': stopped, 'source': 'setup_action'},
    );
    if (system.isAndroid) {
      await reconcileNativeSession();
      if (_sessionState != 'STOPPED') {
        // Keep/restore the visible running state when native did not confirm
        // teardown. A failed command must not render a fake disconnection.
        resumeUiStatsTimerIfNeeded();
        return false;
      }
    } else if (!stopped) {
      return false;
    } else {
      startTime = null;
      reconcileUiStatsTimerIfNeeded();
    }
    return true;
  }

  /// Local-only stop for smart auto stop: cancel timer, stop listener,
  /// clear runTime in UI — but do NOT reset traffic or call native stopService.
  Future handleSmartStopLocal() async {
    if (system.isAndroid) {
      await reconcileNativeSession();
      return;
    }
    StartupTrace.mark('smart_stop_begin', extras: {'layer': 'flutter_local'});
    startTime = null;
    reconcileUiStatsTimerIfNeeded();
    final stopped = await coreController.stopCoreListenerOnly();
    StartupTrace.mark(
      'vpn_listener_stop',
      extras: {'success': stopped, 'source': 'smart_stop'},
    );
    ref.read(runTimeProvider.notifier).value = null;
    StartupTrace.mark(
      'smart_stop_complete',
      extras: {'layer': 'flutter_local', 'flutter_is_start': false},
    );
  }

  /// Local-only resume for smart auto stop: restore startTime, restart
  /// runtime/traffic timer, resume core listener.
  Future handleSmartResumeLocal(DateTime nativeStartTime) async {
    if (system.isAndroid) {
      await reconcileNativeSession();
      return;
    }
    StartupTrace.mark(
      'smart_resume_begin',
      extras: {
        'layer': 'flutter_local',
        'started_at': nativeStartTime.millisecondsSinceEpoch,
      },
    );
    startTime = nativeStartTime;
    ref.read(runTimeProvider.notifier).value =
        nativeStartTime.millisecondsSinceEpoch;
    reconcileUiStatsTimerIfNeeded();
    final suspend = ref.read(suspendProvider);
    var coreReady = suspend;
    if (!suspend) {
      coreReady = await ref.read(coreActionProvider.notifier).ensureCoreReady();
      if (!coreReady) {
        commonPrint.log(
          'smart-resume: core not ready, skip startListener',
          logLevel: LogLevel.warning,
        );
      }
    }
    if (shouldStartListenerAfterSmartResume(
      suspend: suspend,
      coreReady: coreReady,
    )) {
      final started = await coreController.startListener();
      StartupTrace.mark(
        'vpn_listener_start',
        extras: {'success': started, 'source': 'smart_resume'},
      );
    }
    reconcileUiStatsTimerIfNeeded();
    NetworkDiagnosticsRevision.bump(reason: 'smart_resume');
    StartupTrace.mark(
      'smart_resume_complete',
      extras: {'layer': 'flutter_local', 'flutter_is_start': true},
    );
  }

  Future<void> initStatus() async {
    final initIntent = _lifecycle.generation;
    if (!globalState.needInitStatus) {
      commonPrint.log('init status cancel');
      return;
    }
    commonPrint.log('init status');
    StartupTrace.mark('initStatus.begin');
    if (system.isAndroid) {
      if (!await _updateStartTime()) return;
      StartupTrace.mark('updateStartTime');
    }
    final sessionState = _sessionState;
    if (sessionState == 'STARTING' || sessionState == 'STOPPING') {
      globalState.needInitStatus = false;
      await ref.read(coreActionProvider.notifier).connectCore(minDelay: Duration.zero);
      await reconcileNativeSession();
      return;
    }
    final shouldFullSetup = shouldFullSetupOnInit(
      isRunning: isStart || sessionRequiresFullSetup(sessionState),
      autoRun: sessionState != 'PAUSED' && ref.read(appSettingProvider).autoRun,
    );
    if (shouldFullSetup) {
      final coreAction = ref.read(coreActionProvider.notifier);
      final connected = await coreAction.connectCore(
        minDelay: shouldSkipConnectMinDelay(sessionState)
            ? Duration.zero
            : const Duration(milliseconds: 300),
      );
      StartupTrace.mark('connectCore');
      if (!connected) {
        startTime = null;
        ref.read(runTimeProvider.notifier).value = null;
        StartupTrace.mark('core_connect_failed');
        return;
      }
      await coreAction.initCore(
        deferGroupSetup: shouldDeferInitCoreGroups(sessionState),
      );
      StartupTrace.mark('initCore');
      final coreReady =
          coreController.isCompleted && await coreController.isInit;
      if (coreReady) {
        StartupTrace.mark('core_ready');
      } else {
        StartupTrace.mark('core_init_failed');
      }
      if (!_lifecycle.isCurrent(initIntent)) return;
      await updateStatus(true, isInit: true);
    } else {
      globalState.needInitStatus = false;
      ref.read(runTimeProvider.notifier).value = null;
      if (shouldRestoreSmartPaused(
        sessionState,
        smartPaused: _nativeSession['smartPaused'] == true,
      )) {
        ref.read(isSmartStoppedProvider.notifier).set(true);
        StartupTrace.mark('smart_paused_restored');
      }
      if (shouldAttachCoreWithoutVpnSetup(sessionState)) {
        final coreAction = ref.read(coreActionProvider.notifier);
        final connected = await coreAction.connectCore(minDelay: Duration.zero);
        if (connected) {
          final coreReady = await coreAction.ensureCoreReady();
          if (coreReady) {
            // A native PAUSED session proves that Core is attachable, but not
            // which Flutter Profile lifetime owns its current config. A
            // display-only setup is the authoritative reattachment boundary;
            // it keeps TUN paused while activating the selected Profile.
            final outcome = await _applyProfileForDisplayOutcome();
            if (outcome.mayContinueStart) {
              StartupTrace.mark('paused_core_attached');
            }
          }
        } else {
          ref.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
        }
      } else {
        ref.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
      }
      commonPrint.log('init status skip full setup');
      StartupTrace.mark('core_skipped');
    }
  }

  Future<void> updateStatus(bool isStart, {bool isInit = false}) async {
    final intent = isInit ? _lifecycle.generation : _lifecycle.begin();
    if (!isStart) {
      _runtimeConfigCommitOwner.beginRequest();
      // Stop bypasses the preparation queue: it must cancel a pending native
      // permission request without waiting for that request to finish.
      await handleStop();
      return;
    } else if (!isInit) {
      await globalState.attach();
    }
    if (!_lifecycle.isCurrent(intent)) return;
    await _lifecycle.commit(intent, () =>
        _updateStatusOwned(isStart, isInit: isInit, intent: intent));
  }

  Future<void> _updateStatusOwned(bool isStart, {
    required bool isInit, required int intent,
  }) async {
    StartupTrace.mark(
      'vpn_action_requested',
      extras: {
        'action': isStart ? 'start' : 'stop',
        'source': isInit ? 'app_init' : 'flutter_ui',
        'flutter_is_start': ref.read(isStartProvider),
      },
    );
    if (isStart) {
      if (!isInit) {
        if (system.isAndroid &&
            shouldClearTaskRemovalStop(isStart: isStart, isInit: isInit)) {
          await service?.clearTaskRemovalStop();
        }
        final coreAction = ref.read(coreActionProvider.notifier);
        if (!await coreAction.connectCore()) return;
        if (!await coreAction.ensureCoreReady()) return;
        if (!_lifecycle.isCurrent(intent) || !ref.read(initProvider)) return;
      } else {
        globalState.needInitStatus = false;
      }

      final policy = vpnStartPolicy(isInit: isInit);
      try {
        var started = true;
        final outcome = await _applyProfileOutcome(
          force: true,
          silence: policy.silence,
          preloadInvoke: () async {
            if (!_lifecycle.isCurrent(intent)) return;
            started = await _handleStart();
          },
        );

        if (!_lifecycle.isCurrent(intent) ||
            outcome == SetupConfigOutcome.superseded) {
          return;
        }
        if (!started || !outcome.mayContinueStart) {
          if (system.isAndroid) {
            await reconcileNativeSession();
            return;
          }
          if (policy.stopOnFailure) {
            final stopped = await handleStop();
            if (!stopped) return;
          }
          startTime = null;
          ref.read(runTimeProvider.notifier).value = null;
          return;
        }

        if (system.isAndroid) {
          await reconcileNativeSession();
          return;
        }
        startTime ??= DateTime.now();
        if (policy.seedRunTimeAtZero) {
          ref.read(runTimeProvider.notifier).value = 0;
        }
        ref.read(commonActionProvider.notifier).updateRunTime();
      } catch (_) {
        if (!_lifecycle.isCurrent(intent)) return;
        if (system.isAndroid) {
          await reconcileNativeSession();
          rethrow;
        }
        if (!isInit) {
          try {
            await handleStop();
          } catch (_) {
            if (system.isAndroid) await reconcileNativeSession();
          }
          rethrow;
        }
        if (system.isAndroid) {
          await reconcileNativeSession();
          return;
        }
        startTime = null;
        ref.read(runTimeProvider.notifier).value = null;
      }
    } else {
      // Clear smart auto stop manual override when user stops proxy.
      // This ensures the next start on a trusted network auto-stops again.
      final stopped = await handleStop();
      if (!stopped) return;
      convergeFullStopProviders(
        clearManualOverride: () =>
            ref.read(smartAutoStopManualOverrideProvider.notifier).clear(),
        clearSmartStopped: () =>
            ref.read(isSmartStoppedProvider.notifier).set(false),
      );
      if (!system.isAndroid) coreController.resetTraffic();
      ref.read(trafficsProvider.notifier).clear();
      ref.read(totalTrafficProvider.notifier).value = const Traffic();
      ref.read(runTimeProvider.notifier).value = null;
      ref.read(checkIpNumProvider.notifier).add();
    }
  }

  Future<void> updateConfigDebounce() async {
    debouncer.call(FunctionTag.updateConfig, () async {
      await globalState.safeRun(() async {
        final updateParams = ref.read(updateParamsProvider);
        final res = await _requestAdmin(updateParams.tun.enable);
        if (res.isError) return;
        final realTunEnable = ref.read(realTunEnableProvider);
        final message = await coreController.updateConfig(
          updateParams.copyWith.tun(enable: realTunEnable),
        );
        if (message.isNotEmpty) throw message;
      });
    });
  }

  void tryCheckIp() {
    final shouldRetry = ref.read(
      networkDetectionProvider.select(
        (state) =>
            state.hasChecked &&
            state.ipInfo == null &&
            state.isLoading == false,
      ),
    );
    if (!shouldRetry) return;
    ref.read(checkIpNumProvider.notifier).add();
  }

  void applyProfileDebounce({bool silence = false, bool force = false}) {
    debouncer.call(FunctionTag.applyProfile, (silence, force) {
      applyProfile(silence: silence, force: force);
    }, args: [silence, force]);
  }

  void changeMode(Mode mode) {
    ref
        .read(patchClashConfigProvider.notifier)
        .update((state) => state.copyWith(mode: mode));
    if (mode == Mode.global) {
      ref
          .read(proxiesActionProvider.notifier)
          .updateCurrentGroupName(GroupName.GLOBAL.name);
    }
    ref.read(checkIpNumProvider.notifier).add();
  }

  void autoApplyProfile() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      applyProfile();
    });
  }

  Future<bool> applyProfile({
    bool silence = false,
    bool force = false,
    FutureOr<void> Function()? preloadInvoke,
  }) async {
    final outcome = await _applyProfileOutcome(
      silence: silence,
      force: force,
      preloadInvoke: preloadInvoke,
    );
    return !outcome.isFailure;
  }

  Future<SetupConfigOutcome> _applyProfileOutcome({
    bool silence = false,
    bool force = false,
    FutureOr<void> Function()? preloadInvoke,
  }) async {
    final proxiesAction = ref.read(proxiesActionProvider.notifier);
    final runtimeIdentity = proxiesAction.captureRuntimeProfileIdentity();
    final outcome = await _setupConfig(
      force: force,
      silence: silence,
      preloadInvoke: preloadInvoke,
      onUpdated: (context) async {
        final targetProfileId = context.targetProfileId;
        if (targetProfileId == null ||
            runtimeIdentity == null ||
            runtimeIdentity.profileId != targetProfileId ||
            !proxiesAction.isRuntimeIdentityActive(runtimeIdentity)) {
          return;
        }
        await proxiesAction.updateGroups(commitContext: context);
        if (!proxiesAction.isRuntimeIdentityActive(runtimeIdentity)) return;
        StartupTrace.mark('applyProfile.groups');
        final published = await fetchAndPublishRuntimeProjection(
          targetProfileId: targetProfileId,
          currentProfileId: () =>
              proxiesAction.isRuntimeIdentityActive(runtimeIdentity)
              ? runtimeIdentity.profileId
              : null,
          fetch: coreController.getExternalProviders,
          publish: (providers) {
            ref.read(providersProvider.notifier).value = providers;
          },
        );
        if (published) StartupTrace.mark('syncProviders');
      },
    );
    StartupTrace.mark(
      'runtime_config_commit_released',
      extras: {
        'profileId': runtimeIdentity?.profileId,
        'epoch': runtimeIdentity?.epoch,
        'outcome': outcome.name,
      },
    );
    if (runtimeIdentity != null &&
        setupOutcomeConfirmsRuntimeActivation(outcome) &&
        proxiesAction.isRuntimeIdentityActive(runtimeIdentity)) {
      proxiesAction.schedulePostActivationPreheat(runtimeIdentity);
    }
    return outcome;
  }

  /// Settings reuse the profile commit gate. A candidate and its rollback
  /// never race another profile's write to the shared runtime file.
  Future<void> applySettingsSnapshot({
    required Config candidate,
    required SettingsApplyKind kind,
    required bool Function() isLatest,
  }) async {
    final generation = _runtimeConfigCommitOwner.beginRequest();
    final lifecycle = lifecycleGeneration;
    final profileId = candidate.currentProfileId;
    bool active() => ref.read(currentProfileIdProvider) == profileId &&
        isCurrentLifecycle(lifecycle) &&
        !ref.read(isSmartStoppedProvider);
    if (profileId == null || !active() || !ref.read(isStartProvider)) {
      throw const SettingsApplyCancelled();
    }
    final savedRevision = settingsSavedEditRevision;
    final setupState = await ref.read(setupStateProvider(profileId).future);
    final routes = settingsRouteAddresses(candidate);
    for (final route in routes) {
      final error = validateRouteCidr(route);
      if (error != null) throw SettingsApplyFailure(error);
    }
    final materialized = await getProfile(
      setupState: setupState,
      patchConfig: candidate.patchClashConfig.copyWith.tun(enable: false),
      settingsSnapshot: candidate,
    );
    final validation = await coreController.validateConfigWithData(materialized.a);
    if (validation.isNotEmpty) throw SettingsApplyFailure(validation);
    final snapshot = await service?.getSessionSnapshot();
    if (!active() || !isLatest() || !ref.read(isStartProvider) ||
        (system.isAndroid && snapshot?['state'] != 'RUNNING')) {
      throw const SettingsApplyCancelled();
    }
    final sessionId = snapshot?['sessionId'] as int? ?? 0;
    final result = await _runtimeConfigCommitOwner.commit(
      generation: generation,
      transaction: (_) async {
        if (!active() || !isLatest() || !ref.read(isStartProvider)) {
          throw const SettingsApplyCancelled();
        }
        final previous = settingsRuntimeRecord.value;
        if (previous == null || previous.config.currentProfileId != profileId) {
          throw const SettingsApplyFailure('No acknowledged runtime configuration');
        }
        final configFile = File(await appPath.configFilePath);
        var touched = false;
        var nativeApplied = false;
        try {
          if (!active()) throw const SettingsApplyCancelled();
          touched = true;
          await configFile.safeWriteAsString(materialized.a);
          String message;
          if (kind == SettingsApplyKind.hot) {
            final patch = candidate.patchClashConfig;
            message = await coreController.updateConfig(UpdateParams(
              tun: patch.tun.getRealTun(candidate.networkProps.routeMode).copyWith(enable: false),
              allowLan: patch.allowLan,
              findProcessMode: patch.findProcessMode,
              mode: patch.mode,
              logLevel: patch.logLevel,
              ipv6: patch.ipv6,
              tcpConcurrent: patch.tcpConcurrent,
              externalController: patch.externalController,
              unifiedDelay: patch.unifiedDelay,
              mixedPort: patch.mixedPort,
            ));
          } else {
            message = await coreController.setupConfig(params: _setupParams, setupState: setupState);
          }
          if (message.isNotEmpty) throw StateError(message);
          if (!active()) throw const SettingsApplyCancelled();
          if (system.isAndroid) {
            final native = await service!.getSessionSnapshot();
            if (native['state'] != 'RUNNING' || native['sessionId'] != sessionId) {
              throw const SettingsApplyCancelled();
            }
            if (kind == SettingsApplyKind.vpn) {
              final error = await service!.reconfigureSettings(settingsVpnOptions(candidate), sessionId);
              if (error.isNotEmpty) throw StateError(error);
              nativeApplied = true;
            }
            final confirmed = await service!.getSessionSnapshot();
            if (!active() || confirmed['state'] != 'RUNNING' || confirmed['sessionId'] != sessionId) {
              throw const SettingsApplyCancelled();
            }
            final sync = await service!.syncState(ref.read(sharedStateProvider).copyWith(
              vpnOptions: settingsVpnOptions(candidate),
            ));
            if (sync != '') throw StateError(sync ?? 'Settings sync not acknowledged');
          }
          globalState.lastConfigMd5 = materialized.b;
          settingsRuntimeRecord.value = SettingsRuntimeRecord(candidate, materialized.a, savedEditRevision: savedRevision);
          ref.read(checkIpNumProvider.notifier).add();
          NetworkDiagnosticsRevision.bump(reason: 'settings_applied');
        } catch (error) {
          Object? restoreError;
          if (touched) {
            try {
              // Restoring the core does not start/resume the VPN. Even when a
              // newer stop wins, avoid leaving a failed YAML on disk.
              await configFile.safeWriteAsString(previous.yaml);
              final message = await coreController.setupConfig(params: _setupParams, setupState: setupState);
              if (message.isNotEmpty) throw StateError(message);
              globalState.lastConfigMd5 = previous.yaml.toMd5();
              if (system.isAndroid) {
                final native = await service!.getSessionSnapshot();
                if (active() && native['state'] == 'RUNNING' && native['sessionId'] == sessionId) {
                  if (nativeApplied) {
                    final error = await service!.reconfigureSettings(settingsVpnOptions(previous.config), sessionId);
                    if (error.isNotEmpty) throw StateError(error);
                  }
                  await service!.syncState(ref.read(sharedStateProvider).copyWith(
                    vpnOptions: settingsVpnOptions(previous.config),
                  ));
                } else if (error is! SettingsApplyCancelled) {
                  throw StateError('VPN did not recover its running session');
                }
              }
            } catch (failure) {
              restoreError = failure;
            }
          }
          if (system.isAndroid) await reconcileNativeSession();
          if (error is SettingsApplyCancelled && restoreError == null) rethrow;
          throw SettingsApplyFailure(error, restoreError: restoreError);
        }
      },
    );
    if (result == RuntimeConfigCommitOutcome.superseded) {
      throw const SettingsApplyCancelled();
    }
  }

  Future<void> applyProfileForDisplay({bool silence = true}) async {
    await _applyProfileForDisplayOutcome(silence: silence);
  }

  Future<SetupConfigOutcome> applyProfileForReadiness({bool silence = true}) {
    return _applyProfileForDisplayOutcome(silence: silence);
  }

  Future<SetupConfigOutcome> _applyProfileForDisplayOutcome({
    bool silence = true,
    RuntimeConfigPostUpdateContext? inheritedContext,
  }) async {
    final proxiesAction = ref.read(proxiesActionProvider.notifier);
    final runtimeIdentity = proxiesAction.captureRuntimeProfileIdentity();
    final patchConfig = ref
        .read(patchClashConfigProvider)
        .copyWith
        .tun(enable: false);
    final outcome = await _setupConfig(
      force: true,
      silence: silence,
      patchConfigOverride: patchConfig,
      requestAdmin: false,
      inheritedContext: inheritedContext,
    );
    if (inheritedContext == null) {
      StartupTrace.mark(
        'runtime_config_commit_released',
        extras: {
          'profileId': runtimeIdentity?.profileId,
          'epoch': runtimeIdentity?.epoch,
          'outcome': outcome.name,
          'displayOnly': true,
        },
      );
      if (runtimeIdentity != null &&
          setupOutcomeConfirmsRuntimeActivation(outcome) &&
          proxiesAction.isRuntimeIdentityActive(runtimeIdentity)) {
        proxiesAction.schedulePostActivationPreheat(runtimeIdentity);
      }
    }
    return outcome;
  }

  Future<VM2<String, String>> getProfile({
    required SetupState setupState,
    required PatchClashConfig patchConfig,
    Config? settingsSnapshot,
    void Function(bool enabled)? onDnsSource,
  }) async {
    final profileId = setupState.profileId;
    if (profileId == null) return const VM2('', '');
    final defaultUA = globalState.packageInfo.ua;
    final networkVM2 = settingsSnapshot != null
        ? VM2(settingsSnapshot.networkProps.appendSystemDns, settingsSnapshot.networkProps.routeMode)
        : ref.read(
      networkSettingProvider.select(
        (state) => VM2(state.appendSystemDns, state.routeMode),
      ),
    );
    final bool overrideDns = settingsSnapshot == null
        ? ref.read(overrideDnsProvider) : settingsSnapshot.overrideDns;
    final appendSystemDns = networkVM2.a;
    final routeMode = networkVM2.b;
    String? scriptContent;
    final List<Rule> addedRules = [];
    final List<ProxyGroup> proxyGroups = [];
    final List<Rule> rules = [];
    if (setupState.overwriteType == OverwriteType.script) {
      scriptContent = await setupState.script?.content;
    } else if (setupState.overwriteType == OverwriteType.standard) {
      addedRules.addAll(setupState.addedRules);
    } else {
      proxyGroups.addAll(setupState.proxyGroups);
      rules.addAll(setupState.rules);
    }
    final realPatchConfig = patchConfig.copyWith(
      tun: patchConfig.tun.getRealTun(routeMode),
    );
    final usesScript = setupState.overwriteType == OverwriteType.script;
    final Map<String, dynamic> rawConfig;
    // Both Script and non-Script profiles read ONE snapshot whose bytes feed
    // both the generic source parse and the Mihomo normalization. The same
    // snapshot bytes reach Core through a unique snapshot file whose path
    // travels over the Android Binder instead of the whole profile: the Binder
    // transaction buffer is ~1MB and large subscriptions would overflow it.
    // The file is removed once Core has normalized it.
    Future<MihomoConfigMap> normalizeSnapshot(List<int> snapshot) async {
      final snapshotDir = await appPath.profilesPath;
      // Timestamp plus random suffix makes the name collision-resistant even
      // under concurrent materializations of the same profile; a shared name
      // could otherwise let one task overwrite or delete another task's
      // in-flight snapshot.
      final snapshotFile = File(
        p.join(
          snapshotDir,
          '.$profileId.snapshot-'
          '${DateTime.now().microsecondsSinceEpoch}.'
          '${Random().nextInt(1 << 16)}.yaml',
        ),
      );
      try {
        await snapshotFile.writeAsBytes(snapshot, flush: true);
        return await coreController.getConfigAtPath(snapshotFile.path);
      } finally {
        if (await snapshotFile.exists()) {
          await snapshotFile.delete();
        }
      }
    }

    if (usesScript) {
      rawConfig = await resolveScriptSnapshotRuntimeBase(
        loadSnapshot: () async {
          final profilePath = await appPath.getProfilePath(
            profileId.toString(),
          );
          return File(profilePath).readAsBytes();
        },
        normalizeSnapshot: normalizeSnapshot,
        fallbackNormalized: () async {
          final configMap = await coreController.getConfig(profileId);
          return scriptContent?.isNotEmpty == true
              ? await handleEvaluate(scriptContent!, configMap)
              : configMap;
        },
        evaluateScript: (scriptInput) async => scriptContent?.isNotEmpty == true
            ? await handleEvaluate(scriptContent!, scriptInput)
            : scriptInput,
        onPreservationFailure: (error, _) {
          commonPrint.log(
            'script source preservation failed for profileId=$profileId: '
            '$error; falling back to normalized-only script config',
            logLevel: LogLevel.warning,
          );
        },
        onScriptApplyFailure: (error, _) {
          commonPrint.log(
            'script preservation apply failed for profileId=$profileId: '
            '$error; using first script evaluation result',
            logLevel: LogLevel.warning,
          );
        },
      );
    } else {
      // Any failure falls back to the normalized-only path without mixing
      // snapshots.
      rawConfig = await resolveSnapshotRuntimeBase(
        loadSnapshot: () async {
          final profilePath = await appPath.getProfilePath(
            profileId.toString(),
          );
          return File(profilePath).readAsBytes();
        },
        normalizeSnapshot: normalizeSnapshot,
        fallbackNormalized: () => coreController.getConfig(profileId),
        onPreservationFailure: (error, _) {
          commonPrint.log(
            'source snapshot preservation failed for profileId=$profileId: '
            '$error; falling back to normalized-only config',
            logLevel: LogLevel.warning,
          );
        },
      );
    }
    onDnsSource?.call(rawConfig['dns']?['enable'] == true);
    final directory = await appPath.profilesPath;
    final res = makeRealProfileTask(
      MakeRealProfileState(
        rules: rules,
        proxyGroups: proxyGroups,
        profilesPath: directory,
        profileId: profileId,
        rawConfig: rawConfig,
        realPatchConfig: realPatchConfig,
        overrideDns: overrideDns,
        appendSystemDns: appendSystemDns,
        addedRules: addedRules,
        defaultUA: defaultUA,
      ),
    );
    return res;
  }

  Future<String> getProfileWithId(int profileId) async {
    try {
      final setupState = await ref.read(setupStateProvider(profileId).future);
      final patchClashConfig = ref.read(patchClashConfigProvider);
      final res = await getProfile(
        setupState: setupState,
        patchConfig: patchClashConfig,
      );
      return res.a;
    } catch (e) {
      globalState.showNotifier(e.toString());
    }
    return '';
  }

  Future<Result<bool>> _requestAdmin(bool enableTun) async {
    final realTunEnable = ref.read(realTunEnableProvider);
    if (enableTun != realTunEnable && realTunEnable == false) {
      final code = await system.authorizeCore();
      switch (code) {
        case AuthorizeCode.success:
          await ref.read(coreActionProvider.notifier).restartCore();
          return Result.error('');
        case AuthorizeCode.none:
          break;
        case AuthorizeCode.error:
          enableTun = false;
          break;
      }
    }
    ref.read(realTunEnableProvider.notifier).value = enableTun;
    return Result.success(enableTun);
  }

  Future<SetupConfigOutcome> _setupConfig({
    bool force = false,
    bool silence = false,
    FutureOr<void> Function()? preloadInvoke,
    FutureOr Function(RuntimeConfigPostUpdateContext context)? onUpdated,
    PatchClashConfig? patchConfigOverride,
    bool requestAdmin = true,
    RuntimeConfigPostUpdateContext? inheritedContext,
  }) async {
    final isExternalRequest = inheritedContext == null;
    final requestGeneration =
        inheritedContext?.lease.generation ??
        _runtimeConfigCommitOwner.beginRequest();
    final frozenTargetProfile =
        inheritedContext?.targetProfile ?? ref.read(currentProfileProvider);
    final proxiesAction = ref.read(proxiesActionProvider.notifier);
    final frozenRuntimeIdentity =
        frozenTargetProfile?.id == ref.read(currentProfileIdProvider)
        ? proxiesAction.captureRuntimeProfileIdentity()
        : null;
    try {
      var profile = frozenTargetProfile;
      if (profile != null &&
          profile.url.isNotEmpty &&
          !await profile.sourceExists) {
        await ref
            .read(profilesActionProvider.notifier)
            .updateProfile(
              profile,
              publishInput: false,
              applyAfterCommit: false,
            );
        profile = ref.read(profilesProvider).getProfile(profile.id);
      }
      commonPrint.log('setup ===> ${profile?.id}');
      final desiredSettings = ref.read(configProvider);
      final acknowledgedSettings = settingsRuntimeRecord.value;
      // Background/profile refreshes use the last successful settings while
      // the settings queue owns an uncommitted edit. Explicit starts use the
      // saved preferences. This also preserves the one-second quiet period.
      final settingsSnapshot = preloadInvoke == null &&
              ref.read(isStartProvider) && acknowledgedSettings != null
          ? acknowledgedSettings.config.copyWith(
              currentProfileId: desiredSettings.currentProfileId,
            )
          : desiredSettings;
      final PatchClashConfig patchConfig =
          settingsSnapshot.patchClashConfig.copyWith.tun(
            enable: patchConfigOverride?.tun.enable ?? settingsSnapshot.patchClashConfig.tun.enable,
          );
      late final bool realTunEnable;
      if (requestAdmin) {
        final res = await _requestAdmin(patchConfig.tun.enable);
        if (res.isError) {
          return !isExternalRequest ||
                  _runtimeConfigCommitOwner.isLatest(requestGeneration)
              ? SetupConfigOutcome.failed
              : SetupConfigOutcome.superseded;
        }
        realTunEnable = ref.read(realTunEnableProvider);
      } else {
        realTunEnable = false;
      }
      final realPatchConfig = patchConfig.copyWith.tun(enable: realTunEnable);
      final savedRevision = settingsSavedEditRevision;
      final setupState = await ref.read(setupStateProvider(profile?.id).future);
      if (system.isAndroid) {
        globalState.lastVpnState = ref.read(vpnStateProvider);
        final sharedState = ref.read(sharedStateProvider);
        preferences.saveShareState(sharedState);
      }
      final vm2 = await getProfile(
        setupState: setupState,
        patchConfig: realPatchConfig,
        settingsSnapshot: settingsSnapshot,
      );
      StartupTrace.mark('getProfile');
      final yamlString = vm2.a;
      final yamlMd5 = vm2.b;
      final configFilePath = await appPath.configFilePath;
      var outcome = SetupConfigOutcome.failed;
      await globalState.loadingRun(
        () async {
          Future<void> commitTransaction(
            RuntimeConfigCommitLease activeLease,
          ) async {
            Future<bool> acknowledgeRuntimeActivation(
              SetupConfigOutcome confirmedOutcome,
            ) {
              if (!setupOutcomeConfirmsRuntimeActivation(confirmedOutcome)) {
                return Future.value(false);
              }
              if (frozenTargetProfile == null) {
                return Future.value(
                  ref.read(currentProfileIdProvider) == null,
                );
              }
              if (frozenRuntimeIdentity == null) return Future.value(false);
              return proxiesAction.activateRuntimeIdentity(
                frozenRuntimeIdentity,
              );
            }

            if (yamlMd5 == globalState.lastConfigMd5 && force == false) {
              if (!await acknowledgeRuntimeActivation(
                SetupConfigOutcome.unchanged,
              )) {
                outcome = SetupConfigOutcome.superseded;
                return;
              }
              settingsRuntimeRecord.value = SettingsRuntimeRecord(settingsSnapshot, yamlString, savedEditRevision: savedRevision);
              outcome = SetupConfigOutcome.unchanged;
              return;
            }
            await File(configFilePath).safeWriteAsString(yamlString);
            final message = await coreController.setupConfig(
              setupState: setupState,
              params: _setupParams,
              preloadInvoke: preloadInvoke,
            );
            StartupTrace.mark('setupConfig');

            if (message.isNotEmpty) {
              commonPrint.log(
                'setupConfig failed: profileId=${setupState.profileId}, '
                'message="$message", ignoredIsEmpty=${message.endsWith('is empty')}',
                logLevel: LogLevel.warning,
              );

              if (message.endsWith('is empty')) {
                outcome = SetupConfigOutcome.failed;
                return;
              }

              throw message;
            }

            globalState.lastConfigMd5 = yamlMd5;
            if (!await acknowledgeRuntimeActivation(
              SetupConfigOutcome.applied,
            )) {
              outcome = SetupConfigOutcome.superseded;
              return;
            }
            settingsRuntimeRecord.value = SettingsRuntimeRecord(settingsSnapshot, yamlString, savedEditRevision: savedRevision);
            ref.read(checkIpNumProvider.notifier).add();
            NetworkDiagnosticsRevision.bump(reason: 'profile_apply');
            await onUpdated?.call(
              RuntimeConfigPostUpdateContext(
                lease: activeLease,
                targetProfile: profile,
              ),
            );
            outcome = SetupConfigOutcome.applied;
            StartupTrace.mark('applyProfile');
          }

          late final RuntimeConfigCommitOutcome commitOutcome;
          if (inheritedContext != null) {
            await _runtimeConfigCommitOwner.continueCommit(
              lease: inheritedContext.lease,
              transaction: commitTransaction,
            );
            commitOutcome = RuntimeConfigCommitOutcome.committed;
          } else {
            commitOutcome = await _runtimeConfigCommitOwner.commit(
              generation: requestGeneration,
              transaction: commitTransaction,
            );
          }
          if (commitOutcome == RuntimeConfigCommitOutcome.superseded) {
            commonPrint.log(
              'setupConfig superseded before commit: '
              'profileId=${setupState.profileId}, generation=$requestGeneration',
            );
            outcome = SetupConfigOutcome.superseded;
          }
        },
        silence: true,
        tag: !silence ? LoadingTag.proxies : null,
      );
      return outcome;
    } catch (error, stackTrace) {
      if (isExternalRequest &&
          !_runtimeConfigCommitOwner.isLatest(requestGeneration)) {
        commonPrint.log(
          'setupConfig superseded during materialization: '
          'generation=$requestGeneration, error=$error',
        );
        return SetupConfigOutcome.superseded;
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }
}

@Riverpod(keepAlive: true)
class BackupAction extends _$BackupAction {
  @override
  void build() {}

  Future<String> backup() async {
    final profiles = ref.read(profilesProvider);
    final currentProfileId = ref.read(currentProfileIdProvider);
    final profilesPath = await appPath.profilesPath;
    final exportProfiles = <UnifiedExportProfile>[];
    for (final profile in profiles) {
      final file = File(join(profilesPath, '${profile.id}.yaml'));
      if (!await file.exists()) {
        throw StateError(
          'Cannot create backup: profile ${profile.id} is missing its YAML file',
        );
      }
      final info = profile.subscriptionInfo;
      final materializedYaml = await materializeProfileForUnifiedExport(
        profileId: profile.id,
        profileBytes: await file.readAsBytes(),
        profilesDirectory: profilesPath,
        normalizeProviderContent: (bytes) async {
          final ready = await ensureRestoreValidationCoreReady(
            isConnected: coreController.isCompleted,
            connectCore: ref.read(coreActionProvider.notifier).connectCore,
            isCoreInitialized: () async => coreController.isInit,
            initializeCore: () =>
                coreController.init(ref.read(versionProvider)),
          );
          if (!ready) {
            throw StateError(
              currentAppLocalizations.proxyCoreCannotReadProvider,
            );
          }
          return coreController.normalizeProviderContent(bytes);
        },
      );
      exportProfiles.add(
        UnifiedExportProfile(
          androidId: profile.id,
          name: profile.realLabel,
          sourceUrl: profile.url,
          yaml: materializedYaml.yaml,
          providerSourceYaml: materializedYaml.providerSourceYaml,
          updated:
              (profile.lastUpdateDate ?? DateTime.fromMillisecondsSinceEpoch(0))
                  .millisecondsSinceEpoch ~/
              1000,
          autoUpdate: profile.realAutoUpdate,
          updateIntervalMinutes: profile.autoUpdateDuration.inMinutes,
          subscriptionInfo: info == null
              ? null
              : {
                  'upload': info.upload,
                  'download': info.download,
                  'total': info.total,
                  'expire': info.expire,
                },
          externalProvidersFlattened:
              materializedYaml.externalProvidersFlattened,
          localFile: profile.type == ProfileType.file,
        ),
      );
    }
    final importedArchiveFile = File(await appPath.workerUnifiedArchivePath);
    final trustedArchive = await importedArchiveFile.exists()
        ? await importedArchiveFile.readAsBytes()
        : null;
    final bytes = const UnifiedV1Exporter().build(
      UnifiedExportInput(
        profiles: exportProfiles,
        currentAndroidId: currentProfileId,
        trustedArchive: trustedArchive,
        generatorVersion: '1.0.0',
      ),
    );
    final target = File(await appPath.tempFilePath);
    await target.writeAsBytes(bytes, flush: true);
    return target.path;
  }

  Future<BackupRestoreOutcome> restore() async {
    final restoreWatch = Stopwatch()..start();
    final restoreStrategy = ref.read(
      appSettingProvider.select((state) => state.restoreStrategy),
    );
    final backup = File(await appPath.backupFilePath);
    final archiveLength = await backup.length();
    commonPrint.log(
      'backup-restore:start strategy=${restoreStrategy.name} archiveBytes=$archiveLength',
    );
    await validateBackupArchiveFile(backup);
    commonPrint.log(
      'backup-restore:archive-validated elapsedMs=${restoreWatch.elapsedMilliseconds}',
    );
    final coreWatch = Stopwatch()..start();
    final coreReady = await ensureRestoreValidationCoreReady(
      isConnected: coreController.isCompleted,
      connectCore: ref.read(coreActionProvider.notifier).connectCore,
      isCoreInitialized: () async => coreController.isInit,
      initializeCore: () => coreController.init(ref.read(versionProvider)),
    );
    commonPrint.log(
      'backup-restore:core-ready elapsedMs=${coreWatch.elapsedMilliseconds} ready=$coreReady',
    );
    if (!coreReady) {
      throw StateError(currentAppLocalizations.proxyCoreCannotValidateBackup);
    }
    final result =
        await UnifiedBackupService(
          database: database,
          paths: RestorePaths(
            profilesDirectory: await appPath.profilesPath,
            scriptsDirectory: await appPath.scriptsDirPath,
            workerUnifiedArchivePath: await appPath.workerUnifiedArchivePath,
          ),
          validateProfileYaml: (profileId, bytes) async {
            final temporary = File(await appPath.tempFilePath);
            try {
              await temporary.writeAsBytes(bytes, flush: true);
              final message = await coreController.validateConfig(
                temporary.path,
              );
              if (message.isNotEmpty) throw message;
            } finally {
              await temporary.safeDelete();
            }
          },
          readConfig: preferences.getConfig,
          writeConfig: preferences.saveConfig,
          onProgress: (stage, profileCount) {
            commonPrint.log(
              'backup-restore:$stage elapsedMs=${restoreWatch.elapsedMilliseconds} '
              'profileCount=${profileCount ?? '-'}',
            );
          },
        ).restoreBytes(
          await backup.readAsBytes(),
          override: restoreStrategy == RestoreStrategy.override,
        );
    final restoredProfiles = await database.profilesDao.query().get();
    commonPrint.log(
      'backup-restore:state-reloaded elapsedMs=${restoreWatch.elapsedMilliseconds} '
      'profileCount=${restoredProfiles.length} currentProfileId=${result.currentProfileId}',
    );
    ref.read(profilesProvider.notifier).resetFromRestore(restoredProfiles);
    ref.read(providersProvider.notifier).clear();
    ref.read(groupsProvider.notifier).value = const [];
    ref.read(groupsOwnerProfileIdProvider.notifier).set(null);
    ref.read(proxyGroupsSnapshotProvider.notifier).none();
    ref.read(delayDataSourceProvider.notifier).value = const {};
    ref
        .read(proxiesActionProvider.notifier)
        .beginRuntimeProfileTransition(result.currentProfileId);
    ref.read(currentProfileIdProvider.notifier).value = result.currentProfileId;
    if (result.config case final restoredConfig?) {
      ref.read(appSettingProvider.notifier).value =
          restoredConfig.appSettingProps;
      ref.read(windowSettingProvider.notifier).value =
          restoredConfig.windowProps;
      ref.read(vpnSettingProvider.notifier).value = restoredConfig.vpnProps;
      ref.read(networkSettingProvider.notifier).value =
          restoredConfig.networkProps;
      ref.read(themeSettingProvider.notifier).value = restoredConfig.themeProps;
      ref.read(davSettingProvider.notifier).value = restoredConfig.davProps;
      ref.read(overrideDnsProvider.notifier).value = restoredConfig.overrideDns;
      ref.read(hotKeyActionsProvider.notifier).value =
          restoredConfig.hotKeyActions;
      ref.read(proxiesStyleSettingProvider.notifier).value =
          restoredConfig.proxiesStyleProps;
      ref.read(patchClashConfigProvider.notifier).value =
          restoredConfig.patchClashConfig;
    }
    final readiness = await ref
        .read(proxiesActionProvider.notifier)
        .ensureCurrentProfileReady(forceApply: true);
    final succeeded =
        readiness.status == ProviderReadinessStatus.ready ||
        readiness.status == ProviderReadinessStatus.noProviders;
    commonPrint.log(
      'backup-restore:completed elapsedMs=${restoreWatch.elapsedMilliseconds} '
      'committed=true activation=${readiness.status.name} '
      'providerCount=${readiness.providerCount} groupCount=${readiness.groupCount}',
      logLevel: succeeded ? LogLevel.info : LogLevel.warning,
    );
    return BackupRestoreOutcome(
      committed: true,
      activationSucceeded: succeeded,
      activationError: succeeded
          ? null
          : readiness.error?.toString() ??
                'Provider and proxy groups are not ready yet',
      providerReadinessStatus: readiness.status,
    );
  }
}

@Riverpod(keepAlive: true)
class CoreAction extends _$CoreAction {
  Future<bool>? _connectCoreFuture;
  Future<bool>? _ensureCoreReadyFuture;

  @override
  void build() {}

  Future<void> initCore({
    bool deferGroupSetup = false,
    bool callerOwnsProfileActivation = false,
  }) async {
    final wasInitialized = await coreController.isInit;
    final ready = await ensureCoreReady();
    StartupTrace.mark('ensureCoreReady');
    if (!ready) return;
    if (deferGroupSetup) {
      return;
    }
    if (!wasInitialized) {
      final profileId = ref.read(currentProfileIdProvider);
      if (shouldInitCoreForceApply(
        wasInitialized: false,
        deferGroupSetup: false,
        callerOwnsProfileActivation: callerOwnsProfileActivation,
        hasCurrentProfile: profileId != null,
        groupsNeedRefresh: true,
      )) {
        ref.invalidate(clashConfigProvider(profileId!));
        unawaited(
          ref
              .read(proxiesActionProvider.notifier)
              .ensureCurrentProfileReady(forceApply: true),
        );
      }
    } else {
      final profileId = ref.read(currentProfileIdProvider);
      final ownerId = ref.read(groupsOwnerProfileIdProvider);
      final groupsNeedRefresh =
          profileId != null &&
          (ownerId != profileId || ref.read(groupsProvider).isEmpty);
      if (shouldInitCoreForceApply(
        wasInitialized: true,
        deferGroupSetup: false,
        callerOwnsProfileActivation: callerOwnsProfileActivation,
        hasCurrentProfile: profileId != null,
        groupsNeedRefresh: groupsNeedRefresh,
      )) {
        ref.invalidate(clashConfigProvider(profileId!));
        unawaited(
          ref
              .read(proxiesActionProvider.notifier)
              .ensureCurrentProfileReady(forceApply: true),
        );
      } else {
        await ref.read(proxiesActionProvider.notifier).updateGroups();
        StartupTrace.mark('initCore.groups');
      }
    }
  }

  Future<bool> connectCore({
    Duration minDelay = const Duration(milliseconds: 300),
  }) async {
    final running = _connectCoreFuture;
    if (running != null) {
      commonPrint.log('core-connect:reuse');
      return running;
    }
    final future = _connectCore(minDelay: minDelay);
    _connectCoreFuture = future;
    try {
      return await future;
    } finally {
      if (identical(_connectCoreFuture, future)) {
        _connectCoreFuture = null;
      }
    }
  }

  Future<bool> ensureCoreReady() async {
    final running = _ensureCoreReadyFuture;
    if (running != null) {
      commonPrint.log('core-ready:reuse');
      return running;
    }
    final future = _ensureCoreReady();
    _ensureCoreReadyFuture = future;
    try {
      return await future;
    } finally {
      if (identical(_ensureCoreReadyFuture, future)) {
        _ensureCoreReadyFuture = null;
      }
    }
  }

  Future<bool> _ensureCoreReady() async {
    final watch = Stopwatch()..start();
    if (!coreController.isCompleted && !await connectCore()) return false;
    if (await coreController.isInit) {
      commonPrint.log(
        'core-ready:already-initialized elapsedMs=${watch.elapsedMilliseconds}',
      );
      return true;
    }
    final initialized = await coreController.init(ref.read(versionProvider));
    commonPrint.log(
      'core-ready:initialized elapsedMs=${watch.elapsedMilliseconds} '
      'success=$initialized',
      logLevel: initialized ? LogLevel.info : LogLevel.warning,
    );
    if (!initialized) {
      ref.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
    }
    return initialized;
  }

  Future<bool> _connectCore({
    Duration minDelay = const Duration(milliseconds: 300),
  }) async {
    final watch = Stopwatch()..start();
    commonPrint.log('core-connect:start');
    ref.read(coreStatusProvider.notifier).value = CoreStatus.connecting;
    late final String message;
    final preload = coreController.preload().then((value) {
      message = value;
      StartupTrace.mark('preload');
      return value;
    });
    if (minDelay <= Duration.zero) {
      await preload;
    } else {
      await Future.wait([preload, Future.delayed(minDelay)]);
    }
    if (message.isNotEmpty) {
      ref.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
      final hasSession = ref
          .read(setupActionProvider.notifier)
          .hasProtectableVpnSessionNow;
      if (shouldNotifyRemoteServiceLoss(
        message: message,
        hasSession: hasSession,
      )) {
        globalState.showNotifier(message);
      } else {
        commonPrint.log(
          'core-connect:suppress-disconnect-notice',
          logLevel: LogLevel.warning,
        );
      }
      commonPrint.log(
        'core-connect:failed elapsedMs=${watch.elapsedMilliseconds}',
        logLevel: LogLevel.error,
      );
      return false;
    }
    ref.read(coreStatusProvider.notifier).value = CoreStatus.connected;
    commonPrint.log(
      'core-connect:ready elapsedMs=${watch.elapsedMilliseconds}',
    );
    return true;
  }

  Future<Result<bool>> requestAdmin(bool enableTun) async {
    final realTunEnable = ref.read(realTunEnableProvider);
    if (enableTun != realTunEnable && realTunEnable == false) {
      final code = await system.authorizeCore();
      switch (code) {
        case AuthorizeCode.success:
          await restartCore();
          return Result.error('');
        case AuthorizeCode.none:
          break;
        case AuthorizeCode.error:
          enableTun = false;
          break;
      }
    }
    ref.read(realTunEnableProvider.notifier).value = enableTun;
    return Result.success(enableTun);
  }

  Future<bool> restartCore([bool start = false]) async {
    final setupAction = ref.read(setupActionProvider.notifier);
    final intent = setupAction.lifecycleGeneration;
    final isDisconnected =
        ref.read(coreStatusProvider) == CoreStatus.disconnected;
    ref.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
    await coreController.shutdown(!isDisconnected);
    final connected = await connectCore();
    if (!connected) return false;
    final callerOwnsProfileActivation = start || ref.read(isStartProvider);
    await initCore(callerOwnsProfileActivation: callerOwnsProfileActivation);
    if (!setupAction.isCurrentLifecycle(intent)) return false;
    if (callerOwnsProfileActivation) {
      await ref
          .read(setupActionProvider.notifier)
          .updateStatus(true, isInit: true);
    } else {
      await ref.read(setupActionProvider.notifier).applyProfile(force: true);
    }
    return true;
  }

  Future<bool> tryStartCore([bool start = false]) async {
    if (coreController.isCompleted) return false;
    return restartCore(start);
  }

  void handleCoreDisconnected() {
    ref.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
  }
}

@Riverpod(keepAlive: true)
class SystemAction extends _$SystemAction {
  @override
  void build() {}

  Future<List<Package>> getPackages() async {
    if (ref.read(isMobileViewProvider)) {
      await Future.delayed(commonDuration);
    }
    if (ref.read(packagesProvider).isEmpty) {
      ref.read(packagesProvider.notifier).value =
          await app?.getPackages() ?? [];
    }
    return ref.read(packagesProvider);
  }

  Future<void> handleExit([bool needSave = false]) async {
    StartupTrace.mark(
      'application_shutdown_requested',
      extras: {
        'owner': 'system_action',
        'stop_proxy': proxy != null,
        'destroy_core': true,
      },
    );
    Future.delayed(const Duration(seconds: 3), () {
      system.exit();
    });
    try {
      await Future.wait([
        if (needSave) preferences.saveConfig(ref.read(configProvider)),
        if (proxy != null) proxy!.stopProxy(),
      ]);
      await coreController.destroy();
      StartupTrace.mark(
        'application_shutdown_complete',
        extras: {'owner': 'system_action'},
      );
      commonPrint.log('exit');
    } finally {
      system.exit();
    }
  }

  Future<void> handleBackOrExit() async {
    if (ref.read(backBlockProvider)) return;
    if (ref.read(appSettingProvider).minimizeOnExit) {
      await system.back();
    } else {
      await handleExit();
    }
  }

  void updateTun() {
    ref
        .read(patchClashConfigProvider.notifier)
        .update((state) => state.copyWith.tun(enable: !state.tun.enable));
  }

  void updateSystemProxy() {
    ref
        .read(networkSettingProvider.notifier)
        .update((state) => state.copyWith(systemProxy: !state.systemProxy));
  }

  void updateAutoLaunch() {
    ref
        .read(appSettingProvider.notifier)
        .update((state) => state.copyWith(autoLaunch: !state.autoLaunch));
  }

  Future<void> updateLocalIp() async {
    ref.read(localIpProvider.notifier).value = null;
    await Future.delayed(commonDuration);
    ref.read(localIpProvider.notifier).value = await utils.getLocalIpAddress();
  }
}

@Riverpod(keepAlive: true)
class StoreAction extends _$StoreAction {
  @override
  void build() {}

  Future<void> shakingStore() async {
    final profileIds = ref.read(
      profilesProvider.select((state) => state.map((item) => item.id)),
    );
    final scriptIds = await ref.read(
      scriptsProvider.future.select(
        (state) async => (await state).map((item) => item.id),
      ),
    );
    final pathsToDelete = await shakingProfileTask(VM2(profileIds, scriptIds));
    if (pathsToDelete.isNotEmpty) {
      final deleteFutures = pathsToDelete.map((path) async {
        try {
          final res = await coreController.deleteFile(path);
          if (res.isNotEmpty) throw res;
        } catch (e) {
          rethrow;
        }
      });
      await Future.wait(deleteFutures);
    }
  }

  void savePreferencesDebounce() {
    debouncer.call(FunctionTag.savePreferences, () async {
      await preferences.saveConfig(ref.read(configProvider));
    });
  }

  Future handleClear() async {
    _resetConfigState();
    await preferences.clearPreferences();
    commonPrint.log('clear preferences');
    await database.close();
    await _clearDirectoryContents(Directory(await appPath.homeDirPath));
    await _clearDirectoryContents(await appPath.cacheDir.future);
    await preferences.clearPreferences();
    ref.read(systemActionProvider.notifier).handleExit(false);
  }

  void _resetConfigState() {
    ref.read(appSettingProvider.notifier).value = defaultAppSettingProps;
    ref.read(windowSettingProvider.notifier).value = defaultWindowProps;
    ref.read(vpnSettingProvider.notifier).value = defaultVpnProps;
    ref.read(networkSettingProvider.notifier).value = defaultNetworkProps;
    ref.read(themeSettingProvider.notifier).value = defaultThemeProps;
    ref
        .read(proxiesActionProvider.notifier)
        .beginRuntimeProfileTransition(null);
    ref.read(currentProfileIdProvider.notifier).value = null;
    ref.read(davSettingProvider.notifier).value = null;
    ref.read(overrideDnsProvider.notifier).value = false;
    ref.read(hotKeyActionsProvider.notifier).value = [];
    ref.read(proxiesStyleSettingProvider.notifier).value =
        defaultProxiesStyleProps;
    ref.read(patchClashConfigProvider.notifier).value = defaultClashConfig;
  }

  Future<void> _clearDirectoryContents(Directory directory) async {
    if (!await directory.exists()) {
      return;
    }
    await for (final entity in directory.list()) {
      await entity.safeDelete(recursive: true);
    }
  }
}

@Riverpod(keepAlive: true)
class ThemeAction extends _$ThemeAction {
  @override
  void build() {}

  void updateBrightness() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(systemBrightnessProvider.notifier).value =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
    });
  }

  void updateViewSize(Size size) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(viewSizeProvider.notifier).value = size;
    });
  }
}

@Riverpod(keepAlive: true)
class ProxiesAction extends _$ProxiesAction {
  final Map<RuntimeProfileIdentity, Future<void>> _runningUpdateGroups = {};
  final Set<RuntimeProfileIdentity> _dirtyUpdateGroups = {};
  final ProxySelectionSession _selectionTxn = ProxySelectionSession();
  final PendingProxySelections _pendingSelections = PendingProxySelections();
  final RuntimeProviderProjectionSingleflight<ExternalProvider>
  _providerProjection = RuntimeProviderProjectionSingleflight();
  final Map<RuntimeProfileIdentity, Future<void>> _runningPreheats = {};
  final Set<String> _runtimeLoadingProviderKeys = {};
  int _runtimeEpoch = 0;
  int? _runtimeProfileId;
  RuntimeProfileIdentity? _activeRuntimeIdentity;

  late final ProviderReadinessService<ExternalProvider, Group>
  _providerReadiness = ProviderReadinessService(
    log: (stage, result, elapsed) {
      commonPrint.log(
        '$stage profileId=${result.profileId} elapsedMs=${elapsed.inMilliseconds} '
        'providerCount=${result.providerCount} groupCount=${result.groupCount} '
        'status=${result.status.name} lastError=${result.error ?? '-'}',
        logLevel:
            result.status == ProviderReadinessStatus.failed ||
                result.status == ProviderReadinessStatus.timeout ||
                result.status == ProviderReadinessStatus.coreUnavailable
            ? LogLevel.warning
            : LogLevel.info,
      );
    },
  );

  @override
  void build() {
    _runtimeProfileId = ref.read(currentProfileIdProvider);
    ref.listen(currentProfileIdProvider, (previous, next) {
      if (previous == next) return;
      _advanceRuntimeProfile(next);
    });
  }

  void _advanceRuntimeProfile(int? profileId) {
    if (_runtimeProfileId == profileId) return;
    for (final selection in _pendingSelections.clear()) {
      _selectionTxn.complete(
        _selectionKey(selection.identity, selection.groupName),
      );
    }
    _runtimeProfileId = profileId;
    _runtimeEpoch++;
    _activeRuntimeIdentity = null;
    _dirtyUpdateGroups.clear();
    ref.read(delayDataSourceProvider.notifier).clear();
    for (final key in _runtimeLoadingProviderKeys) {
      ref.read(isUpdatingProvider(key).notifier).value = false;
    }
    _runtimeLoadingProviderKeys.clear();
  }

  void beginRuntimeProfileTransition(int? profileId) {
    if (ref.read(currentProfileIdProvider) == profileId) return;
    _advanceRuntimeProfile(profileId);
  }

  RuntimeProfileIdentity? captureRuntimeProfileIdentity() {
    final profileId = ref.read(currentProfileIdProvider);
    if (_runtimeProfileId != profileId) {
      _advanceRuntimeProfile(profileId);
    }
    if (profileId == null) return null;
    return RuntimeProfileIdentity(profileId: profileId, epoch: _runtimeEpoch);
  }

  bool isRuntimeIdentityCurrent(RuntimeProfileIdentity identity) {
    return isRuntimeProfileIdentityCurrent(
      identity: identity,
      currentProfileId: ref.read(currentProfileIdProvider),
      currentEpoch: _runtimeEpoch,
    );
  }

  bool isRuntimeIdentityActive(RuntimeProfileIdentity identity) {
    return isRuntimeProfileIdentityActive(
      identity: identity,
      activeIdentity: _activeRuntimeIdentity,
      currentProfileId: ref.read(currentProfileIdProvider),
      currentEpoch: _runtimeEpoch,
    );
  }

  Future<bool> activateRuntimeIdentity(
    RuntimeProfileIdentity identity,
  ) async {
    if (!isRuntimeIdentityCurrent(identity)) return false;
    _activeRuntimeIdentity = identity;
    final pending = _pendingSelections.takeForActivation(identity);
    for (final selection in pending) {
      if (!isRuntimeIdentityActive(identity)) return false;
      try {
        await _dispatchSelection(selection);
      } catch (error) {
        commonPrint.log(
          'runtime-selection:activation-replay-failed '
          'profileId=${identity.profileId} group=${selection.groupName} '
          'error=$error',
          logLevel: LogLevel.warning,
        );
      }
    }
    return isRuntimeIdentityActive(identity);
  }

  Object _selectionKey(RuntimeProfileIdentity identity, String groupName) =>
      (identity, groupName);

  Future<ProviderReadinessResult> ensureCurrentProfileReady({
    bool forceApply = false,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final profileId = ref.read(currentProfileIdProvider);
    final identity = captureRuntimeProfileIdentity();
    ref.read(proxyGroupsSnapshotProvider.notifier).refreshing();
    if (profileId != null && !coreController.isCompleted) {
      final connected = await ref
          .read(coreActionProvider.notifier)
          .connectCore();
      if (ref.read(currentProfileIdProvider) != profileId) {
        return ProviderReadinessResult(
          status: ProviderReadinessStatus.profileChanged,
          profileId: profileId,
        );
      }
      if (!connected) {
        const error = ProviderReadinessCoreUnavailable();
        ref.read(proxyGroupsSnapshotProvider.notifier).failed(error);
        commonPrint.log(
          'provider-readiness:core-unavailable-before-config profileId=$profileId',
          logLevel: LogLevel.warning,
        );
        return ProviderReadinessResult(
          status: ProviderReadinessStatus.coreUnavailable,
          profileId: profileId,
          error: error,
        );
      }
    }
    final result = await _providerReadiness.ensureCurrentProfileReady(
      targetProfileId: profileId,
      currentProfileId: () => identity != null &&
              isRuntimeIdentityCurrent(identity)
          ? identity.profileId
          : null,
      readProviderDefinitions: () async {
        if (profileId == null) return (external: false, proxy: false);
        return readProfileProviderDefinitions(profileId);
      },
      ensureCoreReady: _ensureCoreReadyForDisplay,
      applyProfileForDisplay: () =>
          ref.read(setupActionProvider.notifier).applyProfileForReadiness(),
      syncProviders: () async {
        if (identity == null || !isRuntimeIdentityActive(identity)) {
          throw StateError('Runtime profile is not active');
        }
        final providers = await coreController.getExternalProviders();
        if (!isRuntimeIdentityActive(identity)) {
          throw StateError('Runtime profile activation changed');
        }
        return providers;
      },
      isProxyProvider: (provider) => provider.type.toLowerCase() == 'proxy',
      readGroups: () => _readRuntimeGroups(identity),
      groupsAreValid: _isSnapshotWritableGroups,
      commitReady: (providers, groups) =>
          _commitReady(identity, providers, groups),
      forceApply:
          forceApply || identity == null || !isRuntimeIdentityActive(identity),
      timeout: timeout,
    );
    if (ref.read(currentProfileIdProvider) != profileId) return result;
    switch (result.status) {
      case ProviderReadinessStatus.ready:
        break;
      case ProviderReadinessStatus.noProviders:
        ref.read(providersProvider.notifier).clear();
        await updateGroups();
        break;
      case ProviderReadinessStatus.timeout:
        ref
            .read(proxyGroupsSnapshotProvider.notifier)
            .failed(const ProviderReadinessTimeout());
        break;
      case ProviderReadinessStatus.coreUnavailable:
        ref
            .read(proxyGroupsSnapshotProvider.notifier)
            .failed(const ProviderReadinessCoreUnavailable());
        break;
      case ProviderReadinessStatus.failed:
        ref
            .read(proxyGroupsSnapshotProvider.notifier)
            .failed(result.error ?? StateError('Provider readiness failed'));
        break;
      case ProviderReadinessStatus.profileChanged:
        break;
    }
    return result;
  }

  Future<bool> _ensureCoreReadyForDisplay() async {
    return ref.read(coreActionProvider.notifier).ensureCoreReady();
  }

  Future<List<Group>> _readRuntimeGroups(
    RuntimeProfileIdentity? identity,
  ) async {
    if (identity == null || !isRuntimeIdentityActive(identity)) {
      throw StateError('Runtime profile is not active');
    }
    final sortType = ref.read(
      proxiesStyleSettingProvider.select((state) => state.sortType),
    );
    final delayMap = ref.read(delayDataSourceProvider);
    final testUrl = ref.read(
      appSettingProvider.select((state) => state.testUrl),
    );
    final selectedMap = ref.read(
      currentProfileProvider.select((state) => state?.selectedMap ?? {}),
    );
    final groups = await coreController.getProxiesGroups(
      selectedMap: selectedMap,
      sortType: sortType,
      delayMap: delayMap,
      defaultTestUrl: testUrl,
    );
    if (!isRuntimeIdentityActive(identity)) {
      throw StateError('Runtime profile activation changed');
    }
    return groups;
  }

  Future<void> _commitReady(
    RuntimeProfileIdentity? identity,
    List<ExternalProvider> providers,
    List<Group> groups,
  ) async {
    if (identity == null ||
        !isRuntimeIdentityActive(identity) ||
        !_isSnapshotWritableGroups(groups)) {
      return;
    }
    final profileId = identity.profileId;
    ref.read(providersProvider.notifier).value = providers;
    ref.read(groupsProvider.notifier).value = groups;
    ref.read(groupsOwnerProfileIdProvider.notifier).set(profileId);
    ref.read(lastGroupsRefreshAtProvider.notifier).update();
    ref.read(proxyGroupsSnapshotProvider.notifier).fresh();
    final profile = _findProfileById(profileId);
    if (profile != null) {
      await _putProxyGroupsSnapshot(profile: profile, groups: groups);
    }
    if (isRuntimeIdentityActive(identity)) {
      _syncComputedSelectedMap(groups);
      schedulePostActivationPreheat(identity);
    }
  }

  bool _groupsEqual(List<Group> a, List<Group> b) => groupsListsEqual(a, b);

  void captureSelectionBaseline(
    RuntimeProfileIdentity identity,
    String groupName,
  ) {
    final profile = _findProfileById(identity.profileId);
    _selectionTxn.captureBaseline(
      _selectionKey(identity, groupName),
      profile?.selectedMap[groupName],
    );
  }

  void _syncComputedSelectedMap(List<Group> groups) {
    final base = ref.read(currentProfileProvider)?.computedSelectedMap ?? {};
    final map = ref
        .read(computedSelectedCacheProvider.notifier)
        .syncFromGroups(groups, base: base);
    ref
        .read(profilesActionProvider.notifier)
        .updateCurrentComputedSelectedMap(map);
  }

  void updateGroupsDebounce({Duration? duration, int? expectedProfileId}) {
    final identity = captureRuntimeProfileIdentity();
    if (identity == null ||
        (expectedProfileId != null &&
            expectedProfileId != identity.profileId)) {
      return;
    }
    scheduleRuntimeProjectionRefresh(
      scheduler: debouncer,
      tag: FunctionTag.updateGroups,
      expectedProfileId: identity.profileId,
      currentProfileId: () => isRuntimeIdentityActive(identity)
          ? identity.profileId
          : null,
      refresh: updateGroups,
      duration: duration,
    );
  }

  void changeProxyDebounce(
    RuntimeProfileIdentity identity,
    String groupName,
    String proxyName, {
    int gen = 0,
  }) {
    _scheduleSelectionDebounce(
      identity: identity,
      groupName: groupName,
      proxyName: proxyName,
      unfix: false,
      gen: gen,
    );
  }

  void unfixProxyDebounce(
    RuntimeProfileIdentity identity,
    String groupName, {
    int gen = 0,
  }) {
    _scheduleSelectionDebounce(
      identity: identity,
      groupName: groupName,
      proxyName: '',
      unfix: true,
      gen: gen,
    );
  }

  void _scheduleSelectionDebounce({
    required RuntimeProfileIdentity identity,
    required String groupName,
    required String proxyName,
    required bool unfix,
    int gen = 0,
  }) {
    final selection = (
      identity: identity,
      groupName: groupName,
      proxyName: proxyName,
      unfix: unfix,
      gen: gen,
    );
    _pendingSelections.remember(selection);
    debouncer.call(
      proxySelectionDebounceTag(groupName, identity),
      (PendingProxySelection selection) async {
        final identity = selection.identity;
        final selectionKey = _selectionKey(identity, selection.groupName);
        if (!isRuntimeIdentityCurrent(identity)) {
          _pendingSelections.takeForDispatch(selection);
          _selectionTxn.complete(selectionKey);
          return;
        }
        if (!isRuntimeIdentityActive(identity)) return;
        final latest = _pendingSelections.takeForDispatch(selection);
        if (latest == null) return;
        await _dispatchSelection(latest);
      },
      args: [selection],
    );
  }

  Future<void> _dispatchSelection(PendingProxySelection selection) async {
    final identity = selection.identity;
    if (!isRuntimeIdentityActive(identity)) return;
    ProxyTrace.noteSelectDispatch(
      gen: selection.gen,
      group: selection.groupName,
      proxy: selection.proxyName,
    );
    if (selection.unfix) {
      await unfixProxy(
        identity: identity,
        groupName: selection.groupName,
        gen: selection.gen,
      );
    } else {
      await changeProxy(
        identity: identity,
        groupName: selection.groupName,
        proxyName: selection.proxyName,
        gen: selection.gen,
      );
    }
    if (isRuntimeIdentityActive(identity)) {
      updateGroupsDebounce(expectedProfileId: identity.profileId);
    }
  }

  Future<String?> _computeProfileFingerprint(Profile? profile) async {
    if (profile == null) return null;

    // 读取 profile config 文件 SHA-256 作为主依据
    String profileFileSha256 = '';
    try {
      final path = await appPath.getProfilePath(profile.id.toString());
      final file = File(path);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        profileFileSha256 = await compute(_profileBytesFingerprint, bytes);
      }
    } catch (e) {
      commonPrint.log('compute profile file sha256 failed: $e');
    }

    // selectedMap 稳定排序后计算 SHA-256
    final selectedEntries = profile.selectedMap.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final selectedMapStableJson = jsonEncode(Map.fromEntries(selectedEntries));
    final selectedMapSha256 = sha256
        .convert(utf8.encode(selectedMapStableJson))
        .toString();

    final parts = <Object?>[
      'snapshot_v$kProxyGroupsSnapshotVersion',
      profile.id,
      profileFileSha256,
      profile.overwriteType.index,
      profile.scriptId ?? 0,
      profile.lastUpdateDate?.millisecondsSinceEpoch ?? 0,
      selectedMapSha256,
    ];

    return sha256.convert(utf8.encode(parts.join('|'))).toString();
  }

  Profile? _findProfileById(int profileId) {
    for (final profile in ref.read(profilesProvider)) {
      if (profile.id == profileId) return profile;
    }
    return null;
  }

  Future<bool> hydrateProxyGroupsSnapshot({
    int? profileId,
    bool allowStaleOnFingerprintMismatch = false,
  }) async {
    final targetProfileId = profileId ?? ref.read(currentProfileIdProvider);
    if (targetProfileId == null) {
      ref.read(proxyGroupsSnapshotProvider.notifier).none();
      return false;
    }

    try {
      final snapshot = await database.proxyGroupsSnapshotsDao.getSnapshot(
        targetProfileId,
      );

      if (snapshot == null || snapshot.groups.isEmpty) {
        if (profileId == null) {
          ref.read(proxyGroupsSnapshotProvider.notifier).none();
        }
        return false;
      }

      // Snapshot hydration publishes global projection state, so an explicit
      // target must still be the profile currently selected by the UI.
      if (ref.read(currentProfileProvider)?.id != targetProfileId) {
        return false;
      }

      // version compatibility check
      if (snapshot.snapshotVersion > kProxyGroupsSnapshotVersion) {
        commonPrint.log('snapshot version incompatible, discarding');
        ref.read(proxyGroupsSnapshotProvider.notifier).none();
        return false;
      }

      // fingerprint 校验：不匹配则丢弃 snapshot
      final profile = _findProfileById(targetProfileId);
      if (profile == null) {
        ref.read(proxyGroupsSnapshotProvider.notifier).none();
        return false;
      }
      final currentFingerprint = await _computeProfileFingerprint(profile);
      if (ref.read(currentProfileIdProvider) != targetProfileId) {
        return false;
      }
      if (snapshot.profileFingerprint == null ||
          snapshot.profileFingerprint != currentFingerprint) {
        commonPrint.log(
          'snapshot fingerprint mismatch: profileId=$targetProfileId, '
          'allowStale=$allowStaleOnFingerprintMismatch',
          logLevel: allowStaleOnFingerprintMismatch
              ? LogLevel.warning
              : LogLevel.info,
        );
        if (!allowStaleOnFingerprintMismatch) {
          return false;
        }
      }

      ref.read(groupsProvider.notifier).value = snapshot.groups;
      ref.read(groupsOwnerProfileIdProvider.notifier).set(targetProfileId);
      ref
          .read(proxyGroupsSnapshotProvider.notifier)
          .stale(updatedAt: snapshot.updatedAt);
      return true;
    } catch (e) {
      commonPrint.log('hydrateProxyGroupsSnapshot failed: $e');
      if (ref.read(currentProfileIdProvider) == targetProfileId) {
        ref.read(proxyGroupsSnapshotProvider.notifier).none();
      }
      return false;
    }
  }

  bool _isSnapshotWritableGroups(List<Group> groups) {
    return groups.isNotEmpty && groups.every((g) => g.all.isNotEmpty);
  }

  Future<bool> _putProxyGroupsSnapshot({
    required Profile profile,
    required List<Group> groups,
  }) async {
    if (!_isSnapshotWritableGroups(groups)) return false;
    final fingerprint = await _computeProfileFingerprint(profile);
    if (fingerprint == null) return false;
    final latestProfile = _findProfileById(profile.id);
    if (latestProfile == null) return false;
    final latestFingerprint = await _computeProfileFingerprint(latestProfile);
    if (latestFingerprint != fingerprint) return false;
    return database.putProfileSnapshotIfExists(
      profileId: profile.id,
      groups: groups,
      profileFingerprint: fingerprint,
    );
  }

  Future<void> updateGroups({RuntimeConfigPostUpdateContext? commitContext}) {
    final profile =
        commitContext?.targetProfile ?? ref.read(currentProfileProvider);
    if (profile == null) {
      commonPrint.log('update-groups:skipped reason=no-profile');
      return Future.value();
    }
    final profileId = profile.id;
    final identity = captureRuntimeProfileIdentity();
    if (identity == null ||
        identity.profileId != profileId ||
        !isRuntimeIdentityActive(identity)) {
      commonPrint.log(
        'update-groups:skipped reason=runtime-not-active profileId=$profileId',
      );
      return Future.value();
    }
    if (commitContext != null) {
      // This refresh is part of an active config commit. It must use its own
      // continuation-aware fallback rather than await a possibly unrelated
      // in-flight refresh that may itself be waiting for config ownership.
      return _updateGroups(
        profile,
        identity: identity,
        commitContext: commitContext,
      );
    }
    final running = _runningUpdateGroups[identity];
    if (running != null) {
      _dirtyUpdateGroups.add(identity);
      commonPrint.log('update-groups:reuse profileId=$profileId');
      return running;
    }
    final future = runTrailingRuntimeRefreshLoop(
      isActive: () => isRuntimeIdentityActive(identity),
      takeDirty: () => _dirtyUpdateGroups.remove(identity),
      refresh: () => _updateGroups(profile, identity: identity),
      onTrailing: () {
        StartupTrace.mark(
          'proxy_groups_trailing_refresh',
          extras: {'profileId': identity.profileId, 'epoch': identity.epoch},
        );
      },
    );
    _runningUpdateGroups[identity] = future;
    future.whenComplete(() {
      if (identical(_runningUpdateGroups[identity], future)) {
        _runningUpdateGroups.remove(identity);
        _dirtyUpdateGroups.remove(identity);
      }
    });
    return future;
  }

  Future<void> _updateGroups(
    Profile targetProfile, {
    required RuntimeProfileIdentity identity,
    RuntimeConfigPostUpdateContext? commitContext,
  }) async {
    final profileId = targetProfile.id;
    final selectedMap = Map<String, String>.from(targetProfile.selectedMap);
    bool targetIsCurrent() => isRuntimeIdentityActive(identity);
    final watch = Stopwatch()..start();

    try {
      if (!targetIsCurrent()) return;
      ref.read(proxyGroupsSnapshotProvider.notifier).refreshing();

      commonPrint.log('update-groups:start profileId=$profileId');
      final coreReady = await _ensureCoreReadyForDisplay();
      if (!targetIsCurrent()) return;
      if (!coreReady) {
        final ownerProfileId = ref.read(groupsOwnerProfileIdProvider);
        final oldGroups = ref.read(groupsProvider);
        final hasSameProfileOldGroups =
            ownerProfileId == profileId && oldGroups.isNotEmpty;

        if (hasSameProfileOldGroups) {
          StartupTrace.mark(
            'proxy_groups_core_unavailable',
            extras: {'path': 'same_profile_old', 'profileId': profileId},
          );
          ref
              .read(proxyGroupsSnapshotProvider.notifier)
              .failed('connectCore failed');
          return;
        }

        final hydrated = await hydrateProxyGroupsSnapshot(
          profileId: profileId,
          allowStaleOnFingerprintMismatch: true,
        );
        if (!targetIsCurrent()) return;

        if (hydrated) {
          StartupTrace.mark(
            'proxy_groups_core_unavailable',
            extras: {'path': 'stale_snapshot', 'profileId': profileId},
          );
          commonPrint.log(
            'updateGroups connectCore failed, fallback to stale snapshot: profileId=$profileId',
            logLevel: LogLevel.warning,
          );
          ref
              .read(proxyGroupsSnapshotProvider.notifier)
              .failed('connectCore failed');
          return;
        }

        commonPrint.log(
          'updateGroups preserve empty fallback: profileId=$profileId, '
          'reason=connectCore failed, ownerProfileId=$ownerProfileId, '
          'oldGroups=${oldGroups.length}',
          logLevel: LogLevel.warning,
        );
        StartupTrace.mark(
          'proxy_groups_core_unavailable',
          extras: {'path': 'empty', 'profileId': profileId},
        );

        ref
            .read(proxyGroupsSnapshotProvider.notifier)
            .failed('connectCore failed');
        return;
      }
      Future<List<Group>> loadGroups() {
        return retry(
          task: () async {
            final sortType = ref.read(
              proxiesStyleSettingProvider.select((state) => state.sortType),
            );
            final delayMap = ref.read(delayDataSourceProvider);
            final testUrl = ref.read(
              appSettingProvider.select((state) => state.testUrl),
            );
            return coreController.getProxiesGroups(
              selectedMap: selectedMap,
              sortType: sortType,
              delayMap: delayMap,
              defaultTestUrl: testUrl,
            );
          },
          retryIf: (res) => res.isEmpty || res.any((g) => g.all.isEmpty),
        );
      }

      var groups = await loadGroups();
      if (!targetIsCurrent()) return;
      if (!_isSnapshotWritableGroups(groups)) {
        final displayOutcome = await ref
            .read(setupActionProvider.notifier)
            ._applyProfileForDisplayOutcome(inheritedContext: commitContext);
        if (displayOutcome == SetupConfigOutcome.superseded) return;
        if (!targetIsCurrent()) return;
        groups = await loadGroups();
        if (!targetIsCurrent()) return;
      }

      if (!_isSnapshotWritableGroups(groups)) {
        final ownerProfileId = ref.read(groupsOwnerProfileIdProvider);
        final oldGroups = ref.read(groupsProvider);

        if (ownerProfileId == profileId && oldGroups.isNotEmpty) {
          commonPrint.log(
            'updateGroups groups empty, preserve same-profile old groups: '
            'profileId=$profileId, oldGroups=${oldGroups.length}',
            logLevel: LogLevel.warning,
          );
          ref.read(proxyGroupsSnapshotProvider.notifier).failed('groups empty');
          return;
        }

        final hydrated = await hydrateProxyGroupsSnapshot(
          profileId: profileId,
          allowStaleOnFingerprintMismatch: true,
        );
        if (!targetIsCurrent()) return;

        if (hydrated) {
          commonPrint.log(
            'updateGroups groups empty, fallback to stale snapshot: '
            'profileId=$profileId',
            logLevel: LogLevel.warning,
          );
          ref.read(proxyGroupsSnapshotProvider.notifier).failed('groups empty');
          return;
        }

        commonPrint.log(
          'updateGroups groups empty, no old groups or snapshot fallback: '
          'profileId=$profileId, ownerProfileId=$ownerProfileId, '
          'oldGroups=${oldGroups.length}',
          logLevel: LogLevel.error,
        );

        ref.read(proxyGroupsSnapshotProvider.notifier).failed('groups empty');
        return;
      }

      // profileId guard: user may have switched profile during async refresh
      if (!targetIsCurrent()) {
        StartupTrace.mark(
          'proxy_groups_owner_guard',
          extras: {
            'requested': profileId,
            'current': ref.read(currentProfileProvider)?.id,
          },
        );
        return;
      }

      // Equality check: skip UI rebuild + snapshot save if groups unchanged
      final oldGroups = ref.read(groupsProvider);
      if (_groupsEqual(oldGroups, groups)) {
        ref.read(lastGroupsRefreshAtProvider.notifier).update();
        ref.read(groupsOwnerProfileIdProvider.notifier).set(profileId);
        ref.read(proxyGroupsSnapshotProvider.notifier).fresh();
        _syncComputedSelectedMap(groups);
        ProxyTrace.noteGroupsConsistent(groups);
        return;
      }

      ref.read(groupsProvider.notifier).value = groups;
      ref.read(groupsOwnerProfileIdProvider.notifier).set(profileId);
      ref.read(proxyGroupsSnapshotProvider.notifier).fresh();
      ref.read(lastGroupsRefreshAtProvider.notifier).update();

      // Save snapshot
      await _putProxyGroupsSnapshot(profile: targetProfile, groups: groups);

      if (!targetIsCurrent()) return;
      _syncComputedSelectedMap(groups);
      ProxyTrace.noteGroupsConsistent(groups);
    } catch (e) {
      if (!targetIsCurrent()) return;
      commonPrint.log(
        'update-groups:error profileId=$profileId '
        'elapsedMs=${watch.elapsedMilliseconds} error=$e',
        logLevel: LogLevel.error,
      );

      final ownerProfileId = ref.read(groupsOwnerProfileIdProvider);
      final oldGroups = ref.read(groupsProvider);
      final hasSameProfileOldGroups =
          ownerProfileId == profileId && oldGroups.isNotEmpty;

      if (hasSameProfileOldGroups) {
        ref.read(proxyGroupsSnapshotProvider.notifier).failed(e);
        return;
      }

      final hydrated = await hydrateProxyGroupsSnapshot(
        profileId: profileId,
        allowStaleOnFingerprintMismatch: true,
      );
      if (!targetIsCurrent()) return;

      if (hydrated) {
        commonPrint.log(
          'updateGroups error fallback to stale snapshot: profileId=$profileId, error=$e',
          logLevel: LogLevel.warning,
        );
        ref.read(proxyGroupsSnapshotProvider.notifier).failed(e);
        return;
      }

      commonPrint.log(
        'updateGroups failed without fallback: profileId=$profileId, '
        'ownerProfileId=$ownerProfileId, oldGroups=${oldGroups.length}, error=$e',
        logLevel: LogLevel.error,
      );

      ref.read(proxyGroupsSnapshotProvider.notifier).failed(e);
    } finally {
      final ownerProfileId = ref.read(groupsOwnerProfileIdProvider);
      final groupCount = ownerProfileId == profileId
          ? ref.read(groupsProvider).length
          : 0;
      commonPrint.log(
        'update-groups:completed profileId=$profileId '
        'elapsedMs=${watch.elapsedMilliseconds} groupCount=$groupCount '
        'currentProfileId=${ref.read(currentProfileIdProvider)}',
      );
    }
  }

  final _prefetchingProfileIds = <int>{};

  Future<void> prefetchSnapshotForProfile(Profile profile) async {
    if (!_prefetchingProfileIds.add(profile.id)) return;
    try {
      final fingerprint = await _computeProfileFingerprint(profile);
      if (fingerprint == null) return;

      final sortType = ref.read(
        proxiesStyleSettingProvider.select((state) => state.sortType),
      );
      final delayMap = ref.read(delayDataSourceProvider);
      final testUrl = ref.read(
        appSettingProvider.select((state) => state.testUrl),
      );

      final profilePath = await appPath.getProfilePath(profile.id.toString());

      final groups = await coreController.materializeProfileSnapshotGroups(
        profilePath: profilePath,
        selectedMap: profile.selectedMap,
        sortType: sortType,
        delayMap: delayMap,
        defaultTestUrl: testUrl,
      );

      if (!_isSnapshotWritableGroups(groups)) return;

      final latestProfile = _findProfileById(profile.id);
      if (latestProfile == null) return;

      final latestFingerprint = await _computeProfileFingerprint(latestProfile);
      if (fingerprint != latestFingerprint) {
        commonPrint.log(
          'prefetchSnapshotForProfile skipped: fingerprint changed '
          'profileId=${profile.id}',
        );
        return;
      }

      final persisted = await _putProxyGroupsSnapshot(
        profile: latestProfile,
        groups: groups,
      );
      if (!persisted) return;

      commonPrint.log(
        'prefetchSnapshotForProfile success: '
        'profileId=${profile.id}, groups=${groups.length}',
      );
    } catch (e) {
      commonPrint.log('prefetchSnapshotForProfile failed: $e');
    } finally {
      _prefetchingProfileIds.remove(profile.id);
    }
  }

  DateTime? _lastPreheatGroupsRefreshAt;

  void schedulePostActivationPreheat(RuntimeProfileIdentity identity) {
    if (!isRuntimeIdentityActive(identity) ||
        _runningPreheats.containsKey(identity)) {
      return;
    }
    final future = Future<void>(() => _preheatComputedGroups(identity));
    _runningPreheats[identity] = future;
    future.whenComplete(() {
      if (identical(_runningPreheats[identity], future)) {
        _runningPreheats.remove(identity);
      }
    });
  }

  Future<void> _preheatComputedGroups(
    RuntimeProfileIdentity identity,
  ) async {
    if (!isRuntimeIdentityActive(identity)) return;
    StartupTrace.mark(
      'proxy_preheat_started',
      extras: {'profileId': identity.profileId, 'epoch': identity.epoch},
    );
    final groups = ref.read(groupsProvider);
    if (groups.isEmpty) {
      StartupTrace.mark(
        'proxy_preheat_finished',
        extras: {
          'profileId': identity.profileId,
          'epoch': identity.epoch,
          'empty': true,
        },
      );
      return;
    }
    final testUrl = ref.read(
      appSettingProvider.select((state) => state.testUrl),
    );
    try {
      await warmUpComputedGroupDelays(
        groups: groups,
        defaultTestUrl: testUrl,
        delayLoader: coreController.getDelay,
        onDelay: (delay) => setDelayForRuntimeIdentity(identity, delay),
        shouldContinue: () => isRuntimeIdentityActive(identity),
      );
      if (!isRuntimeIdentityActive(identity)) {
        StartupTrace.mark(
          'proxy_preheat_cancelled',
          extras: {'profileId': identity.profileId, 'epoch': identity.epoch},
        );
        return;
      }
      StartupTrace.mark(
        'proxy_preheat_finished',
        extras: {'profileId': identity.profileId, 'epoch': identity.epoch},
      );
      // Throttle: skip if last refresh was < 5s ago
      final now = DateTime.now();
      if (_lastPreheatGroupsRefreshAt != null &&
          now.difference(_lastPreheatGroupsRefreshAt!) <
              const Duration(seconds: 5)) {
        return;
      }
      _lastPreheatGroupsRefreshAt = now;
      updateGroupsDebounce(expectedProfileId: identity.profileId);
    } catch (e) {
      commonPrint.log('preheatComputedGroups error: $e');
    }
  }

  void updateCurrentGroupName(String groupName) {
    final profile = ref.read(currentProfileProvider);
    if (profile == null || profile.currentGroupName == groupName) return;
    ref
        .read(profilesProvider.notifier)
        .put(profile.copyWith(currentGroupName: groupName));
  }

  void updateCurrentUnfoldSet(Set<String> value) {
    final currentProfile = ref.read(currentProfileProvider);
    if (currentProfile == null) return;
    ref
        .read(profilesProvider.notifier)
        .put(currentProfile.copyWith(unfoldSet: value));
  }

  void setDelay(Delay delay) {
    ref.read(delayDataSourceProvider.notifier).setDelay(delay);
  }

  bool setDelayForRuntimeIdentity(
    RuntimeProfileIdentity identity,
    Delay delay,
  ) {
    if (!isRuntimeIdentityActive(identity)) return false;
    setDelay(delay);
    return true;
  }

  Future<void> changeProxy({
    required RuntimeProfileIdentity identity,
    required String groupName,
    required String proxyName,
    int gen = 0,
  }) async {
    final selectionKey = _selectionKey(identity, groupName);
    final previous = _selectionTxn.peek(selectionKey);
    final mutation = await runRuntimeMutationIfCurrent(
      identity: identity,
      isCurrent: isRuntimeIdentityActive,
      mutation: () async => coreController.changeProxy(
        ChangeProxyParams(groupName: groupName, proxyName: proxyName),
      ),
    );
    if (!mutation.current) {
      _selectionTxn.complete(selectionKey);
      return;
    }
    final result = mutation.value!;
    ProxyTrace.noteSelectCoreAck(gen: gen, group: groupName, result: result);
    await _finishSelection(
      groupName: groupName,
      identity: identity,
      failedIntent: proxyName,
      previousIntent: previous,
      result: result,
    );
  }

  Future<void> unfixProxy({
    required RuntimeProfileIdentity identity,
    required String groupName,
    int gen = 0,
  }) async {
    final selectionKey = _selectionKey(identity, groupName);
    final previous = _selectionTxn.peek(selectionKey);
    final mutation = await runRuntimeMutationIfCurrent(
      identity: identity,
      isCurrent: isRuntimeIdentityActive,
      mutation: () async =>
          coreController.unfixProxy(UnfixProxyParams(groupName: groupName)),
    );
    if (!mutation.current) {
      _selectionTxn.complete(selectionKey);
      return;
    }
    final result = mutation.value!;
    ProxyTrace.noteSelectCoreAck(gen: gen, group: groupName, result: result);
    await _finishSelection(
      groupName: groupName,
      identity: identity,
      failedIntent: '',
      previousIntent: previous,
      result: result,
    );
  }

  Future<void> _finishSelection({
    required RuntimeProfileIdentity identity,
    required String groupName,
    required String failedIntent,
    required String? previousIntent,
    required String result,
  }) async {
    final selectionKey = _selectionKey(identity, groupName);
    if (!isRuntimeIdentityActive(identity)) {
      _selectionTxn.complete(selectionKey);
      return;
    }
    final targetProfile = _findProfileById(identity.profileId);
    if (targetProfile == null) {
      _selectionTxn.complete(selectionKey);
      return;
    }
    if (isCoreSelectionSuccess(result)) {
      final currentIntent = targetProfile.selectedMap[groupName];
      _selectionTxn.commitWithNewerIntent(
        groupName: selectionKey,
        committedValue: failedIntent,
        currentIntent: currentIntent,
      );
      if (!isRuntimeIdentityActive(identity)) return;
      if (ref.read(appSettingProvider).closeConnections) {
        await coreController.closeConnections();
      } else {
        await coreController.resetConnections();
      }
      if (!isRuntimeIdentityActive(identity)) return;
      ref.read(checkIpNumProvider.notifier).add();
      NetworkDiagnosticsRevision.bump(reason: 'selection_success');
      return;
    }
    final currentIntent = targetProfile.selectedMap[groupName];
    final rollback = shouldRollbackOptimisticIntent(
      currentIntent: currentIntent,
      failedIntent: failedIntent,
    );
    if (rollback) {
      ref
          .read(profilesActionProvider.notifier)
          .restoreSelectedMapEntryForProfile(
            identity.profileId,
            groupName,
            failedIntent: failedIntent,
            previousIntent: previousIntent,
          );
    }
    _selectionTxn.completeUnlessNewerIntent(
      groupName: selectionKey,
      newerIntentPending: !rollback && currentIntent != failedIntent,
    );
    globalState.showNotifier(result);
  }

  Future<ExternalProvider?> refreshExternalProviderProjection(
    RuntimeProfileIdentity identity,
    String providerName,
  ) {
    return _providerProjection.refresh(
      identity: identity,
      providerName: providerName,
      isActive: isRuntimeIdentityActive,
      fetch: () => coreController.getExternalProvider(providerName),
      publish: (provider) {
        ref.read(providersProvider.notifier).setProvider(provider);
      },
    );
  }

  Future<String?> updateProvider(
    ExternalProvider provider, {
    RuntimeProfileIdentity? identity,
    bool showLoading = false,
  }) async {
    final targetIdentity = identity ?? captureRuntimeProfileIdentity();
    if (targetIdentity == null || !isRuntimeIdentityActive(targetIdentity)) {
      return null;
    }
    final loadingKey = provider.updatingKey;
    try {
      if (showLoading) {
        _runtimeLoadingProviderKeys.add(loadingKey);
        ref.read(isUpdatingProvider(loadingKey).notifier).value = true;
      }
      final update = await runRuntimeMutationIfCurrent(
        identity: targetIdentity,
        isCurrent: isRuntimeIdentityActive,
        mutation: () =>
            coreController.updateExternalProvider(providerName: provider.name),
      );
      if (!update.current) return null;
      final message = update.value!;
      if (message.isNotEmpty) return message;
      await refreshExternalProviderProjection(targetIdentity, provider.name);
      if (!isRuntimeIdentityActive(targetIdentity)) return null;
      return '';
    } finally {
      if (showLoading && isRuntimeIdentityActive(targetIdentity)) {
        _runtimeLoadingProviderKeys.remove(loadingKey);
        ref.read(isUpdatingProvider(loadingKey).notifier).value = false;
      }
    }
  }

  Future<String?> sideLoadProvider({
    required RuntimeProfileIdentity identity,
    required ExternalProvider provider,
    required List<int> bytes,
  }) async {
    if (!isRuntimeIdentityActive(identity)) return null;
    final path = provider.path;
    if (path == null) return 'Provider path is unavailable';

    final fileWrite = await runRuntimeMutationIfCurrent(
      identity: identity,
      isCurrent: isRuntimeIdentityActive,
      mutation: () => File(path).safeWriteAsBytes(bytes),
    );
    if (!fileWrite.current) return null;

    final sideLoad = await runRuntimeMutationIfCurrent(
      identity: identity,
      isCurrent: isRuntimeIdentityActive,
      mutation: () => coreController.sideLoadExternalProvider(
        providerName: provider.name,
        data: utf8.decode(bytes),
      ),
    );
    if (!sideLoad.current) return null;
    final message = sideLoad.value!;
    if (message.isNotEmpty) return message;

    await refreshExternalProviderProjection(identity, provider.name);
    if (!isRuntimeIdentityActive(identity)) return null;
    return '';
  }
}

@Riverpod(keepAlive: true)
class ProfilesAction extends _$ProfilesAction {
  // Preparing the core is independent of starting/resuming the VPN.
  Future<T> _withSourceCore<T>(Future<T> Function() operation) =>
      runProfileSourceWithReadyCore(
        ensureReady: ref.read(coreActionProvider.notifier).ensureCoreReady,
        operation: operation,
      );

  Future<String> _validateSource(String path) =>
      _withSourceCore(() => coreController.validateConfig(path));
  @override
  void build() {}

  void updateSelectedMapEntryForProfile(
    int profileId,
    String groupName,
    String proxyName,
  ) {
    final targetProfile = ref.read(profilesProvider).getProfile(profileId);
    if (targetProfile != null &&
        targetProfile.selectedMap[groupName] != proxyName) {
      final selectedMap = Map<String, String>.from(targetProfile.selectedMap)
        ..[groupName] = proxyName;
      ref
          .read(profilesProvider.notifier)
          .put(targetProfile.copyWith(selectedMap: selectedMap));
    }
  }

  /// Restores [groupName] after a failed Core write. Null [value] removes the key.
  void restoreSelectedMapEntryForProfile(
    int profileId,
    String groupName, {
    required String failedIntent,
    required String? previousIntent,
  }) {
    final targetProfile = ref.read(profilesProvider).getProfile(profileId);
    if (targetProfile == null ||
        targetProfile.selectedMap[groupName] != failedIntent) {
      return;
    }
    final selectedMap = Map<String, String>.from(targetProfile.selectedMap);
    if (previousIntent == null) {
      selectedMap.remove(groupName);
    } else {
      selectedMap[groupName] = previousIntent;
    }
    ref
        .read(profilesProvider.notifier)
        .put(targetProfile.copyWith(selectedMap: selectedMap));
  }

  void updateCurrentComputedSelectedMap(
    Map<String, String> computedSelectedMap,
  ) {
    final currentProfile = ref.read(currentProfileProvider);
    if (currentProfile == null) return;
    final next = Map<String, String>.from(computedSelectedMap);
    final current = currentProfile.computedSelectedMap;
    final sameLength = current.length == next.length;
    final sameContent =
        sameLength && current.entries.every((e) => next[e.key] == e.value);
    if (sameContent) return;
    ref
        .read(profilesProvider.notifier)
        .put(currentProfile.copyWith(computedSelectedMap: next));
  }

  Future<void> deleteProfile(int id) async {
    await profileSourceMutationOwner.invalidateAndCommit(id, () async {
      await runAuthoritativeProfileDelete(
        commitDatabaseDelete: () => database.deleteProfileLifetime(id),
        applyCommittedProjection: () {
          ref.read(profilesProvider.notifier).applyCommittedDelete(id);
        },
        updateDesiredProfile: () async {
          await convergeDesiredProfileAfterDelete(
            deletedProfileId: id,
            currentProfileId: ref.read(currentProfileIdProvider),
            remainingProfiles: ref.read(profilesProvider),
            setCurrentProfileId: (profileId) {
              ref
                  .read(proxiesActionProvider.notifier)
                  .beginRuntimeProfileTransition(profileId);
              ref.read(currentProfileIdProvider.notifier).value = profileId;
            },
            stopLastProfile: () =>
                ref.read(setupActionProvider.notifier).updateStatus(false),
          );
        },
        cleanupResources: () => clearEffect(id),
      );
    });
  }

  Future<void> autoUpdateProfiles() async {
    await runAutoProfileRefreshLoop(
      capturedProfiles: ref.read(profilesProvider),
      refresh: (profile) async {
        await updateProfile(profile, publishInput: false);
      },
      onError: (error) {
        commonPrint.log(error.toString(), logLevel: LogLevel.warning);
      },
    );
  }

  void putProfile(Profile profile) {
    ref.read(profilesProvider.notifier).put(profile);
    if (ref.read(currentProfileIdProvider) != null) return;
    ref
        .read(proxiesActionProvider.notifier)
        .beginRuntimeProfileTransition(profile.id);
    ref.read(currentProfileIdProvider.notifier).value = profile.id;
  }

  Future<void> updateProfiles() async {
    for (final profile in ref.read(profilesProvider)) {
      if (profile.type == ProfileType.file) continue;
      await updateProfile(profile, publishInput: false);
    }
  }

  Future<ProfileSourceMutationOutcome> updateProfile(
    Profile profile, {
    bool showLoading = false,
    required bool publishInput,
    bool applyAfterCommit = true,
  }) async {
    final token = profileSourceMutationOwner.begin(profile.id);
    final sourceUrl = profile.url;
    try {
      if (showLoading) {
        ref.read(isUpdatingProvider(profile.updatingKey).notifier).value = true;
      }
      if (publishInput) {
        ref.read(profilesProvider.notifier).put(profile);
      }
      late final ProfileSourceResponse response;
      try {
        response = await profile.downloadSource();
      } catch (_) {
        if (!profileSourceMutationOwner.isCurrent(token)) {
          return ProfileSourceMutationOutcome.superseded;
        }
        rethrow;
      }
      final profilePath = await appPath.getProfilePath(profile.id.toString());
      late final StagedProfileFile staged;
      try {
        staged = await stageProfileFile(
          targetPath: profilePath,
          bytes: response.bytes,
          validate: _validateSource,
        );
      } catch (_) {
        if (!profileSourceMutationOwner.isCurrent(token)) {
          return ProfileSourceMutationOutcome.superseded;
        }
        rethrow;
      }
      Profile? committedProfile;
      var outcome = ProfileSourceMutationOutcome.superseded;
      try {
        outcome = await profileSourceMutationOwner.commit(token, () async {
          final latest = ref.read(profilesProvider).getProfile(profile.id);
          if (!isProfileSourceIdentityCurrent(
            latest,
            profileId: profile.id,
            sourceUrl: sourceUrl,
          )) {
            throw const ProfileSourceMutationSuperseded();
          }
          await staged.commit();
          committedProfile = mergeRemoteProfileResponse(
            latest!,
            response,
            updatedAt: DateTime.now(),
          );
          ref.read(profilesProvider.notifier).put(committedProfile!);
        });
      } on ProfileSourceMutationSuperseded {
        outcome = ProfileSourceMutationOutcome.superseded;
      } finally {
        await staged.dispose();
      }
      final newProfile = committedProfile;
      if (outcome == ProfileSourceMutationOutcome.superseded ||
          newProfile == null ||
          !applyAfterCommit) {
        return outcome;
      }
      // Only the current profile needs a full ApplyConfig. Unused subscriptions
      // stay as YAML until the user switches; prefetching them here kept a
      // second parsed tree alive in :remote after every sync.
      if (newProfile.id == ref.read(currentProfileIdProvider)) {
        ref
            .read(setupActionProvider.notifier)
            .applyProfileDebounce(silence: true);
      }
      return outcome;
    } finally {
      ref.read(isUpdatingProvider(profile.updatingKey).notifier).value = false;
    }
  }

  Future<ProfileSourceMutationOutcome> replaceProfileSource(
    Profile profile,
    Uint8List bytes,
  ) async {
    final token = profileSourceMutationOwner.begin(profile.id);
    ref.read(profilesProvider.notifier).put(profile);
    final profilePath = await appPath.getProfilePath(profile.id.toString());
    late final StagedProfileFile staged;
    try {
      staged = await stageProfileFile(
        targetPath: profilePath,
        bytes: bytes,
        validate: _validateSource,
      );
    } catch (_) {
      if (!profileSourceMutationOwner.isCurrent(token)) {
        return ProfileSourceMutationOutcome.superseded;
      }
      rethrow;
    }
    try {
      return await profileSourceMutationOwner.commit(token, () async {
        final latest = ref.read(profilesProvider).getProfile(profile.id);
        if (latest == null) {
          throw const ProfileSourceMutationSuperseded();
        }
        await staged.commit();
        ref
            .read(profilesProvider.notifier)
            .put(latest.copyWith(lastUpdateDate: DateTime.now()));
      });
    } on ProfileSourceMutationSuperseded {
      return ProfileSourceMutationOutcome.superseded;
    } finally {
      await staged.dispose();
    }
  }

  Future<void> addProfileFormFile() async {
    final platformFile = await globalState.safeRun(picker.pickerFile);
    final bytes = platformFile?.bytes;
    if (bytes == null) return;
    globalState.navigatorKey.currentState?.popUntil((route) => route.isFirst);
    ref.read(currentPageLabelProvider.notifier).toProfiles();
    final profile = await globalState.loadingRun(
      tag: LoadingTag.profiles,
      () async {
        return _withSourceCore(
          () => Profile.normal(label: platformFile?.name).saveFile(bytes),
        );
      },
      title: currentAppLocalizations.addProfile,
    );
    if (profile != null) {
      putProfile(profile);
    }
  }

  Future<void> addProfileFormURL(
    String url, {
    String? label,
    bool autoUpdate = true,
    Duration autoUpdateDuration = defaultUpdateDuration,
  }) async {
    if (globalState.navigatorKey.currentState?.canPop() ?? false) {
      globalState.navigatorKey.currentState?.popUntil((route) => route.isFirst);
    }
    ref.read(currentPageLabelProvider.notifier).value = PageLabel.profiles;
    final profile = await globalState.loadingRun(
      tag: LoadingTag.profiles,
      () async {
        final normalizedLabel = label?.trim();
        final profile =
            Profile.normal(
              url: url,
              label: normalizedLabel?.isNotEmpty == true
                  ? normalizedLabel
                  : null,
            ).copyWith(
              autoUpdate: autoUpdate,
              autoUpdateDuration: autoUpdateDuration,
            );
        return _withSourceCore(profile.update);
      },
      title: currentAppLocalizations.addProfile,
    );
    if (profile != null) {
      putProfile(profile);
    }
  }

  void setProfileAndAutoApply(Profile profile) {
    ref.read(profilesProvider.notifier).put(profile);
    if (profile.id == ref.read(currentProfileIdProvider)) {
      ref.read(setupActionProvider.notifier).applyProfileDebounce();
    }
  }

  Future<void> addProfileFormQrCode() async {
    final url = await globalState.safeRun(picker.pickerConfigQRCode);
    if (url == null) return;
    addProfileFormURL(url);
  }

  void reorder(List<Profile> profiles) {
    ref.read(profilesProvider.notifier).reorder(profiles);
  }

  Future<void> clearEffect(int profileId) async {
    final profilePath = await appPath.getProfilePath(profileId.toString());
    final providersDirPath = await appPath.getProvidersDirPath(
      profileId.toString(),
    );
    final profileFile = File(profilePath);
    final isExists = await profileFile.exists();
    if (isExists) {
      await profileFile.safeDelete(recursive: true);
    }
    final message = await coreController.deleteFile(providersDirPath);
    if (message.isNotEmpty) {
      throw ProfileResourceCleanupException(message);
    }
  }
}
