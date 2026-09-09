import 'dart:convert';
import 'dart:isolate';

import 'package:fl_clash/services/mihomo_config/structural_config_diff.dart';
import 'package:yaml/yaml.dart';

typedef MihomoConfigMap = Map<String, dynamic>;

/// The two views derived from ONE profile snapshot: the raw source parse and
/// the Mihomo-normalized map. Both always come from the same bytes.
typedef MihomoSnapshotParts = ({
  MihomoConfigMap source,
  MihomoConfigMap normalized,
});

/// Parses a Mihomo YAML document into isolate-safe plain Dart structures.
MihomoConfigMap parseMihomoSourceConfig(String source) {
  final document = loadYaml(source);
  final plain = toPlainDartStructure(document);
  if (plain is! Map<String, dynamic>) {
    throw const FormatException('Mihomo source config root must be a map');
  }
  return plain;
}

/// Converts YAML collections (and nested ordinary collections) into fresh,
/// plain Dart structures containing only JSON-compatible scalar values.
dynamic toPlainDartStructure(dynamic value) {
  if (value is YamlMap || value is Map) {
    final result = <String, dynamic>{};
    for (final entry in (value as Map).entries) {
      final key = entry.key;
      if (key is! String) {
        throw FormatException('Mihomo config map key must be a string: $key');
      }
      result[key] = toPlainDartStructure(entry.value);
    }
    return result;
  }
  if (value is YamlList || value is List) {
    return (value as List).map(toPlainDartStructure).toList();
  }
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  throw FormatException(
    'Unsupported Mihomo config value type: ${value.runtimeType}',
  );
}

/// List keys whose items carry a stable `name` identity. Items in these lists
/// are merged by name instead of being atomically replaced: the normalized item
/// stays authoritative, while source-only sibling fields inside the matched
/// item survive. All other lists are still replaced wholesale.
const _keyedListKeys = {'proxies', 'proxy-groups', 'listeners'};

/// Uses the original source as a preservation base while keeping normalized
/// Mihomo values authoritative. Maps are recursively merged; [proxies],
/// [proxy-groups] and [listeners] items are merged by `name`; all other lists
/// are replaced, not structurally merged.
MihomoConfigMap mergeSourceWithNormalized(
  MihomoConfigMap source,
  MihomoConfigMap normalized,
) {
  final result = Map<String, dynamic>.from(
    toPlainDartStructure(source) as Map<String, dynamic>,
  );
  for (final entry in normalized.entries) {
    final sourceValue = result[entry.key];
    final normalizedValue = entry.value;
    if (sourceValue is Map && normalizedValue is Map) {
      result[entry.key] = mergeSourceWithNormalized(
        Map<String, dynamic>.from(
          toPlainDartStructure(sourceValue) as Map<String, dynamic>,
        ),
        Map<String, dynamic>.from(
          toPlainDartStructure(normalizedValue) as Map<String, dynamic>,
        ),
      );
    } else if (sourceValue is List &&
        normalizedValue is List &&
        _keyedListKeys.contains(entry.key)) {
      result[entry.key] = _mergeKeyedLists(sourceValue, normalizedValue);
    } else {
      result[entry.key] = toPlainDartStructure(normalizedValue);
    }
  }
  return result;
}

/// Merges [normalized] items onto same-named [source] items (recursively via
/// [mergeSourceWithNormalized]); the normalized list defines order and
/// membership, source-only items are dropped, and items without a string
/// `name` pass through untouched.
List<dynamic> _mergeKeyedLists(
  List<dynamic> source,
  List<dynamic> normalized,
) {
  final sourceByName = <String, dynamic>{};
  for (final item in source) {
    if (item is Map && item['name'] is String) {
      sourceByName[item['name'] as String] = item;
    }
  }
  return normalized.map((item) {
    if (item is! Map || item['name'] is! String) {
      // Unnamed or malformed items are still deep-copied so the result never
      // shares object identity with the normalized input.
      return toPlainDartStructure(item);
    }
    final sourceItem = sourceByName[item['name'] as String];
    if (sourceItem is! Map) return toPlainDartStructure(item);
    return mergeSourceWithNormalized(
      Map<String, dynamic>.from(sourceItem),
      Map<String, dynamic>.from(item),
    );
  }).toList();
}

