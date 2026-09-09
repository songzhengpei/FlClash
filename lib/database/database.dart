import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';

part 'converter.dart';
part 'generated/database.g.dart';
part 'groups.dart';
part 'icons.dart';
part 'links.dart';
part 'profiles.dart';
part 'proxy_groups_snapshot.dart';
part 'rules.dart';
part 'scripts.dart';

@DriftDatabase(
  tables: [
    Profiles,
    Scripts,
    Rules,
    ProfileRuleLinks,
    ProxyGroups,
    IconRecords,
    ProxyGroupsSnapshots,
  ],
  daos: [
    ProfilesDao,
    ScriptsDao,
    RulesDao,
    ProxyGroupsDao,
    IconRecordsDao,
    ProxyGroupsSnapshotsDao,
  ],
)
class Database extends _$Database {
  Database([QueryExecutor? executor]) : super(executor ?? _openConnection());

  @override
  int get schemaVersion => 4;

  static LazyDatabase _openConnection() {
    return LazyDatabase(() async {
      final databaseFile = File(await appPath.databasePath);
      return NativeDatabase.createInBackground(databaseFile);
    });
  }

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onUpgrade: (m, from, to) async {
        if (from < 2) {
          await m.createTable(proxyGroups);
          await m.createTable(iconRecords);
          await _resetOrders();
          await _migrateRules(m);
        }
        if (from < 3) {
          await m.addColumn(profiles, profiles.computedSelectedMap);
        }
        if (from < 4) {
          await m.createTable(proxyGroupsSnapshots);
        }
      },
      beforeOpen: (details) async {
        // final m = Migrator(this);
        // await m.createTable(iconRecords);
        // await _migrateRules(m);
        // await m.deleteTable('proxy_groups');
        // await m.createTable(proxyGroups);
      },
    );
  }

  Future<void> _migrateRules(Migrator m) async {
    final tableInfo = await customSelect('PRAGMA table_info(rules)').get();
    final columnNames = tableInfo
        .map((row) => row.read<String>('name'))
        .toList();
    if (columnNames.isEmpty) {
      await m.createTable(rules);
      return;
    } else if (columnNames.contains('rule_action')) {
      return;
    }
    await customStatement(
      'ALTER TABLE rules ADD COLUMN rule_action TEXT NOT NULL DEFAULT ""',
    );
    await customStatement('ALTER TABLE rules ADD COLUMN content TEXT');
    await customStatement('ALTER TABLE rules ADD COLUMN rule_target TEXT');
    await customStatement('ALTER TABLE rules ADD COLUMN rule_provider TEXT');
    await customStatement('ALTER TABLE rules ADD COLUMN sub_rule TEXT');
    await customStatement(
      'ALTER TABLE rules ADD COLUMN no_resolve INTEGER NOT NULL DEFAULT 0',
    );
    await customStatement(
      'ALTER TABLE rules ADD COLUMN src INTEGER NOT NULL DEFAULT 0',
    );
    final oldRows = await customSelect('SELECT id, value FROM rules').get();
    for (final row in oldRows) {
      final id = row.read<int>('id');
      final value = row.read<String>('value');
      final parsed = Rule.parse(value, id: id);
      await customStatement(
        'UPDATE rules SET rule_action = ?, content = ?, rule_target = ?, rule_provider = ?, sub_rule = ?, no_resolve = ?, src = ? WHERE id = ?',
        [
          parsed.ruleAction.name,
          parsed.content,
          parsed.ruleTarget,
          parsed.ruleProvider,
          parsed.subRule,
          parsed.noResolve ? 1 : 0,
          parsed.src ? 1 : 0,
          id,
        ],
      );
    }
    await customStatement('ALTER TABLE rules DROP COLUMN value');
    await m.createIndex(idxRuleTarget);
  }

  Future<void> _resetOrders() async {
    await rulesDao.resetOrders();
  }

  Future<void> restore(
    List<Profile> profiles,
    List<Script> scripts,
    List<Rule> rules,
    List<ProfileRuleLink> links,
    List<ProxyGroup> proxyGroups, {
    bool isOverride = false,
  }) async {
    if (profiles.isNotEmpty ||
        scripts.isNotEmpty ||
        rules.isNotEmpty ||
        links.isNotEmpty ||
        proxyGroups.isNotEmpty) {
      await batch((b) {
        if (isOverride) {
          profilesDao.setAllWithBatch(b, profiles);
          scriptsDao.setAllWithBatch(b, scripts);
          rulesDao.restoreWithBatch(b, rules, links);
          proxyGroupsDao.setAllWithBatch(null, b, proxyGroups);
        } else {
          profilesDao.putAllWithBatch(
            b,
            profiles.map((item) => item.toCompanion()),
          );
          b.insertAllOnConflictUpdate(
            this.scripts,
            scripts.map((item) => item.toCompanion()).toList(),
          );
          b.insertAllOnConflictUpdate(
            this.rules,
            rules.map((item) => item.toCompanion()).toList(),
          );
          b.insertAllOnConflictUpdate(
            profileRuleLinks,
            links.map((item) => item.toCompanion()).toList(),
          );
          b.insertAllOnConflictUpdate(
            this.proxyGroups,
            proxyGroups.map((item) => item.toCompanion()).toList(),
          );
        }
      });
      if (isOverride) {
        await proxyGroupsSnapshotsDao.deleteAllSnapshots();
      } else {
        await proxyGroupsSnapshotsDao.deleteSnapshots(
          profiles.map((e) => e.id),
        );
      }
    }
  }

  Future<void> restoreProfilesOnly(
    List<Profile> profiles, {
    List<Script> scripts = const [],
    List<Rule> rules = const [],
    List<ProfileRuleLink> links = const [],
    bool isOverride = false,
  }) async {
    if (profiles.isEmpty && scripts.isEmpty && rules.isEmpty && links.isEmpty) {
      return;
    }
    await batch((b) {
      if (profiles.isNotEmpty) {
        if (isOverride) {
          profilesDao.setAllWithBatch(b, profiles);
        } else {
          profilesDao.putAllWithBatch(
            b,
            profiles.map((item) => item.toCompanion()),
          );
        }
      }
      if (scripts.isNotEmpty) {
        if (isOverride) {
          scriptsDao.setAllWithBatch(b, scripts);
        } else {
          b.insertAllOnConflictUpdate(
            this.scripts,
            scripts.map((s) => s.toCompanion()).toList(),
          );
        }
      }
      if (rules.isNotEmpty && links.isNotEmpty) {
        if (isOverride) {
          rulesDao.restoreWithBatch(b, rules, links);
        } else {
          b.insertAllOnConflictUpdate(
            this.rules,
            rules.map((r) => r.toCompanion()).toList(),
          );
          // Preserve original link order from backup (do not regenerate keys)
          b.insertAllOnConflictUpdate(
            profileRuleLinks,
            links.map((l) => l.toCompanion()).toList(),
          );
        }
      }
    });
  }

  Future<void> setProfileCustomData(
    int profileId,
    List<ProxyGroup> groups,
    List<Rule> rules,
  ) async {
    await batch((b) {
      proxyGroupsDao.setAllWithBatch(profileId, b, groups);
      rulesDao.setCustomRulesWithBatch(profileId, b, rules);
    });
  }

  /// Deletes one complete profile-owned database lifetime without relying on
  /// SQLite foreign-key enforcement.
  Future<void> deleteProfileLifetime(int profileId) {
    return transaction(() async {
      await (delete(
        profileRuleLinks,
      )..where((row) => row.profileId.equals(profileId))).go();
      await (delete(
        proxyGroups,
      )..where((row) => row.profileId.equals(profileId))).go();
      await proxyGroupsSnapshotsDao.deleteSnapshot(profileId);
      await profiles.remove((row) => row.id.equals(profileId));
    });
  }

  /// Persists a snapshot only while its owning profile row still exists.
  Future<bool> putProfileSnapshotIfExists({
    required int profileId,
    required List<Group> groups,
    required String profileFingerprint,
  }) {
    return transaction(() async {
      final profileExists =
          await (selectOnly(profiles)
                ..addColumns([profiles.id])
                ..where(profiles.id.equals(profileId)))
              .getSingleOrNull() !=
          null;
      if (!profileExists) return false;
      await proxyGroupsSnapshotsDao.putSnapshot(
        profileId: profileId,
        groups: groups,
        profileFingerprint: profileFingerprint,
      );
      return true;
    });
  }
}

