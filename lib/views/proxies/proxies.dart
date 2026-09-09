import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/common.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/views/proxies/list.dart';
import 'package:fl_clash/views/proxies/providers.dart';
import 'package:fl_clash/widgets/surge/surge.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'setting.dart';

final _profileHasExternalProvidersProvider = FutureProvider.autoDispose
    .family<bool, int>((ref, profileId) async {
      final definitions = await readProfileProviderDefinitions(profileId);
      return definitions.external;
    });

class ProxiesView extends ConsumerStatefulWidget {
  const ProxiesView({super.key});

  @override
  ConsumerState<ProxiesView> createState() => _ProxiesViewState();
}

class _ProxiesViewState extends ConsumerState<ProxiesView> {
  bool _hasProviders() {
    final runtimeHasProviders = ref.watch(
      providersProvider.select((state) => state.isNotEmpty),
    );
    final currentProfileId = ref.watch(currentProfileIdProvider);
    final profileHasProviders =
        currentProfileId != null &&
        ref
                .watch(_profileHasExternalProvidersProvider(currentProfileId))
                .value ==
            true;
    return runtimeHasProviders || profileHasProviders;
  }

  Future<void> _handleProvidersPressed(BuildContext context) async {
    await ref.read(proxiesActionProvider.notifier).ensureCurrentProfileReady();
    if (!context.mounted) return;
    showSheet(
      context: context,
      props: const SheetProps(isScrollControlled: true),
      builder: (_) {
        return const ProvidersView();
      },
    );
  }

  List<SlAppBarAction> _buildActions(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final hasProviders = _hasProviders();
    return [
      SlAppBarOverflowAction(
        tooltip: appLocalizations.more,
        popup: CommonPopupMenu(
          items: [
            if (hasProviders)
              PopupMenuItemData(
                icon: SurgeIcons.providerDownload,
                label: appLocalizations.providers,
                onPressed: () {
                  unawaited(_handleProvidersPressed(context));
                },
              ),
            PopupMenuItemData(
              icon: SurgeIcons.tune,
              label: appLocalizations.settings,
              onPressed: () {
                showSheet(
                  context: context,
                  props: const SheetProps(isScrollControlled: true),
                  builder: (_) {
                    return AdaptiveSheetScaffold(
                      body: const ProxiesSetting(),
                      title: appLocalizations.settings,
                      appBarActions: const [],
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    ];
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      ref.read(proxiesStyleSettingProvider.notifier).update((state) {
        return state.copyWith(type: ProxiesType.list);
      });

      // A mounted page must not replace current runtime groups with an older
      // disk snapshot (or decode that snapshot again on every page entry).
      if (ref.read(groupsProvider).isEmpty ||
          ref.read(groupsOwnerProfileIdProvider) !=
              ref.read(currentProfileIdProvider)) {
        await ref
            .read(proxiesActionProvider.notifier)
            .hydrateProxyGroupsSnapshot();
      }
      if (!mounted) return;

      final ownerProfileId = ref.read(groupsOwnerProfileIdProvider);
      final currentProfileId = ref.read(currentProfileIdProvider);
      final groupsEmpty =
          ownerProfileId != currentProfileId ||
          ref.read(groupsProvider).isEmpty;
      final lastRefresh = ref.read(lastGroupsRefreshAtProvider);
      final expired =
          lastRefresh == null ||
          DateTime.now().difference(lastRefresh) > const Duration(seconds: 30);
      final plan = ProxyPageEntryPlan(
        ownerProfileId: ownerProfileId,
        currentProfileId: currentProfileId,
        groupsIsEmpty: ref.read(groupsProvider).isEmpty,
        expired: expired,
        snapshotHydrated: ref.read(groupsProvider).isNotEmpty,
      );
      StartupTrace.mark(
        'proxy_page_entry',
        extras: {
          'scenario': plan.scenarioId,
          'ensure_ready': plan.ensureReady,
          'force_apply': plan.forceApply,
          'expired': expired,
          'groups_empty': groupsEmpty,
        },
      );

      if (groupsEmpty || expired) {
        unawaited(
          ref
              .read(proxiesActionProvider.notifier)
              .ensureCurrentProfileReady(forceApply: groupsEmpty),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    ProxyTrace.noteHotspotBuild('proxies_view');
    final surge = SurgeTheme.of(context);
    final isLoading = ref.watch(loadingProvider(LoadingTag.proxies));
    return CommonScaffold(
      isLoading: isLoading,
      resizeToAvoidBottomInset: false,
      appBarActions: _buildActions(context),
      title: context.appLocalizations.proxies,
      titleVariant: SlAppBarTitleVariant.root,
      backgroundColor: surge.background,
      body: ColoredBox(color: surge.background, child: const ProxiesListView()),
    );
  }
}
