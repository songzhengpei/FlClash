import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/providers/settings_apply.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/profiles/preview.dart';
import 'package:fl_clash/widgets/surge/surge.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'custom/custom.dart';
import 'script.dart';
import 'standard.dart';

class OverwriteView extends ConsumerStatefulWidget {
  final int profileId;

  const OverwriteView({super.key, required this.profileId});

  @override
  ConsumerState<OverwriteView> createState() => _OverwriteViewState();
}

class _OverwriteViewState extends ConsumerState<OverwriteView> {
  @override
  void initState() {
    super.initState();
  }

  Future<void> _handlePreview() async {
    final profile = ref.read(profileProvider(widget.profileId));
    if (profile == null) {
      return;
    }
    BaseNavigator.push<String>(context, PreviewProfileView(profile: profile));
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return ProfileIdProvider(
      profileId: widget.profileId,
      child: CommonScaffold(
        title: appLocalizations.override,
        appBarActions: [
          SlAppBarIconAction(
            icon: SurgeIcons.visibility,
            tooltip: appLocalizations.preview,
            onPressed: _handlePreview,
          ),
        ],
        body: const CustomScrollView(slivers: [_Title(), _Content()]),
      ),
    );
  }

  @override
  void dispose() {
    super.dispose();
    globalState.container.read(settingsApplyProvider.notifier)
        .savedEdit(widget.profileId, () async {});
  }
}

class _Title extends ConsumerWidget {
  const _Title();

  String _getTitle(BuildContext context, OverwriteType type) {
    return switch (type) {
      OverwriteType.standard => context.appLocalizations.standard,
      OverwriteType.script => context.appLocalizations.script,
      OverwriteType.custom => context.appLocalizations.overwriteTypeCustom,
    };
  }

  IconData _getIcon(OverwriteType type) {
    return switch (type) {
      OverwriteType.standard => SurgeIcons.stars,
      OverwriteType.script => SurgeIcons.rocket,
      OverwriteType.custom => SurgeIcons.dashboardCustomize,
    };
  }

  String _getDesc(BuildContext context, OverwriteType type) {
    return switch (type) {
      OverwriteType.standard => context.appLocalizations.standardModeDesc,
      OverwriteType.script => context.appLocalizations.scriptModeDesc,
      OverwriteType.custom => context.appLocalizations.overwriteTypeCustomDesc,
    };
  }

  void _handleChangeType(WidgetRef ref, int profileId, OverwriteType type) {
    ref.read(profilesProvider.notifier).updateProfile(profileId, (state) {
      return state.copyWith(overwriteType: type);
    });
  }

  @override
  Widget build(context, ref) {
    final appLocalizations = context.appLocalizations;
    final profileId = ProfileIdProvider.of(context)!.profileId;
    final overwriteType = ref.watch(overwriteTypeProvider(profileId));
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: SurgeCard(
          shadow: false,
          padding: const EdgeInsets.fromLTRB(14, 13, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                appLocalizations.overrideMode,
                style: context.typography.sectionTitle.copyWith(
                  color: SurgeTheme.of(context).textSecondary,
                ),
              ),
              const SizedBox(height: 10),
              SurgeSegmentedControl<OverwriteType>(
                value: overwriteType,
                height: 42,
                items: [
                  for (final type in OverwriteType.values)
                    SurgeSegmentedItem(
                      value: type,
                      label: _getTitle(context, type),
                      icon: _getIcon(type),
                    ),
                ],
                onChanged: (type) {
                  _handleChangeType(ref, profileId, type);
                },
              ),
              const SizedBox(height: 12),
              AnimatedSwitcher(
                duration: SurgeMotion.reveal,
                switchInCurve: SurgeMotion.enterCurve,
                switchOutCurve: SurgeMotion.exitCurve,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween(
                      begin: const Offset(0, -0.08),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: Text(
                  _getDesc(context, overwriteType),
                  key: ValueKey(overwriteType),
                  style: context.typography.supporting.copyWith(
                    color: SurgeTheme.of(context).textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Content extends ConsumerWidget {
  const _Content();

  @override
  Widget build(BuildContext context, ref) {
    final profileId = ProfileIdProvider.of(context)!.profileId;
    final overwriteType = ref.watch(overwriteTypeProvider(profileId));
    ref.listen(clashConfigProvider(profileId), (_, _) {});
    return switch (overwriteType) {
      OverwriteType.standard => const StandardContent(),
      OverwriteType.script => const ScriptContent(),
      OverwriteType.custom => const CustomContent(),
    };
  }
}
