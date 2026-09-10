import 'package:flutter/foundation.dart';
import 'package:fl_clash/models/models.dart';

/// Last acknowledged materialization, not merely the current preferences.
class SettingsRuntimeRecord {
  const SettingsRuntimeRecord(this.config, this.yaml, {this.savedEditRevision = 0});
  final int savedEditRevision;
  final Config config;
  final String yaml;
}

int settingsSavedEditRevision = 0;

final settingsRuntimeRecord = ValueNotifier<SettingsRuntimeRecord?>(null);

class SettingsApplyCancelled implements Exception {
  const SettingsApplyCancelled();
}

class SettingsApplyFailure implements Exception {
  const SettingsApplyFailure(this.cause, {this.restoreError});
  final Object cause;
  final Object? restoreError;
  @override
  String toString() =>
      restoreError == null ? '$cause' : '$cause; restore failed: $restoreError';
}
