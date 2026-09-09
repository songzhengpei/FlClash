import 'package:fl_clash/common/app_localizations.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/plugins/tile.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

bool shouldHandleTileFullStop({
  required bool isStart,
  required bool isSmartStopped,
}) => isStart || isSmartStopped;

class TileManager extends ConsumerStatefulWidget {
  final Widget child;

  const TileManager({super.key, required this.child});

  @override
  ConsumerState<TileManager> createState() => _TileContainerState();
}

class _TileContainerState extends ConsumerState<TileManager> with TileListener {
  @override
  Widget build(BuildContext context) {
    return widget.child;
  }

  bool get isStart => ref.read(isStartProvider);

  bool get isSmartStopped => ref.read(isSmartStoppedProvider);

  @override
  Future<void> onStart() async {
    await ref.read(setupActionProvider.notifier).updateStatus(true);
    if (isStart) {
      await app?.tip(currentAppLocalizations.startVpn);
    }
    super.onStart();
  }

  @override
  Future<void> onStop() async {
    await ref.read(setupActionProvider.notifier).updateStatus(false);
    if (!isStart && !isSmartStopped) {
      await app?.tip(currentAppLocalizations.stopVpn);
    }
    super.onStop();
  }

  @override
  Future<void> onSmartStop() async {
    await ref.read(smartAutoStopManagerProvider.notifier).pauseNow();
    super.onSmartStop();
  }

  @override
  Future<void> onSmartResume() async {
    await ref.read(smartAutoStopManagerProvider.notifier).resumeNow();
    super.onSmartResume();
  }

  @override
  Future<void> onSync() async {
    if (!ref.read(initProvider)) return;
    await ref.read(setupActionProvider.notifier).reconcileNativeSession();
    super.onSync();
  }

  @override
  void initState() {
    super.initState();
    tile?.addListener(this);
  }

  @override
  void dispose() {
    tile?.removeListener(this);
    super.dispose();
  }
}
