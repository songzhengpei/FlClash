import 'dart:async';
import 'dart:io';

import 'package:animations/animations.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:fl_clash/common/theme.dart';
import 'package:fl_clash/widgets/dialog.dart';
import 'package:fl_clash/widgets/input.dart';
import 'package:fl_clash/widgets/list.dart';
import 'package:fl_clash/widgets/surge/surge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_color_utilities/palettes/core_palette.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:url_launcher/url_launcher.dart';

import 'common/common.dart';
import 'database/database.dart';
import 'enum/enum.dart';
import 'l10n/l10n.dart';
import 'models/models.dart';
import 'providers/providers.dart';

class GlobalState {
  static GlobalState? _instance;
  final navigatorKey = GlobalKey<NavigatorState>();
  bool isPre = true;
  late final String coreSHA256;
  late final String mihomoVersion;
  late final String mihomoCommit;
  late final String mihomoReleaseDate;
  late final String coreBuildTime;
  late final PackageInfo packageInfo;
  Function? updateCurrentDelayDebounce;
  late Measure measure;
  late CommonTheme theme;
  late Color accentColor;
  late ProviderContainer container;
  bool needInitStatus = true;

  // ignore: deprecated_member_use
  CorePalette? corePalette;
  String? lastConfigMd5;
  VpnState? lastVpnState;
  bool isAttach = false;

  final Future<void> Function()? _initializeOverride;

  GlobalState._internal() : _initializeOverride = null;

  @visibleForTesting
  GlobalState.test(Future<void> Function() initialize)
      : _initializeOverride = initialize;

  factory GlobalState() {
    _instance ??= GlobalState._internal();
    return _instance!;
  }

  Future<ProviderContainer> init(int version) async {
    coreSHA256 = const String.fromEnvironment('CORE_SHA256');
    mihomoVersion = const String.fromEnvironment('MIHOMO_VERSION');
    mihomoCommit = const String.fromEnvironment('MIHOMO_COMMIT');
    mihomoReleaseDate = const String.fromEnvironment('MIHOMO_RELEASE_DATE');
    coreBuildTime = const String.fromEnvironment('CORE_BUILD_TIME');
    isPre = const String.fromEnvironment('APP_ENV') != 'stable';
    StartupTrace.mark('globalState.init.begin');
    await _initDynamicColor();
    StartupTrace.mark('dynamic_color');
    return _initData(version);
  }

  Future<void> _initDynamicColor() async {
    accentColor = const Color(0xFF0A84FF);
    try {
      corePalette = await DynamicColorPlugin.getCorePalette();
      accentColor =
          await DynamicColorPlugin.getAccentColor() ?? const Color(0xFF0A84FF);
    } catch (_) {}
  }

  String get ua => container
      .read(patchClashConfigProvider.select((state) => state.globalUa))
      .takeFirstValid([packageInfo.ua]);

  BuildContext get _context => navigatorKey.currentContext!;

  Future<ProviderContainer> _initData(int version) async {
    final appState = AppState(
      brightness: WidgetsBinding.instance.platformDispatcher.platformBrightness,
      version: version,
      viewSize: Size.zero,
      requests: FixedList(maxLength),
      logs: FixedList(maxLength),
      traffics: FixedList(30),
      totalTraffic: const Traffic(),
      systemUiOverlayStyle: const SystemUiOverlayStyle(),
    );
    final appStateOverrides = buildAppStateOverrides(appState);
    packageInfo = await PackageInfo.fromPlatform();
    StartupTrace.mark('package_info');
    final configMap = await preferences.getConfigMap();
    StartupTrace.mark('preferences');
    final migratedConfig = await migration.migrationIfNeeded(
      configMap,
      sync: (data) async {
        final newConfigMap = data.configMap;
        final config = Config.realFromJson(newConfigMap);
        await Future.wait([
          database.restore(
            data.profiles,
            data.scripts,
            data.rules,
            data.links,
            data.proxyGroups,
          ),
          preferences.saveConfig(config),
        ]);
        return config;
      },
    );
    StartupTrace.mark('migration');

    final config = migratedConfig.copyWith(
      themeProps: normalizeThemeProps(migratedConfig.themeProps),
    );
    if (config != migratedConfig) {
      await preferences.saveConfig(config);
    }

    final configOverrides = buildConfigOverrides(config);
    container = ProviderContainer(
      overrides: [...appStateOverrides, ...configOverrides],
    );
    final profiles = await database.profilesDao.query().get();
    StartupTrace.mark('database_profiles');
    container.read(profilesProvider.notifier).setAndReorder(profiles);
    await AppLocalizations.load(
      utils.getLocaleForString(config.appSettingProps.locale) ??
          WidgetsBinding.instance.platformDispatcher.locale,
    );
    StartupTrace.mark('localization');
    return container;
  }

