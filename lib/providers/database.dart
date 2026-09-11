import 'dart:async';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'settings_apply.dart';
import 'package:fl_clash/services/profile_order.dart';

part 'generated/database.g.dart';

final _customRuleRevisions = <int, int>{};

Future<void> withRollback<T>({
  required T snapshot,
  required FutureOr<void> Function() action,
  required void Function(T snapshot) rollback,
}) async {
  try {
    await action();
  } catch (e, s) {
    rollback(snapshot);
    Error.throwWithStackTrace(e, s);
  }
}

@riverpod
Stream<List<Profile>> profilesStream(Ref ref) {
  return database.profilesDao.query().watch();
}

@riverpod
Stream<List<Rule>> addedRulesStream(Ref ref, int profileId) {
  return database.rulesDao.queryAddedRules(profileId).watch();
}

@riverpod
Stream<int> customRulesCount(Ref ref, int profileId) {
  return database.rulesDao.profileCustomRulesCount(profileId).watchSingle();
}

@riverpod
Stream<int> proxyGroupsCount(Ref ref, int profileId) {
  return database.proxyGroupsDao.count(profileId).watchSingle();
}

@Riverpod(keepAlive: true)
class Profiles extends _$Profiles {
  @override
  List<Profile> build() {
    return ref.watch(profilesStreamProvider).value ?? [];
  }

  /// Replace runtime state after an already-committed restore without writing
  /// the same rows back to the database asynchronously.
  void resetFromRestore(List<Profile> profiles) {
    state = List<Profile>.from(profiles);
  }

  /// Applies an already-committed delete without issuing another DB mutation.
  void applyCommittedDelete(int id) {
    state = state.where((profile) => profile.id != id).toList();
  }

  void put(Profile profile) {
    final previous = List<Profile>.from(state);
    final current = previous.where((item) => item.id == profile.id).firstOrNull;
    final newProfile = previous.optimizeLabel(
      current == null ? profile : profile.copyWith(order: current.order),
    );
    state = previous.copyAndPut(newProfile, (item) => item.id == newProfile.id);
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.profiles.put(newProfile.toCompanion()),
        rollback: (v) => state = v,
      ),
    );
  }

  void del(int id) {
    final previous = List<Profile>.from(state);
    state = previous.where((e) => e.id != id).toList();
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.profiles.remove((t) => t.id.equals(id)),
        rollback: (v) => state = v,
      ),
    );
  }

  void updateProfile(int profileId, Profile Function(Profile profile) builder) {
    final index = state.indexWhere((element) => element.id == profileId);
    if (index == -1) return;
    final newProfile = builder(state[index]).copyWith(order: state[index].order);
    final previous = List<Profile>.from(state);
    final next = List<Profile>.from(previous);
    next[index] = newProfile;
    state = next;
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.profiles.put(newProfile.toCompanion()),
        rollback: (v) => state = v,
      ),
    );
  }

  void setAndReorder(List<Profile> profiles) {
    final previous = List<Profile>.from(state);
    state = List<Profile>.from(profiles);
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.profilesDao.setAll(profiles),
        rollback: (v) => state = v,
      ),
    );
  }

  void reorder(List<Profile> profiles) {
    final previous = List<Profile>.from(state);
    final next = mergeProfileOrder(state, profiles.map((p) => p.id));
    state = next;
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.profilesDao.reorderIds(next.map((p) => p.id).toList()),
        rollback: (v) {
          if (identical(state, next)) state = v;
        },
      ),
    );
  }

  @override
  bool updateShouldNotify(List<Profile> previous, List<Profile> next) {
    return !profileListEquality.equals(previous, next);
  }
}

@riverpod
class Scripts extends _$Scripts with AsyncNotifierMixin {
  @override
  Stream<List<Script>> build() {
    return database.scriptsDao.query().watch();
  }

  @override
  List<Script> get value => state.value ?? [];

