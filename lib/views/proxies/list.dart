import 'dart:math';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/services/providers/provider_readiness_service.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/surge/surge.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'card.dart';
import 'common.dart';
import 'empty.dart';
import 'list_layout.dart';
import 'scrolling_label.dart';

typedef GroupNameProxiesMap = Map<String, List<Proxy>>;

class ProxiesListView extends StatefulWidget {
  const ProxiesListView({super.key});

  @override
  State<ProxiesListView> createState() => _ProxiesListViewState();
}

class _ProxiesListViewState extends State<ProxiesListView> {
  final _controller = ScrollController();
  final _labelPlaybackCoordinator = ProxyLabelPlaybackCoordinator();
  final _headerStateNotifier = ValueNotifier<ProxiesListHeaderSelectorState?>(
    null,
  );
  List<double> _headerOffset = [];
  double containerHeight = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_adjustHeader);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _adjustHeader();
    });
  }

  ProxiesListHeaderSelectorState _getProxiesListHeaderSelectorState(
    double initOffset,
  ) {
    final index = _headerOffset.findInterval(initOffset);
    final currentIndex = index;
    double headerOffset = 0.0;
    if (index + 1 <= _headerOffset.length - 1) {
      final endOffset = _headerOffset[index + 1];
      final startOffset = endOffset - listHeaderHeight;
      if (initOffset > startOffset && initOffset < endOffset) {
        headerOffset = initOffset - startOffset;
      }
    }
    return ProxiesListHeaderSelectorState(
      offset: max(headerOffset, 0),
      currentIndex: currentIndex,
    );
  }

  void _adjustHeader() {
    _headerStateNotifier.value = _getProxiesListHeaderSelectorState(
      !_controller.hasClients ? 0 : _controller.offset,
    );
  }

  @override
  void dispose() {
    _labelPlaybackCoordinator.dispose();
    _headerStateNotifier.dispose();
    _controller.removeListener(_adjustHeader);
    _controller.dispose();
    super.dispose();
  }

  bool _onUserScroll(UserScrollNotification notification) {
    if (notification.direction != ScrollDirection.idle) {
      _labelPlaybackCoordinator.cancelActive();
    }
    return false;
  }

  void _handleChange(Set<String> currentUnfoldSet, String groupName) {
    _labelPlaybackCoordinator.requestReplayFor(groupName);
    _autoScrollToGroup(groupName);
    final tempUnfoldSet = Set<String>.from(currentUnfoldSet);
    if (tempUnfoldSet.contains(groupName)) {
      tempUnfoldSet.remove(groupName);
    } else {
      tempUnfoldSet.add(groupName);
    }
    updateCurrentUnfoldSet(tempUnfoldSet);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _adjustHeader();
    });
  }

  bool _shouldShowStickyHeader({
    required int index,
    required Group group,
    required Set<String> currentUnfoldSet,
  }) {
    if (!_controller.hasClients ||
        index < 0 ||
        index >= _headerOffset.length ||
        _controller.offset <= _headerOffset[index] + 0.5) {
      return false;
    }
    if (!currentUnfoldSet.contains(group.name)) {
      return false;
    }
    return true;
  }

  Widget _buildRow(
    int groupIndex,
    int proxyIndex, {
    required List<Group> groups,
    required Set<String> currentUnfoldSet,
    required ProxyCardType cardType,
  }) {
    final group = groups[groupIndex];
    final isFirstGroup = groupIndex == 0;
    final isLastGroup = groupIndex == groups.length - 1;
    final expanded = currentUnfoldSet.contains(group.name);
    if (proxyIndex < 0) {
      final hasProxies = expanded && group.all.isNotEmpty;
      return SizedBox(
        key: ValueKey(group.name),
        height: listHeaderHeight,
        child: ListHeader(
          key: ValueKey('proxy-header-${group.name}'),
          labelPlaybackCoordinator: _labelPlaybackCoordinator,
          playbackOrder: groupIndex,
          onScrollToSelected: _scrollToGroupSelected,
          isExpand: expanded,
          rowPosition: isFirstGroup
              ? (isLastGroup && !hasProxies
                    ? ProxyListRowPosition.single
                    : ProxyListRowPosition.first)
              : (isLastGroup && !hasProxies
                    ? ProxyListRowPosition.last
                    : ProxyListRowPosition.middle),
          showDivider: !(isLastGroup && !hasProxies),
          group: group,
          onChange: (name) => _handleChange(currentUnfoldSet, name),
        ),
      );
    }
    final proxy = group.all[proxyIndex];
    final last = isLastGroup && proxyIndex == group.all.length - 1;
    return SizedBox(
      height: getProxyTileHeight(),
      child: ProxyCard(
        testUrl: group.testUrl,
        type: cardType,
        groupType: group.type,
        key: ValueKey('${group.name}.${proxy.name}'),
        proxy: proxy,
        groupName: group.name,
        isExpanded: true,
        rowPosition: last
            ? ProxyListRowPosition.last
            : ProxyListRowPosition.middle,
        showDivider: !last,
      ),
    );
  }

  Widget _buildHeader(
    WidgetRef ref, {
    required Group group,
    required Set<String> currentUnfoldSet,
    required int playbackOrder,
    ProxyListRowPosition? rowPosition,
  }) {
    final groupName = group.name;
    final isExpand = currentUnfoldSet.contains(groupName);
    return SizedBox(
      height: listHeaderHeight,
      child: ListHeader(
        labelPlaybackCoordinator: _labelPlaybackCoordinator,
        playbackOrder: playbackOrder,
        enterAnimated: false,
        onScrollToSelected: _scrollToGroupSelected,
        key: Key(groupName),
        isExpand: isExpand,
        rowPosition:
            rowPosition ??
            (isExpand
                ? ProxyListRowPosition.first
                : ProxyListRowPosition.single),
        showDivider: isExpand,
        group: group,
        onChange: (String groupName) {
          _handleChange(currentUnfoldSet, groupName);
        },
      ),
    );
  }

  double _getGroupOffset(String groupName) {
    if (_controller.position.maxScrollExtent == 0) {
      return 0;
    }
    final currentGroups = getCurrentGroups();
    final findIndex = currentGroups.indexWhere(
      (item) => item.name == groupName,
    );
    final index = findIndex != -1 ? findIndex : 0;
    return _headerOffset[index];
  }

  void _scrollToMakeVisibleWithPadding({
    required double containerHeight,
    required double pixels,
    required double start,
    required double end,
    double padding = 24,
  }) {
    final visibleStart = pixels;
    final visibleEnd = pixels + containerHeight;

    final isElementVisible = start >= visibleStart && end <= visibleEnd;
    if (isElementVisible) {
      return;
    }

    double targetScrollOffset;

    if (end <= visibleStart) {
      targetScrollOffset = start;
    } else if (start >= visibleEnd) {
      targetScrollOffset = end - containerHeight + padding;
    } else {
      final visibleTopPart = end - visibleStart;
      final visibleBottomPart = visibleEnd - start;
      if (visibleTopPart.abs() >= visibleBottomPart.abs()) {
        targetScrollOffset = end - containerHeight + padding;
      } else {
        targetScrollOffset = start;
      }
    }

    targetScrollOffset = targetScrollOffset.clamp(
      _controller.position.minScrollExtent,
      _controller.position.maxScrollExtent,
    );

    _controller.jumpTo(targetScrollOffset);
  }

  void _autoScrollToGroup(String groupName) {
    final pixels = _controller.position.pixels;
    final offset = _getGroupOffset(groupName);
    _scrollToMakeVisibleWithPadding(
      containerHeight: containerHeight,
      pixels: pixels,
      start: offset,
      end: offset + listHeaderHeight,
    );
  }

  void _scrollToGroupSelected(String groupName) {
    final currentInitOffset = _getGroupOffset(groupName);
    final currentGroups = getCurrentGroups();
    final proxies = currentGroups.getGroup(groupName)?.all;
    _jumpTo(
      currentInitOffset +
          getScrollToSelectedOffset(
            groupName: groupName,
            proxies: proxies ?? [],
          ),
    );
  }

  void _jumpTo(double offset) {
    if (mounted && _controller.hasClients) {
      _controller.animateTo(
        offset.clamp(
          _controller.position.minScrollExtent,
          _controller.position.maxScrollExtent,
        ),
        duration: SurgeMotion.scroll,
        curve: Curves.easeIn,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (_, ref, _) {
        ProxyTrace.noteHotspotBuild('proxies_list');
        ref.listen<PageLabel>(currentPageLabelProvider, (previous, next) {
          _labelPlaybackCoordinator.setPageActive(next == PageLabel.proxies);
        });
        _labelPlaybackCoordinator.setPageActive(
          ref.read(currentPageLabelProvider) == PageLabel.proxies,
        );
        final state = ref.watch(proxiesListStateProvider);
        final snapshotState = ref.watch(proxyGroupsSnapshotProvider);
        ref.watch(themeSettingProvider.select((state) => state.textScale));
        final hasGroups = state.groups.isNotEmpty;
        if (hasGroups) {
          ProxyTrace.noteFirstGroupVisible();
        }
        final freshness = snapshotState.freshness;
        if (!hasGroups) {
          final isFailed = freshness == ProxyGroupsFreshnessState.failed;
          final isRefreshing =
              freshness == ProxyGroupsFreshnessState.refreshing;
          final canRefresh = freshness != ProxyGroupsFreshnessState.refreshing;
          final readinessError = snapshotState.error;
          final emptyKind = isRefreshing
              ? ProxiesEmptyStateKind.loading
              : readinessError is ProviderReadinessCoreUnavailable
              ? ProxiesEmptyStateKind.coreUnavailable
              : readinessError is ProviderReadinessTimeout
              ? ProxiesEmptyStateKind.timeout
              : isFailed
              ? ProxiesEmptyStateKind.failed
              : ProxiesEmptyStateKind.empty;
          final emptyLabel = switch (emptyKind) {
            ProxiesEmptyStateKind.loading =>
              context.appLocalizations.syncingProxyGroups,
            ProxiesEmptyStateKind.timeout =>
              context.appLocalizations.providerNotReady,
            ProxiesEmptyStateKind.coreUnavailable =>
              context.appLocalizations.proxyCoreUnavailable,
            ProxiesEmptyStateKind.failed =>
              context.appLocalizations.providerLoadFailed,
            ProxiesEmptyStateKind.empty =>
              context.appLocalizations.noProxyGroups,
          };
          final emptyDescription = switch (emptyKind) {
            ProxiesEmptyStateKind.loading =>
              context.appLocalizations.fetchingProviderNodes,
            ProxiesEmptyStateKind.timeout =>
              context.appLocalizations.checkNetworkAndRetry,
            ProxiesEmptyStateKind.coreUnavailable =>
              context.appLocalizations.reconnectPrompt,
            ProxiesEmptyStateKind.failed =>
              context.appLocalizations.tryAgainLater,
            ProxiesEmptyStateKind.empty =>
              context.appLocalizations.noAvailableNodesInProfile,
          };
          return ProxiesEmptyState(
            label: emptyLabel,
            description: emptyDescription,
            actionLabel: canRefresh
                ? emptyKind == ProxiesEmptyStateKind.coreUnavailable
                      ? context.appLocalizations.reconnect
                      : emptyKind == ProxiesEmptyStateKind.empty
                      ? context.appLocalizations.refreshProxyGroups
                      : context.appLocalizations.reload
                : null,
            onAction: canRefresh
                ? () {
                    globalState.loadingRun(
                      () async {
                        await ref
                            .read(proxiesActionProvider.notifier)
                            .ensureCurrentProfileReady(forceApply: true);
                      },
                      silence: false,
                      tag: LoadingTag.proxies,
                    );
                  }
                : null,
            actionLoading: isRefreshing,
            kind: emptyKind,
          );
        }
        final layout = ProxyListLayout(
          nodeCounts: [
            for (final group in state.groups)
              state.currentUnfoldSet.contains(group.name)
                  ? group.all.length
                  : 0,
          ],
          headerHeight: listHeaderHeight,
          nodeHeight: getProxyTileHeight(),
        );
        _headerOffset = layout.headerOffsets;
        return CommonScrollBar(
          controller: _controller,
          thumbVisibility: true,
          trackVisibility: true,
          child: Stack(
            children: [
              Positioned.fill(
                child: ScrollConfiguration(
                  behavior: HiddenBarScrollBehavior(),
                  child: NotificationListener<UserScrollNotification>(
                    onNotification: _onUserScroll,
                    child: ListView.builder(
                      key: proxiesListStoreKey,
                      padding: EdgeInsets.fromLTRB(
                        16,
                        16,
                        16,
                        SurgeBottomNavLayout.mainPageBottomPadding(context),
                      ),
                      controller: _controller,
                      itemCount: layout.rowCount,
                      itemExtentBuilder: (index, _) =>
                          layout.rowAt(index).proxyIndex < 0
                          ? listHeaderHeight
                          : getProxyTileHeight(),
                      itemBuilder: (_, index) {
                        final row = layout.rowAt(index);
                        return _buildRow(
                          row.groupIndex,
                          row.proxyIndex,
                          groups: state.groups,
                          currentUnfoldSet: state.currentUnfoldSet,
                          cardType: state.proxyCardType,
                        );
                      },
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: LayoutBuilder(
                  builder: (_, container) {
                    containerHeight = container.maxHeight;
                    return ValueListenableBuilder(
                      valueListenable: _headerStateNotifier,
                      builder: (_, headerState, _) {
                        if (headerState == null) {
                          return const SizedBox.shrink();
                        }
                        final index = headerState.currentIndex;
                        if (index < 0 ||
                            index >= state.groups.length ||
                            index >= _headerOffset.length) {
                          return const SizedBox.shrink();
                        }
                        final group = state.groups[index];
                        if (!_shouldShowStickyHeader(
                          index: index,
                          group: group,
                          currentUnfoldSet: state.currentUnfoldSet,
                        )) {
                          return const SizedBox.shrink();
                        }
                        return Stack(
                          children: [
                            Positioned(
                              top: 0,
                              child: SizedBox(
                                width: container.maxWidth,
                                height: listHeaderHeight,
                                child: ColoredBox(
                                  color: SurgeTheme.of(context).background,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                    ),
                                    child: _buildHeader(
                                      ref,
                                      group: group,
                                      currentUnfoldSet: state.currentUnfoldSet,
                                      playbackOrder: index,
                                      rowPosition: ProxyListRowPosition.first,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class ListHeader extends StatefulWidget {
  final Group group;

  final Function(String groupName) onChange;
  final Function(String groupName) onScrollToSelected;
  final bool isExpand;
  final ProxyListRowPosition rowPosition;
  final bool showDivider;

  final bool enterAnimated;
  final int playbackOrder;
  final ProxyLabelPlaybackCoordinator labelPlaybackCoordinator;

  const ListHeader({
    super.key,
    this.enterAnimated = true,
    this.rowPosition = ProxyListRowPosition.single,
    this.showDivider = false,
    this.playbackOrder = 0,
    required this.group,
    required this.onChange,
    required this.onScrollToSelected,
    required this.isExpand,
    required this.labelPlaybackCoordinator,
  });

  @override
  State<ListHeader> createState() => _ListHeaderState();
}

class _ListHeaderState extends State<ListHeader> {
  var isLock = false;

  String get icon => widget.group.icon;

  String get groupName => widget.group.name;

  String get groupType => widget.group.type.name;

  bool get isExpand => widget.isExpand;

  Future<void> _delayTest() async {
    if (isLock) return;
    isLock = true;
    await delayTest(widget.group.all, widget.group.testUrl);
    isLock = false;
  }

  void _handleChange(String groupName) {
    widget.onChange(groupName);
  }

  Widget _buildIcon() {
    return Consumer(
      builder: (_, ref, child) {
        final surge = SurgeTheme.of(context);
        final iconStyle = ref.watch(
          proxiesStyleSettingProvider.select((state) => state.iconStyle),
        );
        return switch (iconStyle) {
          ProxiesIconStyle.standard => LayoutBuilder(
            builder: (_, constraints) {
              return Container(
                margin: const EdgeInsets.only(right: 12),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Container(
                    height: constraints.maxHeight,
                    width: constraints.maxWidth,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(surge.radii.input),
                      color: surge.textSecondary.withValues(alpha: 0.08),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: IconTheme.merge(
                      data: IconThemeData(size: constraints.maxHeight - 12),
                      child: CommonTargetIcon(src: icon),
                    ),
                  ),
                ),
              );
            },
          ),
          ProxiesIconStyle.icon => Container(
            margin: const EdgeInsets.only(right: 12),
            child: LayoutBuilder(
              builder: (_, constraints) {
                return IconTheme.merge(
                  data: IconThemeData(size: constraints.maxHeight - 8),
                  child: CommonTargetIcon(src: icon),
                );
              },
            ),
          ),
          ProxiesIconStyle.none => Container(),
        };
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    ProxyTrace.noteHotspotBuild('list_header');
    final surge = SurgeTheme.of(context);
    final radius = BorderRadius.vertical(
      top:
          widget.rowPosition == ProxyListRowPosition.first ||
              widget.rowPosition == ProxyListRowPosition.single
          ? Radius.circular(surge.radii.card)
          : Radius.zero,
      bottom:
          widget.rowPosition == ProxyListRowPosition.last ||
              widget.rowPosition == ProxyListRowPosition.single
          ? Radius.circular(surge.radii.card)
          : Radius.zero,
    );
    final border = Border(
      left: BorderSide(
        color: surge.separator.withValues(alpha: 0.78),
        width: 0.5,
      ),
      right: BorderSide(
        color: surge.separator.withValues(alpha: 0.78),
        width: 0.5,
      ),
      top:
          widget.rowPosition == ProxyListRowPosition.first ||
              widget.rowPosition == ProxyListRowPosition.single
          ? BorderSide(
              color: surge.separator.withValues(alpha: 0.78),
              width: 0.5,
            )
          : BorderSide.none,
      bottom:
          widget.rowPosition == ProxyListRowPosition.last ||
              widget.rowPosition == ProxyListRowPosition.single
          ? BorderSide(
              color: surge.separator.withValues(alpha: 0.78),
              width: 0.5,
            )
          : BorderSide.none,
    );
    final card = Material(
      key: widget.key,
      color: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      borderRadius: radius,
      child: Ink(
        decoration: BoxDecoration(
          color: surge.card,
          borderRadius: radius,
          border: border,
          boxShadow:
              widget.rowPosition == ProxyListRowPosition.first ||
                  widget.rowPosition == ProxyListRowPosition.single
              ? [
                  BoxShadow(
                    color: surge.shadow.withValues(alpha: 0.10),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: SurgePressable(
          scaleFeedback: false,
          overlayInsets: EdgeInsets.symmetric(vertical: surge.spacing.hairline),
          overlayBaseColor: surge.card,
          onTap: () {
            _handleChange(groupName);
          },
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Consumer(
                        builder: (_, ref, _) {
                          final proxyName = ref
                              .watch(selectedProxyNameProvider(groupName))
                              .takeFirstValid([]);
                          final displayLabel = proxyName.isEmpty
                              ? ''
                              : proxyFullDisplayName(
                                  visibleName: proxyName,
                                  resolved: ref.watch(
                                    realSelectedProxyStateProvider(proxyName),
                                  ),
                                );
                          final tooltipMessage = displayLabel.isNotEmpty
                              ? displayLabel
                              : groupName;
                          return LongPressFullText(
                            message: tooltipMessage,
                            onLongPress: () {
                              widget.labelPlaybackCoordinator.requestReplayFor(
                                groupName,
                              );
                            },
                            child: Row(
                              children: [
                                _buildIcon(),
                                Flexible(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      EmojiText(
                                        groupName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: context
                                            .typography
                                            .proxyGroupTitle
                                            .copyWith(color: surge.textPrimary),
                                      ),
                                      const SizedBox(height: 4),
                                      Flexible(
                                        flex: 1,
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          mainAxisAlignment:
                                              MainAxisAlignment.start,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.center,
                                          children: [
                                            Text(
                                              groupType,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: context
                                                  .typography
                                                  .proxySelectorLabel
                                                  .copyWith(
                                                    color: surge.textSecondary,
                                                  ),
                                            ),
                                            const SizedBox(width: 12),
                                            if (displayLabel.isNotEmpty)
                                              Flexible(
                                                flex: 1,
                                                child: ScrollingProxyLabel(
                                                  text: displayLabel,
                                                  ownerKey: groupName,
                                                  order: widget.playbackOrder,
                                                  enableInternalLongPress:
                                                      false,
                                                  coordinator: widget
                                                      .labelPlaybackCoordinator,
                                                  replayToken: isExpand,
                                                  style: context
                                                      .typography
                                                      .proxySelectorLabel
                                                      .copyWith(
                                                        color: surge.textPrimary
                                                            .withValues(
                                                              alpha: 0.78,
                                                            ),
                                                      ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    _buildActions(context),
                  ],
                ),
              ),
              if (widget.showDivider)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 0,
                  child: Divider(
                    height: 0,
                    thickness: surge.spacing.hairline,
                    color: surge.separator,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    return widget.enterAnimated ? FadeScaleEnterBox(child: card) : card;
  }

  Widget _buildActions(BuildContext context) {
    return SoftOsControlDock(
      height: 34,
      children: [
        if (isExpand) ...[
          SoftOsDockButton(
            tooltip: context.appLocalizations.locateCurrentNode,
            icon: SurgeIcons.selector,
            iconSize: 15.5,
            onTap: () {
              widget.onScrollToSelected(groupName);
            },
          ),
          const SoftOsDockDivider(height: 18),
          SoftOsDockButton(
            tooltip: context.appLocalizations.testLatency,
            icon: SurgeIcons.networkPing,
            iconSize: 15.5,
            onTap: _delayTest,
          ),
          const SoftOsDockDivider(height: 18),
        ],
        SoftOsDockButton(
          tooltip: isExpand
              ? context.appLocalizations.collapse
              : context.appLocalizations.expand,
          icon: isExpand ? SurgeIcons.collapse : SurgeIcons.expand,
          iconSize: 15.5,
          onTap: () {
            _handleChange(groupName);
          },
        ),
      ],
    );
  }
}
