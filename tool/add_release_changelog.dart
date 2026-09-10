import 'dart:convert';
import 'dart:io';

void main() {
  final rawTag = Platform.environment['RELEASE_TAG']?.trim() ?? '';
  final rawChangelog = Platform.environment['RELEASE_CHANGELOG'] ?? '';
  final tag = rawTag.startsWith('v') ? rawTag : 'v$rawTag';

  if (!RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(tag)) {
    fail('Invalid RELEASE_TAG: $rawTag');
  }

  final changes = rawChangelog
      .split(RegExp(r'\r?\n|\s*\|\s*'))
      .map((item) => item.replaceFirst(RegExp(r'^\s*\d+[.、．)]\s*'), '').trim())
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
  if (changes.isEmpty) {
    fail('RELEASE_CHANGELOG must contain at least one item.');
  }

  final file = File('lib/common/app_changelog.dart');
  final source = file.readAsStringSync();
  final marker = RegExp(
    r'const appChangelogEntries = <AppChangelogEntry>\[\r?\n',
  ).firstMatch(source);
  if (marker == null) fail('Could not locate appChangelogEntries.');
  if (RegExp("version:\\s*'$tag'").hasMatch(source)) {
    stdout.writeln('The $tag app changelog already exists. Skipping.');
    exit(0);
  }

  final now = DateTime.now().toUtc();
  final date =
      '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
  final items = changes.map((item) => '      ${jsonEncode(item)},').join('\n');
  final entry =
      '''  AppChangelogEntry(
    version: '$tag',
    date: '$date',
    changes: [
$items
    ],
  ),
''';
  final insertAt = marker.end;
  file.writeAsStringSync(
    source.substring(0, insertAt) + entry + source.substring(insertAt),
  );

  stdout.writeln('Added $tag app changelog with ${changes.length} item(s).');
}

Never fail(String message) {
  stderr.writeln(message);
  exit(1);
}
