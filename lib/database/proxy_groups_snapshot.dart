part of 'database.dart';

@DataClassName('RawProxyGroupsSnapshot')
class ProxyGroupsSnapshots extends Table {
  @override
  String get tableName => 'proxy_groups_snapshots';

  IntColumn get profileId =>
      integer().references(Profiles, #id, onDelete: KeyAction.cascade)();

  TextColumn get groups => text().map(const GroupsConverter())();

  TextColumn get profileFingerprint => text().nullable()();

  IntColumn get snapshotVersion =>
      integer().withDefault(const Constant(kProxyGroupsSnapshotVersion))();

  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {profileId};
}

@DriftAccessor(tables: [ProxyGroupsSnapshots])
class ProxyGroupsSnapshotsDao extends DatabaseAccessor<Database>
    with _$ProxyGroupsSnapshotsDaoMixin {
  ProxyGroupsSnapshotsDao(super.attachedDatabase);

  Future<RawProxyGroupsSnapshot?> getSnapshot(int profileId) async {
    // Drift converters run on the caller isolate, even with a background DB.
    final row = await customSelect(
      'SELECT * FROM proxy_groups_snapshots WHERE profile_id = ?',
      variables: [Variable.withInt(profileId)],
      readsFrom: {proxyGroupsSnapshots},
    ).getSingleOrNull();
    if (row == null) return null;
    final encoded = row.read<String>('groups');
    final groups = await Isolate.run(
      () => const GroupsConverter().fromSql(encoded),
    );
    return RawProxyGroupsSnapshot(
      profileId: row.read<int>('profile_id'),
      groups: groups,
      profileFingerprint: row.readNullable<String>('profile_fingerprint'),
      snapshotVersion: row.read<int>('snapshot_version'),
      updatedAt: row.read<DateTime>('updated_at'),
    );
  }

  Future<void> putSnapshot({
    required int profileId,
    required List<Group> groups,
    String? profileFingerprint,
  }) async {
    final encoded = await Isolate.run(
      () => const GroupsConverter().toSql(groups),
    );
    await customInsert(
      'INSERT INTO proxy_groups_snapshots '
      '(profile_id, groups, profile_fingerprint, snapshot_version, updated_at) '
      'VALUES (?, ?, ?, ?, ?) ON CONFLICT(profile_id) DO UPDATE SET '
      'groups = excluded.groups, '
      'profile_fingerprint = excluded.profile_fingerprint, '
      'snapshot_version = excluded.snapshot_version, '
      'updated_at = excluded.updated_at',
      variables: [
        Variable.withInt(profileId),
        Variable.withString(encoded),
        Variable<String>(profileFingerprint),
        Variable.withInt(kProxyGroupsSnapshotVersion),
        Variable.withDateTime(DateTime.now()),
      ],
      updates: {proxyGroupsSnapshots},
    );
  }

  Future<void> deleteSnapshot(int profileId) {
    return (delete(
      proxyGroupsSnapshots,
    )..where((t) => t.profileId.equals(profileId))).go();
  }

  Future<void> deleteSnapshots(Iterable<int> profileIds) async {
    final ids = profileIds.toSet();
    if (ids.isEmpty) return;
    await (delete(
      proxyGroupsSnapshots,
    )..where((t) => t.profileId.isIn(ids))).go();
  }

  Future<void> deleteAllSnapshots() => delete(proxyGroupsSnapshots).go();
}