extension TableInfoExt<Tbl extends Table, Row> on TableInfo<Tbl, Row> {
  void setAll(
    Batch batch,
    Iterable<Insertable<Row>> items, {
    required Expression<bool> Function(Tbl tbl) deleteFilter,
    bool preDelete = false,
  }) async {
    if (preDelete) {
      batch.deleteWhere(this, deleteFilter);
    }
    batch.insertAllOnConflictUpdate(this, items);
    if (!preDelete) {
      batch.deleteWhere(this, deleteFilter);
    }
  }

  Selectable<int?> get count {
    final countExp = countAll();
    final query = select().addColumns([countExp]);
    return query.map((row) => row.read(countExp));
  }

  Future<int> remove(Expression<bool> Function(Tbl tbl) filter) async {
    return (delete()..where(filter)).go();
  }

  Future<int> put(Insertable<Row> item) async {
    return insertOnConflictUpdate(item);
  }
}

extension SimpleSelectStatementExt<T extends HasResultSet, D>
    on SimpleSelectStatement<T, D> {
  Selectable<int> get count {
    final countExp = countAll();
    final query = addColumns([countExp]);
    return query.map((row) => row.read(countExp)!);
  }
}

extension JoinedSelectStatementExt<T extends HasResultSet, D>
    on JoinedSelectStatement<T, D> {
  Selectable<int> get count {
    final countExp = countAll();
    addColumns([countExp]);
    return map((row) => row.read(countExp)!);
  }
}

final database = Database();