/// Reads ONE profile snapshot and derives both the source parse and the
/// Mihomo-normalized view from the exact same bytes, so source and normalized
/// can never come from different profile versions.
Future<MihomoSnapshotParts> loadMihomoSnapshotParts({
  required Future<List<int>> Function() loadSnapshot,
  required Future<MihomoConfigMap> Function(List<int> snapshot)
      normalizeSnapshot,
}) async {
  final snapshot = await loadSnapshot();
  final source = await _parseSnapshotInBackground(snapshot);
  final normalized = await normalizeSnapshot(snapshot);
  return (source: source, normalized: normalized);
}

Future<MihomoConfigMap> _parseSnapshotInBackground(List<int> snapshot) =>
    Isolate.run(() => parseMihomoSourceConfig(utf8.decode(snapshot)));

/// Resolves the non-Script runtime base from ONE profile snapshot so the
/// generic source parse and the Mihomo normalization always consume the same
/// bytes (no source B + normalized A). Any failure in snapshot reading, source
/// parsing, Core normalization, or overlay abandons preservation entirely and
/// falls back to the normalized-only path; a partially preserved overlay is
/// never produced.
Future<MihomoConfigMap> resolveSnapshotRuntimeBase({
  required Future<List<int>> Function() loadSnapshot,
  required Future<MihomoConfigMap> Function(List<int> snapshot)
      normalizeSnapshot,
  required Future<MihomoConfigMap> Function() fallbackNormalized,
  void Function(Object error, StackTrace stackTrace)? onPreservationFailure,
}) async {
  try {
    final parts = await loadMihomoSnapshotParts(
      loadSnapshot: loadSnapshot,
      normalizeSnapshot: normalizeSnapshot,
    );
    return mergeSourceWithNormalized(parts.source, parts.normalized);
  } catch (error, stackTrace) {
    onPreservationFailure?.call(error, stackTrace);
    return fallbackNormalized();
  }
}

/// Resolves the Script runtime base from ONE profile snapshot with source
/// preservation around the Script transform.
///
/// Pipeline: snapshot parts (source + normalizedBefore) -> the Script evaluates
/// a deep copy of normalizedBefore -> structural diff(normalizedBefore, after)
/// -> applied onto the source-preserved base (source + normalized overlay).
///
/// Guarantees:
/// - The Script always receives a deep copy of the normalized map, never the
///   raw source and never a preserved map, so the observable input contract is
///   unchanged.
/// - The Script evaluates at most once. Infrastructure failures (snapshot
///   read, source parse, Core normalization) abandon preservation and fall
///   back to the existing normalized-only Script path; a Script error
///   propagates; a post-Script merge/diff/apply failure reuses the first
///   Script result instead of re-evaluating.
Future<MihomoConfigMap> resolveScriptSnapshotRuntimeBase({
  required Future<List<int>> Function() loadSnapshot,
  required Future<MihomoConfigMap> Function(List<int> snapshot)
      normalizeSnapshot,
  required Future<MihomoConfigMap> Function() fallbackNormalized,
  required Future<MihomoConfigMap> Function(MihomoConfigMap scriptInput)
      evaluateScript,
  void Function(Object error, StackTrace stackTrace)? onPreservationFailure,
  void Function(Object error, StackTrace stackTrace)? onScriptApplyFailure,
}) async {
  final MihomoSnapshotParts parts;
  try {
    parts = await loadMihomoSnapshotParts(
      loadSnapshot: loadSnapshot,
      normalizeSnapshot: normalizeSnapshot,
    );
  } catch (error, stackTrace) {
    onPreservationFailure?.call(error, stackTrace);
    return fallbackNormalized();
  }

  final before = Map<String, dynamic>.from(
    deepCopyConfigValue(parts.normalized) as Map<String, dynamic>,
  );
  // The Script input is an independent copy: even if the evaluator mutates
  // its argument, the diff base stays pristine.
  final scriptInput = Map<String, dynamic>.from(
    deepCopyConfigValue(before) as Map<String, dynamic>,
  );
  final after = await evaluateScript(scriptInput);

  try {
    final preservationBase = mergeSourceWithNormalized(
      parts.source,
      parts.normalized,
    );
    final changes = diffStructuralChanges(before, after);
    return applyStructuralChanges(preservationBase, changes);
  } catch (error, stackTrace) {
    onScriptApplyFailure?.call(error, stackTrace);
    return after;
  }
}
