// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../smart_auto_stop.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Tracks whether smart auto stop is currently active (VPN was auto-stopped
/// because the device is on a trusted network).

@ProviderFor(IsSmartStopped)
final isSmartStoppedProvider = IsSmartStoppedProvider._();

/// Tracks whether smart auto stop is currently active (VPN was auto-stopped
/// because the device is on a trusted network).
final class IsSmartStoppedProvider
    extends $NotifierProvider<IsSmartStopped, bool> {
  /// Tracks whether smart auto stop is currently active (VPN was auto-stopped
  /// because the device is on a trusted network).
  IsSmartStoppedProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'isSmartStoppedProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$isSmartStoppedHash();

  @$internal
  @override
  IsSmartStopped create() => IsSmartStopped();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(bool value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<bool>(value),
    );
  }
}

String _$isSmartStoppedHash() => r'01bc4dd8981626d9dc29334085f1002114c4edfc';

/// Tracks whether smart auto stop is currently active (VPN was auto-stopped
/// because the device is on a trusted network).

abstract class _$IsSmartStopped extends $Notifier<bool> {
  bool build();
  @$mustCallSuper
  @override
  void runBuild() {
    final ref = this.ref as $Ref<bool, bool>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<bool, bool>,
              bool,
              Object?,
              Object?
            >;
    element.handleCreate(ref, build);
  }
}

/// Tracks whether the user has manually resumed from a smart auto-stop
/// during the current trusted-network session.
///
/// When true, [SmartAutoStopManager._checkAndToggle] will NOT auto-stop
/// again until the user leaves the trusted network or manually stops the
/// proxy. This is a temporary per-session override, not a permanent
/// setting change.

@ProviderFor(SmartAutoStopManualOverride)
final smartAutoStopManualOverrideProvider =
    SmartAutoStopManualOverrideProvider._();

/// Tracks whether the user has manually resumed from a smart auto-stop
/// during the current trusted-network session.
///
/// When true, [SmartAutoStopManager._checkAndToggle] will NOT auto-stop
/// again until the user leaves the trusted network or manually stops the
/// proxy. This is a temporary per-session override, not a permanent
/// setting change.
final class SmartAutoStopManualOverrideProvider
    extends $NotifierProvider<SmartAutoStopManualOverride, bool> {
  /// Tracks whether the user has manually resumed from a smart auto-stop
  /// during the current trusted-network session.
  ///
  /// When true, [SmartAutoStopManager._checkAndToggle] will NOT auto-stop
  /// again until the user leaves the trusted network or manually stops the
  /// proxy. This is a temporary per-session override, not a permanent
  /// setting change.
  SmartAutoStopManualOverrideProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'smartAutoStopManualOverrideProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$smartAutoStopManualOverrideHash();

  @$internal
  @override
  SmartAutoStopManualOverride create() => SmartAutoStopManualOverride();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(bool value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<bool>(value),
    );
  }
}

String _$smartAutoStopManualOverrideHash() =>
    r'b0818767a11cde61c487e50cc9936c5adda686b0';

/// Tracks whether the user has manually resumed from a smart auto-stop
/// during the current trusted-network session.
///
/// When true, [SmartAutoStopManager._checkAndToggle] will NOT auto-stop
/// again until the user leaves the trusted network or manually stops the
/// proxy. This is a temporary per-session override, not a permanent
/// setting change.

abstract class _$SmartAutoStopManualOverride extends $Notifier<bool> {
  bool build();
  @$mustCallSuper
  @override
  void runBuild() {
    final ref = this.ref as $Ref<bool, bool>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<bool, bool>,
              bool,
              Object?,
              Object?
            >;
    element.handleCreate(ref, build);
  }
}

/// Tracks whether a user-initiated smart resume is currently in progress.
///
/// UI can watch this to show a loading/disabled state on the "恢复" button,
/// preventing duplicate clicks while a resume is already under way.

@ProviderFor(IsSmartResuming)
final isSmartResumingProvider = IsSmartResumingProvider._();

/// Tracks whether a user-initiated smart resume is currently in progress.
///
/// UI can watch this to show a loading/disabled state on the "恢复" button,
/// preventing duplicate clicks while a resume is already under way.
final class IsSmartResumingProvider
    extends $NotifierProvider<IsSmartResuming, bool> {
  /// Tracks whether a user-initiated smart resume is currently in progress.
  ///
  /// UI can watch this to show a loading/disabled state on the "恢复" button,
  /// preventing duplicate clicks while a resume is already under way.
  IsSmartResumingProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'isSmartResumingProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$isSmartResumingHash();

  @$internal
  @override
  IsSmartResuming create() => IsSmartResuming();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(bool value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<bool>(value),
    );
  }
}

String _$isSmartResumingHash() => r'f5d7b061fe7762f8e230c92d1807b9058ba5b950';

/// Tracks whether a user-initiated smart resume is currently in progress.
///
/// UI can watch this to show a loading/disabled state on the "恢复" button,
/// preventing duplicate clicks while a resume is already under way.

abstract class _$IsSmartResuming extends $Notifier<bool> {
  bool build();
  @$mustCallSuper
  @override
  void runBuild() {
    final ref = this.ref as $Ref<bool, bool>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<bool, bool>,
              bool,
              Object?,
              Object?
            >;
    element.handleCreate(ref, build);
  }
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

@ProviderFor(SmartAutoStopManager)
final smartAutoStopManagerProvider = SmartAutoStopManagerProvider._();

/// Manages the smart auto stop lifecycle.
///
/// When enabled, listens to connectivity changes and checks if the device's
/// local IP matches any trusted network. If it does, the VPN is automatically
/// stopped. When the device leaves the trusted network, the VPN is resumed.
///
/// On Android, uses native smartStop/smartResume to suspend/resume TUN
/// without tearing down the service. Falls back to full stop/start on
/// non-Android or when native calls fail.
final class SmartAutoStopManagerProvider
    extends $NotifierProvider<SmartAutoStopManager, bool> {
  /// Manages the smart auto stop lifecycle.
  ///
  /// When enabled, listens to connectivity changes and checks if the device's
  /// local IP matches any trusted network. If it does, the VPN is automatically
  /// stopped. When the device leaves the trusted network, the VPN is resumed.
  ///
  /// On Android, uses native smartStop/smartResume to suspend/resume TUN
  /// without tearing down the service. Falls back to full stop/start on
  /// non-Android or when native calls fail.
  SmartAutoStopManagerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'smartAutoStopManagerProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$smartAutoStopManagerHash();

  @$internal
  @override
  SmartAutoStopManager create() => SmartAutoStopManager();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(bool value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<bool>(value),
    );
  }
}

String _$smartAutoStopManagerHash() =>
    r'bfedd077e7a011a832e322f6ecd24b514e16a08d';

/// Manages the smart auto stop lifecycle.
///
/// When enabled, listens to connectivity changes and checks if the device's
/// local IP matches any trusted network. If it does, the VPN is automatically
/// stopped. When the device leaves the trusted network, the VPN is resumed.
///
/// On Android, uses native smartStop/smartResume to suspend/resume TUN
/// without tearing down the service. Falls back to full stop/start on
/// non-Android or when native calls fail.

abstract class _$SmartAutoStopManager extends $Notifier<bool> {
  bool build();
  @$mustCallSuper
  @override
  void runBuild() {
    final ref = this.ref as $Ref<bool, bool>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<bool, bool>,
              bool,
              Object?,
              Object?
            >;
    element.handleCreate(ref, build);
  }
}
