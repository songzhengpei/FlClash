import 'package:drift/native.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rule flags survive committed DAO writes in both directions', () async {
    final db = Database(NativeDatabase.memory());
    addTearDown(db.close);
    await db.profiles.put(
      const Profile(
        id: 1,
        autoUpdateDuration: Duration(hours: 1),
      ).toCompanion(),
    );
    const rule = Rule(
      id: 11,
      ruleAction: RuleAction.IP_CIDR,
      content: '10.0.0.0/8',
      ruleTarget: 'DIRECT',
    );
    for (final enabled in [true, false]) {
      final saved = rule.copyWith(noResolve: enabled, src: enabled);
      await db.rulesDao.putProfileCustomRule(1, saved);
      final loaded =
          (await db.rulesDao.queryProfileCustomRules(1).get()).single;
      expect(loaded.noResolve, enabled);
      expect(loaded.src, enabled);
      expect(loaded.rawValue, saved.rawValue);
    }
  });
}