  void put(Script script) {
    final previous = List<Script>.from(value);
    final index = previous.indexWhere((item) => item.id == script.id);
    final next = List<Script>.from(previous);
    if (index != -1) {
      next[index] = script;
    } else {
      next.add(script);
    }
    value = next;
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.scripts.put(script.toCompanion()),
        rollback: (v) => value = v,
      ),
    );
  }

  void del(int id) {
    final previous = List<Script>.from(value);
    final index = previous.indexWhere((item) => item.id == id);
    if (index == -1) return;
    final next = List<Script>.from(previous);
    next.removeAt(index);
    value = next;
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.scripts.remove((t) => t.id.equals(id)),
        rollback: (v) => value = v,
      ),
    );
  }

  bool isExits(String label) {
    return value.indexWhere((item) => item.label == label) != -1;
  }

  @override
  bool updateShouldNotify(
    AsyncValue<List<Script>> previous,
    AsyncValue<List<Script>> next,
  ) {
    return !scriptListEquality.equals(previous.value, next.value);
  }
}

@riverpod
Future<Script?> script(Ref ref, int? scriptId) async {
  final script = ref.watch(
    scriptsProvider.future.select((state) async {
      final scripts = await state;
      return scripts.get(scriptId);
    }),
  );
  return script;
}

@riverpod
class GlobalRules extends _$GlobalRules with AsyncNotifierMixin {
  @override
  Stream<List<Rule>> build() {
    return database.rulesDao.queryGlobalAddedRules().watch();
  }

  @override
  List<Rule> get value => state.value ?? [];

  @override
  bool updateShouldNotify(
    AsyncValue<List<Rule>> previous,
    AsyncValue<List<Rule>> next,
  ) {
    return !ruleListEquality.equals(previous.value, next.value);
  }

  void delAll(Iterable<int> ruleIds) {
    final previous = List<Rule>.from(value);
    value = List.from(previous.where((item) => !ruleIds.contains(item.id)));
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.rulesDao.delRules(ruleIds),
        rollback: (v) => value = v,
      ),
    );
  }

  void put(Rule rule) {
    final previous = List<Rule>.from(value);
    final newRule = rule.autoOrder(rule, null, previous.firstOrNull?.order);
    value = previous.copyAndPut(newRule, (rule) => rule.id == newRule.id);
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.rulesDao.putGlobalRule(newRule),
        rollback: (v) => value = v,
      ),
    );
  }

  void order(int oldIndex, int newIndex) {
    final previous = List<Rule>.from(value);
    int insertIndex = newIndex;
    if (oldIndex < newIndex) insertIndex -= 1;
    final nextItems = List<Rule>.from(previous);
    final item = nextItems.removeAt(oldIndex);
    nextItems.insert(insertIndex, item);
    value = nextItems;
    final preOrder = nextItems.safeGet(insertIndex - 1)?.order;
    final nextOrder = nextItems.safeGet(insertIndex + 1)?.order;
    final newOrder = indexing.generateKeyBetween(preOrder, nextOrder)!;
    unawaited(
      withRollback(
        snapshot: previous,
        action: () =>
            database.rulesDao.orderGlobalRule(ruleId: item.id, order: newOrder),
        rollback: (v) => value = v,
      ),
    );
  }
}

@riverpod
class ProfileAddedRules extends _$ProfileAddedRules with AsyncNotifierMixin {
  @override
  Stream<List<Rule>> build(int profileId) {
    return database.rulesDao.queryProfileAddedRules(profileId).watch();
  }

  @override
  List<Rule> get value => state.value ?? [];

  @override
  bool updateShouldNotify(
    AsyncValue<List<Rule>> previous,
    AsyncValue<List<Rule>> next,
  ) {
    return !ruleListEquality.equals(previous.value, next.value);
  }

