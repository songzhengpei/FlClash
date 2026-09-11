import 'dart:async';

import 'package:fl_clash/models/models.dart';
import 'settings_contract.dart';
import 'settings_runtime.dart';
import '../mihomo_config/structural_config_diff.dart';

enum SettingsApplyPhase { idle, pending, applying, applied, deferred, failed }

class SettingsApplyStatus {
  const SettingsApplyStatus(this.phase, {this.reconnect = false, this.error});
  final SettingsApplyPhase phase;
  final bool reconnect;
  final String? error;
}

/// One queue for settings, with a frozen attempt and conditional rollback.
/// The transport owns runtime rollback; this queue owns preference rollback.
class SettingsApplyQueue {
  SettingsApplyQueue({
    required Config baseline,
    required this.read,
    required this.canApply,
    required this.apply,
    required this.restorePreferences,
    required this.onStatus,
  }) : _baseline = baseline;

  final Config Function() read;
  final bool Function() canApply;
  final Future<void> Function(Config, SettingsApplyKind, bool Function()) apply;
  final Future<void> Function(Config) restorePreferences;
  final void Function(SettingsApplyStatus) onStatus;
  Config _baseline;
  Config? _pendingAcknowledgement;
  int? _pendingSavedRevision;
  Timer? _timer;
  int _revision = 0;
  int _context = 0;
  bool _busy = false;
  bool _disposed = false;
  bool _restoring = false;
  bool _forceRecovery = false;
  final List<StructuralChange> _editsDuringAttempt = [];
  final Map<int, Future<void> Function()> _savedEdits = {};
  bool get busy => _busy;

  SettingsApplyKind _kind(Config config) {
    final kind = settingsApplyKind(_baseline, config);
    if (kind == SettingsApplyKind.vpn) return kind;
    return _forceRecovery || _savedEdits.isNotEmpty
        ? SettingsApplyKind.reload
        : kind;
  }

  /// Called only after an editor has committed its draft to storage.
  void savedEdit(Future<void> Function() rollback) {
    if (_disposed) return;
    _savedEdits[++settingsSavedEditRevision] = rollback;
    _revision++;
    _schedule();
  }

  void acknowledged(Config config, {int? savedRevision}) {
    if (_busy) {
      _pendingAcknowledgement = config;
      _pendingSavedRevision = savedRevision;
      return;
    }
    _baseline = config;
    if (savedRevision != null) {
      _savedEdits.removeWhere((revision, _) => revision <= savedRevision);
    }
    if (_kind(read()) == SettingsApplyKind.none) {
      _timer?.cancel();
      onStatus(const SettingsApplyStatus(SettingsApplyPhase.idle));
    } else {
      _schedule();
    }
  }

  void change(Config previous, Config next) {
    if (_disposed || _restoring) return;
    if (previous.currentProfileId != next.currentProfileId) {
      _context++;
      _revision++;
      _timer?.cancel();
      _baseline = _baseline.copyWith(currentProfileId: next.currentProfileId);
      _savedEdits.clear();
      // CoreManager owns immediate profile application and its feedback.
      // Changing subscription is not a deferred settings edit.
      onStatus(const SettingsApplyStatus(SettingsApplyPhase.idle));
      return;
    }
    if (settingsApplyKind(previous, next) == SettingsApplyKind.none) return;
    if (_busy) {
      _editsDuringAttempt.addAll(
        diffStructuralChanges(runtimeSettings(previous), runtimeSettings(next)),
      );
    }
    _revision++;
    _schedule();
  }

  void sessionChanged() {
    if (!canApply()) {
      _context++;
      _timer?.cancel();
      if (_kind(read()) != SettingsApplyKind.none) {
        onStatus(const SettingsApplyStatus(SettingsApplyPhase.deferred));
      }
    } else if (!_busy && _kind(read()) != SettingsApplyKind.none) {
      _schedule();
    }
    // An explicit start/resume applies the saved configuration itself.
  }

  void retry() {
    _forceRecovery = true;
    _revision++;
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    final kind = _kind(read());
    if (kind == SettingsApplyKind.none) return;
    if (!canApply()) {
      onStatus(const SettingsApplyStatus(SettingsApplyPhase.deferred));
      return;
    }
    onStatus(
      SettingsApplyStatus(
        SettingsApplyPhase.pending,
        reconnect: kind == SettingsApplyKind.vpn,
      ),
    );
    _timer = Timer(
      kind == SettingsApplyKind.hot && !_busy
          ? Duration.zero
          : const Duration(seconds: 1),
      _drain,
    );
  }

  Future<void> _drain() async {
    if (_disposed || _busy || !canApply()) return;
    final attempt = read();
    final before = _baseline;
    final kind = _kind(attempt);
    if (kind == SettingsApplyKind.none) return;
    final revision = _revision;
    final context = _context;
    final savedEdits = Map<int, Future<void> Function()>.of(_savedEdits);
    bool valid() =>
        !_disposed &&
        context == _context &&
        attempt.currentProfileId == read().currentProfileId;
    _busy = true;
    _editsDuringAttempt.clear();
    onStatus(
      SettingsApplyStatus(
        SettingsApplyPhase.applying,
        reconnect: kind == SettingsApplyKind.vpn,
      ),
    );
    try {
      await apply(
        attempt,
        kind,
        () => valid() && revision == _revision && canApply(),
      );
      if (valid()) {
        _savedEdits.removeWhere((revision, _) => savedEdits.containsKey(revision));
        _baseline = attempt;
        _forceRecovery = false;
        if (revision == _revision) {
          onStatus(const SettingsApplyStatus(SettingsApplyPhase.applied));
        }
      }
    } on SettingsApplyCancelled {
      if (valid()) {
        onStatus(const SettingsApplyStatus(SettingsApplyPhase.deferred));
      }
    } catch (error) {
      if (!_disposed && attempt.currentProfileId == read().currentProfileId) {
        if (error is SettingsApplyFailure && error.restoreError != null) {
          _forceRecovery = true;
        }
        try {
          for (final rollback in savedEdits.values.toList().reversed) {
            await rollback();
          }
          _savedEdits.removeWhere((revision, _) => savedEdits.containsKey(revision));
          _restoring = true;
          final persistence = restorePreferences(
            rollbackSettings(
              before,
              attempt,
              read(),
              newerChanges: _editsDuringAttempt,
            ),
          );
          _restoring = false;
          await persistence;
        } catch (restoreError) {
          onStatus(
            SettingsApplyStatus(
              SettingsApplyPhase.failed,
              error: '$error; preference restore failed: $restoreError',
            ),
          );
          return;
        } finally {
          _restoring = false;
        }
        onStatus(
          SettingsApplyStatus(SettingsApplyPhase.failed, error: '$error'),
        );
      }
    } finally {
      _busy = false;
      final acknowledgement = _pendingAcknowledgement;
      _pendingAcknowledgement = null;
      if (!_disposed &&
          acknowledgement != null &&
          acknowledgement.currentProfileId == read().currentProfileId) {
        acknowledged(acknowledgement, savedRevision: _pendingSavedRevision);
        _pendingSavedRevision = null;
      }
      if (!_disposed && valid() && revision != _revision && canApply()) {
        _schedule();
      }
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }
}
