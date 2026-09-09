import 'package:drift/native.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'large snapshot roundtrip, upsert and legacy converter compatibility',
    () async {
      final db = Database(NativeDatabase.memory());
      addTearDown(db.close);
      await db.profiles.put(
        const Profile(
          id: 1,
          label: 'large',
          url: 'https://example.com',
          autoUpdateDuration: Duration(hours: 1),
        ).toCompanion(),
      );
      final groups = [
        Group(
          name: 'test',
          type: GroupType.Selector,
          now: 'node-9999',
          all: List.generate(10000, (i) => Proxy(name: 'node-$i', type: 'ss')),
        ),
      ];
      final before = DateTime.now().subtract(const Duration(seconds: 1));
      await db.proxyGroupsSnapshotsDao.putSnapshot(
        profileId: 1,
        groups: groups,
        profileFingerprint: 'first',
      );
      final snapshot = (await db.proxyGroupsSnapshotsDao.getSnapshot(1))!;
      expect(snapshot.groups, groups);
      expect(snapshot.updatedAt.isAfter(before), isTrue);
      expect(snapshot.profileFingerprint, 'first');
      expect(snapshot.snapshotVersion, kProxyGroupsSnapshotVersion);
      final legacy = await db.select(db.proxyGroupsSnapshots).getSingle();
      expect(legacy.groups, groups);
      await db.proxyGroupsSnapshotsDao.putSnapshot(profileId: 1, groups: []);
      expect(
        (await db.proxyGroupsSnapshotsDao.getSnapshot(1))!.groups,
        isEmpty,
      );
      expect(
        (await db.proxyGroupsSnapshotsDao.getSnapshot(1))!.profileFingerprint,
        isNull,
      );
      expect(await db.proxyGroupsSnapshotsDao.getSnapshot(2), isNull);
    },
  );
}
