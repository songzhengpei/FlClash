import 'package:fl_clash/common/app_changelog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('latest changelog matches the v2.1.9 release', () {
    expect(appChangelogEntries.first.version, 'v2.1.9');
    expect(appChangelogEntries.first.changes, [
      '降低订阅同步内存占用',
      '优化代理被回收后的恢复',
    ]);
    expect(
      appChangelogEntries.map((entry) => entry.version),
      isNot(contains('v2.1.6')),
    );
    expect(
      appChangelogEntries.map((entry) => entry.version),
      isNot(contains('v2.1.7')),
    );
  });

  test('fresh installs do not show the changelog automatically', () {
    expect(
      shouldShowChangelogAfterUpdate(wasUpdated: false, lastShownVersion: null),
      isFalse,
    );
  });

  test('an updated install shows the latest changelog once', () {
    expect(
      shouldShowChangelogAfterUpdate(wasUpdated: true, lastShownVersion: null),
      isTrue,
    );
    expect(
      shouldShowChangelogAfterUpdate(
        wasUpdated: true,
        lastShownVersion: appChangelogEntries.first.version,
      ),
      isFalse,
    );
  });
}
