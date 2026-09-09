import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/network_matcher.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'action.dart';
import 'app.dart';
import 'config.dart';
import 'state.dart';

part 'generated/smart_auto_stop.g.dart';

/// Filter out loopback, VPN tunnel, and point-to-point interfaces.
const filteredInterfacePrefixes = ['lo', 'tun', 'utun', 'ppp', 'vpn'];

/// Returns `true` if [name] matches a known VPN/loopback interface prefix.
bool isFilteredNetworkInterface(String name) {
  final lower = name.toLowerCase();
  return filteredInterfacePrefixes.any(lower.startsWith);
}

Future<bool> convergeConfirmedSmartStop({
  required Future<bool> Function() smartStop,
  required Future<void> Function(bool value) setNativeSmartStopped,
  required void Function(bool value) setFlutterSmartStopped,
  required Future<void> Function() stopLocalListener,
}) async {
  if (!await smartStop()) return false;
  await setNativeSmartStopped(true);
  setFlutterSmartStopped(true);
  await stopLocalListener();
  return true;
}

Future<bool> convergeConfirmedSmartResume({
  required Future<bool> Function() smartResume,
  required Future<void> Function(bool value) setNativeSmartStopped,
  required Future<DateTime?> Function() getNativeStartTime,
  required Future<void> Function(DateTime startTime) resumeLocalListener,
  required void Function(bool value) setFlutterSmartStopped,
}) async {
  if (!await smartResume()) return false;
  final nativeStartTime = await getNativeStartTime();
  if (nativeStartTime == null) return false;
  await setNativeSmartStopped(false);
  await resumeLocalListener(nativeStartTime);
  setFlutterSmartStopped(false);
  return true;
}

/// Tracks whether smart auto stop is currently active (VPN was auto-stopped
/// because the device is on a trusted network).
@Riverpod(keepAlive: true)
class IsSmartStopped extends _$IsSmartStopped {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

/// Tracks whether the user has manually resumed from a smart auto-stop
/// during the current trusted-network session.
///
/// When true, [SmartAutoStopManager._checkAndToggle] will NOT auto-stop
/// again until the user leaves the trusted network or manually stops the
/// proxy. This is a temporary per-session override, not a permanent
/// setting change.
@Riverpod(keepAlive: true)
class SmartAutoStopManualOverride extends _$SmartAutoStopManualOverride {
  @override
  bool build() => false;

  void set(bool value) => state = value;

  void clear() => state = false;
}

/// Tracks whether a user-initiated smart resume is currently in progress.
///
/// UI can watch this to show a loading/disabled state on the "恢复" button,
/// preventing duplicate clicks while a resume is already under way.
@Riverpod(keepAlive: true)
class IsSmartResuming extends _$IsSmartResuming {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

/// Manages the smart auto stop lifecycle.
///
/// When enabled, listens to connectivity changes and checks if the device's
/// local IP matches any trusted network. If it does, the VPN is automatically
/// stopped. When the device leaves the trusted network, the VPN is resumed.
///
/// On Android, uses native smartStop/smartResume to suspend/resume TUN
/// without tearing down the service. Falls back to full stop/start on
/// non-Android or when native calls fail.
@Riverpod(keepAlive: true)
class SmartAutoStopManager extends _$SmartAutoStopManager {
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  Timer? _debounceTimer;
  Timer? _guardTimer;
  bool _checking = false;
  bool _manualResumeInProgress = false;
  bool _pendingManualResume = false;
  DateTime? _vpnStartedAt;

  /// Grace period after VPN startup before allowing smart auto stop.
  /// Prevents race condition where smartStop fires before service is ready.
  static const _startGuardDuration = Duration(seconds: 8);

