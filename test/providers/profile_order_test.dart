import 'package:drift/native.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/services/profile_order.dart';
import 'package:flutter_test/flutter_test.dart';

Profile profile(int id, {int? order, String? label}) => Profile(
  id: id, order: order, label: label ?? '$id',
  autoUpdateDuration: const Duration(hours: 1),
);

void main() {
  test('downward drag to end and upward drag preserve correct positions', () {
    final items = [profile(1), profile(2), profile(3)];
    reorderProfileList(items, 0, 3);
    expect(items.map((p) => p.id), [2, 3, 1]);
    reorderProfileList(items, 2, 0);
    expect(items.map((p) => p.id), [1, 2, 3]);
    reorderProfileList(items, 0, 1);
    expect(items.map((p) => p.id), [1, 2, 3]);
  });

  test('old sheet keeps current metadata, new rows and excludes deleted rows', () {
    final result = mergeProfileOrder(
      [profile(1, label: 'updated'), profile(3), profile(4)], [3, 2, 1]);
    expect(result.map((p) => p.id), [3, 1, 4]);
    expect(result.map((p) => p.order), [0, 1, 2]);
    expect(result[1].label, 'updated');
  });

  test('repeated sorts persist a newly added null-order profile correctly', () async {
    final db = Database(NativeDatabase.memory());
    addTearDown(db.close);
    for (final item in [profile(1, order: 0), profile(2, order: 1), profile(3, label: '123')]) {
      await db.profiles.put(item.toCompanion());
    }
    for (final ids in [[3, 1, 2], [1, 3, 2], [1, 2, 3], [3, 2, 1]]) {
      await db.profilesDao.reorderIds(ids);
      final loaded = await db.profilesDao.query().get();
      expect(loaded.map((p) => p.id), ids);
      expect(loaded.map((p) => p.order), [0, 1, 2]);
      expect(loaded.firstWhere((p) => p.id == 3).label, '123');
    }
    await db.profiles.remove((row) => row.id.equals(3));
    await db.profilesDao.reorderIds([3, 2, 1]);
    expect((await db.profilesDao.query().get()).map((p) => p.id), [2, 1]);
  });
}