  Future<T?> loadingRun<T>(
    FutureOr<T> Function() futureFunction, {
    String? title,
    required LoadingTag? tag,
    bool silence = false,
  }) async {
    return globalState.safeRun(
      futureFunction,
      silence: silence,
      title: title,
      onStart: () {
        if (tag != null) {
          container.read(loadingProvider(tag).notifier).start();
        }
      },
      onEnd: () {
        if (tag != null) {
          container.read(loadingProvider(tag).notifier).stop();
        }
      },
    );
  }

  Future<T?> safeRun<T>(
    FutureOr<T> Function() futureFunction, {
    String? title,
    VoidCallback? onStart,
    VoidCallback? onEnd,
    bool silence = true,
  }) async {
    try {
      onStart?.call();
      return await futureFunction();
    } catch (e, s) {
      commonPrint.log('$title ===> $e, $s', logLevel: LogLevel.warning);
      if (silence) {
        showNotifier(e.toString());
      } else {
        showMessage(
          title: title ?? currentAppLocalizations.tip,
          message: TextSpan(text: e.toString()),
        );
      }
      return null;
    } finally {
      onEnd?.call();
    }
  }

  Future<bool?> showMessage({
    required InlineSpan message,
    BuildContext? context,
    String? title,
    String? confirmText,
    String? cancelText,
    bool cancelable = true,
    bool? dismissible,
  }) async {
    return showCommonDialog<bool>(
      context: context,
      dismissible: dismissible,
      child: Builder(
        builder: (context) {
          final appLocalizations = context.appLocalizations;
          return CommonDialog(
            title: title ?? appLocalizations.tip,
            actions: [
              if (cancelable)
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop(false);
                  },
                  child: Text(cancelText ?? appLocalizations.cancel),
                ),
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop(true);
                },
                child: Text(confirmText ?? appLocalizations.confirm),
              ),
            ],
            child: Container(
              width: 300,
              constraints: const BoxConstraints(maxHeight: 200),
              child: SingleChildScrollView(
                child: SelectableText.rich(
                  TextSpan(
                    style: Theme.of(context).textTheme.labelLarge,
                    children: [message],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<bool?> showAllUpdatingMessagesDialog(
    List<UpdatingMessage> messages,
  ) async {
    return showCommonDialog<bool>(
      child: Builder(
        builder: (context) {
          final appLocalizations = currentAppLocalizations;
          return CommonDialog(
            padding: EdgeInsets.zero,
            title: appLocalizations.tip,
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop(true);
                },
                child: Text(appLocalizations.confirm),
              ),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 4),
              constraints: const BoxConstraints(maxHeight: 200),
              child: ListView.separated(
                itemBuilder: (_, index) {
                  final message = messages[index];
                  return ListItem(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    title: Text(message.label),
                    subtitle: Text(message.message),
                  );
                },
                itemCount: messages.length,
                separatorBuilder: (_, _) => const Divider(height: 0),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<T?> showCommonDialog<T>({
    required Widget child,
    BuildContext? context,
    bool? dismissible,
    bool filter = true,
  }) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final result = await showModal<T>(
      useRootNavigator: false,
      context: context ?? globalState.navigatorKey.currentContext!,
      configuration: FadeScaleTransitionConfiguration(
        barrierColor: Colors.black.withValues(
          alpha: SurgeMotion.modalBarrierOpacity,
        ),
        barrierDismissible: dismissible ?? true,
        transitionDuration: SurgeMotion.container,
        reverseTransitionDuration: SurgeMotion.state,
      ),
      builder: (_) => child,
      filter: filter ? commonFilter : null,
    );
    FocusManager.instance.primaryFocus?.unfocus();
    return result;
  }

  void showNotifier(String text, {MessageActionState? actionState}) {
    if (text.isEmpty) {
      return;
    }
    navigatorKey.currentContext?.showNotifier(text, actionState: actionState);
  }

  Future<void> openUrl(String url) async {
    final res = await showCommonDialog<bool>(
      child: Builder(
        builder: (context) {
          final appLocalizations = context.appLocalizations;
          return CommonDialog(
            title: appLocalizations.externalLink,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 16,
              children: [
                InputDecorator(
                  decoration:
                      surgeInputDecoration(
                        context,
                        hintText: appLocalizations.externalLink,
                        contentPadding: const EdgeInsets.fromLTRB(
                          16,
                          14,
                          8,
                          14,
                        ),
                        suffixIcon: const Icon(SurgeIcons.lock),
                      ).copyWith(
                        suffixIconConstraints: const BoxConstraints(
                          minWidth: 40,
                          minHeight: 44,
                        ),
                      ),
                  child: Transform.translate(
                    offset: const Offset(0, -3),
                    child: Text(
                      url,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: context.typography.body,
                    ),
                  ),
                ),
                SurgeDialogActionRow(
                  cancelLabel: appLocalizations.cancel,
                  submitLabel: appLocalizations.go,
                  onCancel: () {
                    Navigator.of(context).pop(false);
                  },
                  onSubmit: () {
                    Navigator.of(context).pop(true);
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
    if (res != true) {
      return;
    }
    launchUrl(Uri.parse(url));
  }

  Future<void>? _attachFuture;

  Future<void> attach() async {
    if (isAttach == true) {
      return;
    }
    final running = _attachFuture;
    if (running != null) return running;
    final future = (_initializeOverride ?? _initApp)();
    _attachFuture = future;
    try {
      await future;
      isAttach = true;
    } finally {
      _attachFuture = null;
    }
  }

  Future<void> _initApp() async {
    FlutterError.onError = (details) {
      commonPrint.log(
        'exception: ${details.exception} stack: ${details.stack}',
        logLevel: LogLevel.warning,
      );
    };
    container.read(profilesActionProvider.notifier).autoUpdateProfiles();
    container.read(commonActionProvider.notifier).autoCheckUpdate();
    autoLaunch?.updateStatus(container.read(appSettingProvider).autoLaunch);
    await _handleFailedPreference();
    await _handlerDisclaimer();
    // Hydrate proxy groups snapshot before core init for instant first paint
    await container
        .read(proxiesActionProvider.notifier)
        .hydrateProxyGroupsSnapshot();
    StartupTrace.mark('proxy_group_snapshot_hydration');
    await container.read(setupActionProvider.notifier).initStatus();
    StartupTrace.mark('setupAction.initStatus');
    container.read(initProvider.notifier).value = true;
    StartupTrace.finish('main_ready');
  }

  Future<void> _handleFailedPreference() async {
    if (await preferences.isInit) return;
    final res = await showMessage(
      title: currentAppLocalizations.tip,
      message: TextSpan(text: currentAppLocalizations.cacheCorrupt),
    );
    if (res == true) {
      final file = File(await appPath.sharedPreferencesPath);
      await file.safeDelete();
    }
    await container.read(systemActionProvider.notifier).handleExit();
  }

  Future<bool> showDisclaimer() async {
    return await showCommonDialog<bool>(
          dismissible: false,
          child: CommonDialog(
            title: currentAppLocalizations.disclaimer,
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(_context).pop<bool>(false);
                },
                child: Text(currentAppLocalizations.exit),
              ),
              TextButton(
                onPressed: () {
                  Navigator.of(_context).pop<bool>(true);
                },
                child: Text(currentAppLocalizations.agree),
              ),
            ],
            child: Text(currentAppLocalizations.disclaimerDesc),
          ),
        ) ??
        false;
  }

  Future<void> _handlerDisclaimer() async {
    if (container.read(
      appSettingProvider.select((state) => state.disclaimerAccepted),
    )) {
      return;
    }
    final isDisclaimerAccepted = await showDisclaimer();
    if (!isDisclaimerAccepted) {
      await container.read(systemActionProvider.notifier).handleExit();
    }
    container
        .read(appSettingProvider.notifier)
        .update((state) => state.copyWith(disclaimerAccepted: true));
  }
}

final globalState = GlobalState();