  void put(Rule rule) {
    final previous = List<Rule>.from(value);
    final newRule = rule.autoOrder(rule, null, previous.firstOrNull?.order);
    value = previous.copyAndPut(newRule, (rule) => rule.id == newRule.id);
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.rulesDao.putProfileAddedRule(profileId, newRule),
        rollback: (v) => value = v,
      ),
    );
  }

  void delAll(Iterable<int> ruleIds) {
    final previous = List<Rule>.from(value);
    value = List.from(previous.where((item) => !ruleIds.contains(item.id)));
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.rulesDao.delRules(ruleIds),
        rollback: (v) => value = v,
      ),
    );
  }

  void order(int oldIndex, int newIndex) {
    final previous = List<Rule>.from(value);
    int insertIndex = newIndex;
    if (oldIndex < newIndex) insertIndex -= 1;
    final nextItems = List<Rule>.from(previous);
    final item = nextItems.removeAt(oldIndex);
    nextItems.insert(insertIndex, item);
    value = nextItems;
    final preOrder = nextItems.safeGet(insertIndex - 1)?.order;
    final nextOrder = nextItems.safeGet(insertIndex + 1)?.order;
    final newOrder = indexing.generateKeyBetween(preOrder, nextOrder)!;
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.rulesDao.orderProfileAddedRule(
          profileId,
          ruleId: item.id,
          order: newOrder,
        ),
        rollback: (v) => value = v,
      ),
    );
  }
}

@riverpod
class ProfileCustomRules extends _$ProfileCustomRules with AsyncNotifierMixin {
  @override
  Stream<List<Rule>> build(int profileId) {
    return database.rulesDao.queryProfileCustomRules(profileId).watch();
  }

  @override
  List<Rule> get value => state.value ?? [];

  @override
  bool updateShouldNotify(
    AsyncValue<List<Rule>> previous,
    AsyncValue<List<Rule>> next,
  ) {
    return !ruleListEquality.equals(previous.value, next.value);
  }

  void put(Rule rule) {
    final previous = List<Rule>.from(value);
    final newRule = rule.autoOrder(rule, null, previous.firstOrNull?.order);
    value = previous.copyAndPut(newRule, (rule) => rule.id == newRule.id);
    final coordinator = ref.read(settingsApplyProvider.notifier);
    final previousRevision = _customRuleRevisions[newRule.id] ?? 0;
    final revision = previousRevision + 1;
    _customRuleRevisions[newRule.id] = revision;
    final previousRule = previous.where((item) => item.id == newRule.id).firstOrNull;
    unawaited(
      withRollback(
        snapshot: previous,
        action: () async {
          await database.rulesDao.putProfileCustomRule(profileId, newRule);
          coordinator.savedEdit(profileId, () async {
            // A later committed edit of this rule owns its value, even if the
            // user toggled away and back to the same value during application.
            if (_customRuleRevisions[newRule.id] != revision) return;
            if (previousRule == null) {
              await database.rulesDao.delRules([newRule.id]);
            } else {
              await database.rulesDao.putProfileCustomRule(profileId, previousRule);
            }
            _customRuleRevisions[newRule.id] = previousRevision;
          });
        },
        rollback: (v) => value = v,
      ),
    );
  }

  void delAll(Iterable<int> ruleIds) {
    for (final id in ruleIds) {
      _customRuleRevisions[id] = (_customRuleRevisions[id] ?? 0) + 1;
    }
    final previous = List<Rule>.from(value);
    value = List.from(previous.where((item) => !ruleIds.contains(item.id)));
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.rulesDao.delRules(ruleIds),
        rollback: (v) => value = v,
      ),
    );
  }

  void order(int oldIndex, int newIndex) {
    final previous = List<Rule>.from(value);
    int insertIndex = newIndex;
    if (oldIndex < newIndex) insertIndex -= 1;
    final nextItems = List<Rule>.from(previous);
    final item = nextItems.removeAt(oldIndex);
    _customRuleRevisions[item.id] = (_customRuleRevisions[item.id] ?? 0) + 1;
    nextItems.insert(insertIndex, item);
    value = nextItems;
    final preOrder = nextItems.safeGet(insertIndex - 1)?.order;
    final nextOrder = nextItems.safeGet(insertIndex + 1)?.order;
    final newOrder = indexing.generateKeyBetween(preOrder, nextOrder)!;
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.rulesDao.orderProfileCustomRule(
          profileId,
          ruleId: item.id,
          order: newOrder,
        ),
        rollback: (v) => value = v,
      ),
    );
  }
}

@riverpod
class ProxyGroups extends _$ProxyGroups with AsyncNotifierMixin {
  @override
  Stream<List<ProxyGroup>> build(int profileId) {
    return database.proxyGroupsDao.query(profileId).watch();
  }