  @override
  bool build() {
    ref.onDispose(_dispose);

    // Listen to connectivity changes
    _startListening();

    // Track VPN start time for startup guard
    ref.listen(isStartProvider, (prev, next) {
      if (prev == false && next == true) {
        _vpnStartedAt = DateTime.now();
      } else if (next == false) {
        _vpnStartedAt = null;
      }
    });

    // Listen to smart auto stop config changes — trigger check when
    // smartAutoStop toggled or smartAutoStopNetworks modified.
    ref.listen(vpnSettingProvider, (prev, next) {
      final prevEnabled = prev?.smartAutoStop ?? false;
      final prevNetworks = prev?.smartAutoStopNetworks ?? [];
      final nextEnabled = next.smartAutoStop;
      final nextNetworks = next.smartAutoStopNetworks;

      final configChanged =
          prevEnabled != nextEnabled ||
          !_listEquals(prevNetworks, nextNetworks);

      if (!configChanged) return;

      if (system.isAndroid) {
        unawaited(_syncNativeConfig());
      }

      // Clear manual resume override when Smart Auto Stop is disabled,
      // trusted networks are emptied, or the network list is modified.
      // This prevents stale override from persisting across config cycles.
      final smartAutoStopDisabled = prevEnabled && !nextEnabled;
      final trustedNetworksCleared = nextNetworks.isEmpty;
      final trustedNetworksChanged =
          prevNetworks.isNotEmpty && !_listEquals(prevNetworks, nextNetworks);
      if (smartAutoStopDisabled ||
          trustedNetworksCleared ||
          trustedNetworksChanged) {
        ref.read(smartAutoStopManualOverrideProvider.notifier).clear();
      }

      // If smartAutoStop was just disabled or networks emptied while
      // VPN was auto-stopped, resume immediately without waiting for
      // connectivity change.
      if (!system.isAndroid &&
          (!nextEnabled || nextNetworks.isEmpty) &&
          ref.read(isSmartStoppedProvider)) {
        _resumeFromSmartStop();
        return;
      }

      // Otherwise trigger a debounced check with the new config.
      if (!system.isAndroid && nextEnabled && nextNetworks.isNotEmpty) {
        _debouncedCheck();
      }
    });

    ref.listen(appSettingProvider, (previous, next) {
      if (system.isAndroid &&
          previous?.closeConnections != next.closeConnections) {
        unawaited(_syncNativeConfig());
      }
    });

    ref.listen(initProvider, (previous, next) {
      if (system.isAndroid && previous != true && next) {
        unawaited(_syncNativeConfig());
      }
    });

    // Initial check on manager startup (debounced so providers are settled).
    if (system.isAndroid) {
      unawaited(_syncNativeConfig());
    } else {
      _debouncedCheck();
    }

    return false;
  }

  void _startListening() {
    _subscription?.cancel();
    _subscription = Connectivity().onConnectivityChanged.listen((results) {
      StartupTrace.mark(
        'smart_auto_connectivity_event',
        extras: {'results': results.map((value) => value.name).join(',')},
      );
      if (system.isAndroid) {
        // Native owns the decision. This foreground listener only refreshes
        // the Flutter projection when the UI process happens to be alive.
        unawaited(reevaluateNow());
      } else {
        _debouncedCheck();
      }
    });
  }

  Future<void> _syncNativeConfig() async {
    if (!ref.read(initProvider)) return;
    final native = service;
    if (native == null) return;
    final vpn = ref.read(vpnSettingProvider);
    await native.updateSmartPauseConfig(
      enabled: vpn.smartAutoStop,
      trustedNetworks: vpn.smartAutoStopNetworks,
      closeConnections: ref.read(appSettingProvider).closeConnections,
    );
  }

  /// Re-evaluates native policy against the latest physical-network truth.
  /// The caller must reconcile the native session before invoking this method.
  Future<void> reevaluateNow() async {
    if (!system.isAndroid) {
      await _checkAndToggle();
      return;
    }
    await _syncNativeConfig();
    await service?.reevaluateSmartPause();
    await ref.read(setupActionProvider.notifier).reconcileNativeSession();
  }

  void _debouncedCheck() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(seconds: 2), () {
      _checkAndToggle();
    });
  }

