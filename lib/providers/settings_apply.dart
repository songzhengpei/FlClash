import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/services/settings/settings_apply_queue.dart';
import 'package:fl_clash/services/settings/settings_contract.dart';
import 'package:fl_clash/services/settings/settings_runtime.dart';
import 'action.dart';
import 'app.dart';
import 'config.dart';
import 'state.dart';
import 'smart_auto_stop.dart';

final settingsApplyProvider =
    NotifierProvider<SettingsApply, SettingsApplyStatus>(SettingsApply.new);

class SettingsApply extends Notifier<SettingsApplyStatus> {
  late SettingsApplyQueue _queue;

  @override
  SettingsApplyStatus build() {
    _queue = SettingsApplyQueue(
      baseline: settingsRuntimeRecord.value?.config ?? ref.read(configProvider),
      read: () => ref.read(configProvider),
      canApply: () =>
          ref.read(initProvider) &&
          ref.read(isStartProvider) &&
          !ref.read(isSmartStoppedProvider) &&
          ref.read(currentProfileIdProvider) != null,
      apply: (candidate, kind, latest) => ref
          .read(setupActionProvider.notifier)
          .applySettingsSnapshot(
            candidate: candidate,
            kind: kind,
            isLatest: latest,
          ),
      restorePreferences: (config) async {
        ref.read(patchClashConfigProvider.notifier).value =
            config.patchClashConfig;
        ref.read(vpnSettingProvider.notifier).value = config.vpnProps;
        ref.read(networkSettingProvider.notifier).value = config.networkProps;
        ref.read(overrideDnsProvider.notifier).value = config.overrideDns;
        await preferences.saveConfig(ref.read(configProvider));
      },
      onStatus: (next) {
        StartupTrace.mark(
          'settings_apply_state',
          extras: {
            'phase': next.phase.name,
            'reconnect': next.reconnect,
            if (next.error != null) 'error': next.error,
          },
        );
        state = next;
      },
    );
    ref.listen(configProvider, (previous, next) {
      if (previous != null) _queue.change(previous, next);
    });
    ref.listen(isStartProvider, (_, _) => _queue.sessionChanged());
    ref.listen(initProvider, (_, _) => _queue.sessionChanged());
    ref.listen(isSmartStoppedProvider, (_, _) => _queue.sessionChanged());
    void committed() {
      final record = settingsRuntimeRecord.value;
      if (record == null ||
          record.config.currentProfileId !=
              ref.read(currentProfileIdProvider)) {
        return;
      }
      _queue.acknowledged(record.config, savedRevision: record.savedEditRevision);
      ref.invalidate(dnsSettingsSourceProvider);
    }

    settingsRuntimeRecord.addListener(committed);
    ref.onDispose(() {
      settingsRuntimeRecord.removeListener(committed);
      _queue.dispose();
    });
    return const SettingsApplyStatus(SettingsApplyPhase.idle);
  }

  void retry() => _queue.retry();

  void savedEdit(int profileId, Future<void> Function() rollback) {
    if (profileId == ref.read(currentProfileIdProvider)) {
      _queue.savedEdit(rollback);
    }
  }
}

/// Source resolution shares script evaluation / ownership input with the real
/// materializer. Async provider invalidation prevents a previous profile result
/// from being published as the current profile's source.
final dnsSettingsSourceProvider = FutureProvider<DnsSettingsSource?>((
  ref,
) async {
  final profile = ref.watch(currentProfileProvider);
  final override = ref.watch(overrideDnsProvider);
  ref.watch(coreStatusProvider);
  if (profile == null || !coreController.isCompleted) return null;
  final snapshot = ref.read(configProvider);
  final setup = await ref.read(setupStateProvider(profile.id).future);
  bool? enabled;
  await ref
      .read(setupActionProvider.notifier)
      .getProfile(
        setupState: setup,
        patchConfig: snapshot.patchClashConfig,
        settingsSnapshot: snapshot,
        onDnsSource: (value) {
          enabled = value;
        },
      );
  return enabled == null
      ? null
      : dnsSettingsSource(sourceEnabled: enabled!, overrideDns: override);
});