  @override
  bool updateShouldNotify(
    AsyncValue<List<ProxyGroup>> previous,
    AsyncValue<List<ProxyGroup>> next,
  ) {
    return !proxyGroupsEquality.equals(previous.value, next.value);
  }

  void del(String name) {
    final previous = List<ProxyGroup>.from(value);
    value = List.from(previous.where((item) => item.name != name));
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.proxyGroups.remove(
          (t) => t.profileId.equals(profileId) & t.name.equals(name),
        ),
        rollback: (v) => value = v,
      ),
    );
  }

  bool put(ProxyGroup proxyGroup) {
    final previous = List<ProxyGroup>.from(value);
    final index = previous.indexWhere((item) => item.id == proxyGroup.id);
    if (index == -1 &&
        previous.indexWhere((item) => item.name == proxyGroup.name) != -1) {
      return false;
    }
    if (index != -1) {
      final oldName = previous[index].name;
      final newName = proxyGroup.name;
      if (oldName != newName) {
        database.rulesDao.renameCustomRuleTarget(
          profileId,
          oldName: oldName,
          newName: newName,
        );
        database.proxyGroupsDao.renameProxies(
          profileId,
          oldName: oldName,
          newName: newName,
        );
      }
    }
    final icon = proxyGroup.icon?.value;
    if (icon != null) {
      database.iconRecordsDao.put(icon);
    }
    final next = List<ProxyGroup>.from(previous);
    if (index != -1) {
      next[index] = proxyGroup;
    } else {
      next.add(
        proxyGroup.copyWith(
          order: indexing.generateKeyBetween(null, proxyGroup.order),
        ),
      );
    }
    value = next;
    unawaited(
      withRollback(
        snapshot: previous,
        action: () =>
            database.proxyGroups.put(proxyGroup.toCompanion(profileId)),
        rollback: (v) => value = v,
      ),
    );
    return true;
  }

  void order(int oldIndex, int newIndex) {
    final previous = List<ProxyGroup>.from(value);
    int insertIndex = newIndex;
    if (oldIndex < newIndex) insertIndex -= 1;
    final nextItems = List<ProxyGroup>.from(previous);
    final item = nextItems.removeAt(oldIndex);
    nextItems.insert(insertIndex, item);
    value = nextItems;
    final preOrder = nextItems.safeGet(insertIndex - 1)?.order;
    final nextOrder = nextItems.safeGet(insertIndex + 1)?.order;
    final newOrder = indexing.generateKeyBetween(preOrder, nextOrder)!;
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.proxyGroupsDao.order(
          profileId,
          proxyGroup: item,
          order: newOrder,
        ),
        rollback: (v) => value = v,
      ),
    );
  }

  @override
  List<ProxyGroup> get value => state.value ?? [];
}

@riverpod
class ProfileDisabledRuleIds extends _$ProfileDisabledRuleIds
    with AsyncNotifierMixin {
  @override
  List<int> get value => state.value ?? [];

  @override
  Stream<List<int>> build(int profileId) {
    return database.rulesDao
        .queryProfileDisabledRules(profileId)
        .map((item) => item.id)
        .watch();
  }

  @override
  bool updateShouldNotify(
    AsyncValue<List<int>> previous,
    AsyncValue<List<int>> next,
  ) {
    return !intListEquality.equals(previous.value, next.value);
  }

  void _put(int ruleId) {
    final newList = List<int>.from(value);
    final index = newList.indexWhere((item) => item == ruleId);
    if (index != -1) {
      newList[index] = ruleId;
    } else {
      newList.insert(0, ruleId);
    }
    value = newList;
  }

  void del(int ruleId) {
    final previous = List<int>.from(value);
    value = List.from(previous.where((item) => item != ruleId));
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.rulesDao.delDisabledLink(profileId, ruleId),
        rollback: (v) => value = v,
      ),
    );
  }

  void put(int ruleId) {
    final previous = List<int>.from(value);
    _put(ruleId);
    unawaited(
      withRollback(
        snapshot: previous,
        action: () => database.rulesDao.putDisabledLink(profileId, ruleId),
        rollback: (v) => value = v,
      ),
    );
  }
}