  Future<void> _checkAndToggle() async {
    if (_checking) return;
    StartupTrace.mark('smart_auto_check');
    _checking = true;
    try {
      final vpnProps = ref.read(vpnSettingProvider);
      if (!vpnProps.smartAutoStop) return;
      if (vpnProps.smartAutoStopNetworks.isEmpty) return;

      final isRunning = ref.read(isStartProvider);
      final isSmartStopped = ref.read(isSmartStoppedProvider);
      final manualOverride = ref.read(smartAutoStopManualOverrideProvider);

      // Get non-VPN IPv4 addresses
      final localIps = await _getLocalIpAddresses();

      // Do not act when we have no real address data — wait for next check
      // to avoid false resume on flaky network transitions.
      if (localIps.isEmpty) return;

      final isOnTrusted = localIps.any(
        (ip) => NetworkMatcher.matches(ip, vpnProps.smartAutoStopNetworks),
      );

      // Left trusted network while smart-stopped → resume VPN and clear
      // any lingering manual override.
      if (!isOnTrusted && isSmartStopped) {
        await _smartResume();
        ref.read(smartAutoStopManualOverrideProvider.notifier).clear();
        return;
      }

      // Left trusted network while running with manual override → clear
      // the override so future trusted-network visits auto-stop normally.
      if (!isOnTrusted && manualOverride) {
        ref.read(smartAutoStopManualOverrideProvider.notifier).clear();
        return;
      }

      // On trusted network, VPN running, not yet smart-stopped, and user
      // hasn't manually resumed this session → auto smart-stop.
      if (isOnTrusted && isRunning && !isSmartStopped && !manualOverride) {
        // Startup guard: VPN service may not be fully ready yet.
        // Defer smart stop and re-check after guard expires.
        if (_vpnStartedAt != null &&
            DateTime.now().difference(_vpnStartedAt!) < _startGuardDuration) {
          _scheduleCheckAfterGuard();
          return;
        }
        await _smartStop();
      }
    } finally {
      _checking = false;

      if (_pendingManualResume) {
        _pendingManualResume = false;
        unawaited(_runManualResume());
      }
    }
  }

  /// Stop VPN via native smartStop (suspend TUN only, keep service alive).
  /// On failure, defers instead of full-stopping to avoid killing a
  /// service that is still starting up.
  Future<void> _smartStop() async {
    StartupTrace.mark(
      'vpn_action_requested',
      extras: {'action': 'smart_stop', 'source': 'smart_auto_stop'},
    );
    final setupAction = ref.read(setupActionProvider.notifier);
    final s = service;
    if (system.isAndroid && s != null) {
      try {
        await s.smartStop();
      } finally {
        await setupAction.reconcileNativeSession();
      }
      return;
    }
    if (s != null) {
      try {
        final success = await convergeConfirmedSmartStop(
          smartStop: s.smartStop,
          setNativeSmartStopped: s.setSmartStopped,
          setFlutterSmartStopped: (value) =>
              ref.read(isSmartStoppedProvider.notifier).set(value),
          stopLocalListener: setupAction.handleSmartStopLocal,
        );
        StartupTrace.mark(
          'vpn_action_complete',
          extras: {
            'action': 'smart_stop',
            'source': 'smart_auto_stop',
            'success': success,
          },
        );
        if (success) return;
      } catch (_) {}
    }
    // Native smartStop failed — defer rather than full stop.
    // Scheduling a re-check lets the next attempt succeed once the
    // service is fully ready.
    _debouncedCheck();
  }

  /// Explicit smart-stop entry point used by external Android controls.
  /// This intentionally bypasses trusted-network matching while reusing the
  /// same confirmed native pause and Flutter convergence path as automation.
  Future<void> pauseNow() async {
    await _smartStop();
  }

