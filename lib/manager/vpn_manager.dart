import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_clash/widgets/settings_apply_status.dart';

class VpnManager extends ConsumerWidget {
  const VpnManager({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsApplyFeedback(child: child);
  }
}
