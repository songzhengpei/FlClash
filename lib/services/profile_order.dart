import 'package:fl_clash/models/models.dart';

/// Apply a sheet's ID order to current records, retaining newly added profiles.
List<Profile> mergeProfileOrder(List<Profile> current, Iterable<int> ids) {
  final remaining = {for (final profile in current) profile.id: profile};
  final result = <Profile>[];
  for (final id in ids) {
    final profile = remaining.remove(id);
    if (profile != null) result.add(profile);
  }
  result.addAll(remaining.values);
  return [
    for (var i = 0; i < result.length; i++) result[i].copyWith(order: i),
  ];
}

/// Flutter's legacy onReorder index is measured before removing the item.
void reorderProfileList(List<Profile> profiles, int oldIndex, int newIndex) {
  if (newIndex > oldIndex) newIndex--;
  profiles.insert(newIndex, profiles.removeAt(oldIndex));
}