  /// Resume VPN via native smartResume (resume TUN only, no service restart),
  /// falling back to full stop/start if native call fails.
  Future<void> _smartResume() async {
    StartupTrace.mark(
      'vpn_action_requested',
      extras: {'action': 'smart_resume', 'source': 'smart_auto_stop'},
    );
    final setupAction = ref.read(setupActionProvider.notifier);
    final s = service;
    if (system.isAndroid) {
      try {
        await s?.smartResume();
      } finally {
        await setupAction.reconcileNativeSession();
      }
      return;
    }
    if (s != null) {
      try {
        final success = await convergeConfirmedSmartResume(
          smartResume: s.smartResume,
          setNativeSmartStopped: s.setSmartStopped,
          getNativeStartTime: s.getRunTime,
          resumeLocalListener: setupAction.handleSmartResumeLocal,
          setFlutterSmartStopped: (value) =>
              ref.read(isSmartStoppedProvider.notifier).set(value),
        );
        StartupTrace.mark(
          'vpn_action_complete',
          extras: {
            'action': 'smart_resume',
            'source': 'smart_auto_stop',
            'success': success,
          },
        );
        if (success) return;
      } catch (_) {}
      // Native failed — fall through to phase 1 fallback
    }
    // Fallback: full start via setupAction
    await setupAction.updateStatus(true);
    if (ref.read(isStartProvider)) {
      ref.read(isSmartStoppedProvider.notifier).set(false);
    }
  }

  /// Schedule a check after the startup guard expires.
  /// This ensures smart stop will eventually fire even if no new
  /// connectivity change occurs during the guard window.
  void _scheduleCheckAfterGuard() {
    _guardTimer?.cancel();
    final elapsed = DateTime.now().difference(_vpnStartedAt ?? DateTime.now());
    final remaining = _startGuardDuration - elapsed;
    if (remaining.isNegative) return;
    _guardTimer = Timer(remaining, () {
      _debouncedCheck();
    });
  }

  /// Resume from smart stop triggered by config change (disable or empty rules).
  Future<void> _resumeFromSmartStop() async {
    if (_checking) return;
    _checking = true;
    try {
      await _smartResume();
    } finally {
      _checking = false;

      if (_pendingManualResume) {
        _pendingManualResume = false;
        unawaited(_runManualResume());
      }
    }
  }

  /// Public entry point for the Dashboard "Resume" button.
  ///
  /// If a connectivity check ([_checkAndToggle]) is in progress, the request
  /// is recorded as pending and automatically executed once the check finishes.
  /// This guarantees the user only needs to click once, even during rapid
  /// network-state transitions.
  Future<void> resumeNow() async {
    if (_manualResumeInProgress) return;

    if (_checking) {
      _pendingManualResume = true;
      ref.read(isSmartResumingProvider.notifier).set(true);
      return;
    }

    await _runManualResume();
  }

  /// Execute a manual resume with full safety guards:
  ///   - disallows re-entry
  ///   - cancels any pending debounced check to avoid interference
  ///   - sets [isSmartResumingProvider] so UI shows a loading state
  ///   - only sets [smartAutoStopManualOverrideProvider] after confirmed start
  ///   - always clears loading state in finally
  Future<void> _runManualResume() async {
    if (_manualResumeInProgress) return;

    _manualResumeInProgress = true;
    _pendingManualResume = false;
    ref.read(isSmartResumingProvider.notifier).set(true);
    _debounceTimer?.cancel();

    try {
      await _smartResume();

      // Only set override if proxy actually started.
      if (ref.read(isStartProvider)) {
        ref.read(smartAutoStopManualOverrideProvider.notifier).set(true);
      }
    } finally {
      _manualResumeInProgress = false;
      ref.read(isSmartResumingProvider.notifier).set(false);
    }
  }

  Future<List<String>> _getLocalIpAddresses() async {
    try {
      final s = service;
      if (s != null) {
        return await s.getLocalIpAddresses();
      }
    } catch (_) {}
    // Fallback to Dart's NetworkInterface if native call fails
    return _getLocalIpViaDart();
  }

  Future<List<String>> _getLocalIpViaDart() async {
    try {
      final interfaces = await NetworkInterface.list(includeLoopback: false);
      final addresses = <String>[];
      for (final intf in interfaces) {
        if (isFilteredNetworkInterface(intf.name)) continue;
        for (final addr in intf.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            addresses.add(addr.address);
          }
        }
      }
      return addresses;
    } catch (_) {
      return [];
    }
  }

  bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _dispose() {
    _subscription?.cancel();
    _subscription = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _guardTimer?.cancel();
    _guardTimer = null;
  }
}
