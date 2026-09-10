import 'dart:async';
import 'dart:math' as math;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/views/dashboard/dashboard_layout.dart';
import 'package:fl_clash/widgets/surge/surge.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

@visibleForTesting
class NetworkOverviewCardLayout {
  const NetworkOverviewCardLayout({
    required this.headerHeight,
    required this.chartHeight,
    required this.trafficTitleToChartGap,
    required this.latencyHeaderToRowsGap,
    required this.afterTrafficGap,
    required this.headerToChartGap,
    required this.chartToDividerGap,
    required this.dividerToTrafficGap,
    required this.detectionTopGap,
    required this.detectionBottomGap,
    required this.latencyRowGap,
  });

  final double headerHeight;
  final double chartHeight;
  final double trafficTitleToChartGap;
  final double latencyHeaderToRowsGap;
  final double afterTrafficGap;
  final double headerToChartGap;
  final double chartToDividerGap;
  final double dividerToTrafficGap;
  final double detectionTopGap;
  final double detectionBottomGap;
  final double latencyRowGap;
}

class NetworkOverviewCardLayoutCalculator {
  const NetworkOverviewCardLayoutCalculator._();

  static const double dividerHeight = 1;
  static const double detectionVerticalGap = 16;
  static const double pixelRoundingAllowance = 1;

  static double headerHeightFor(DashboardResponsiveLayout layout) =>
      math.max(layout.legacy(28), layout.textIcon(18));
  static double chartHeightFor(DashboardResponsiveLayout layout) =>
      layout.legacy(82);
  static double headerToChartGapFor(DashboardResponsiveLayout layout) =>
      layout.legacy(10);
  static double chartToDividerGapFor(DashboardResponsiveLayout layout) =>
      layout.legacy(16);
  static double dividerToTrafficGapFor(DashboardResponsiveLayout layout) =>
      layout.legacy(16);
  static double trafficTitleToChartGapFor(DashboardResponsiveLayout layout) =>
      layout.legacy(24);
  static double latencyHeaderToRowsGapFor(DashboardResponsiveLayout layout) =>
      layout.legacy(14);
  static double latencyRowGapFor(DashboardResponsiveLayout layout) =>
      layout.legacy(12);
  static double trafficToDividerGapFor(DashboardResponsiveLayout layout) =>
      layout.legacy(16);
  static double detectionBarHeightFor(DashboardResponsiveLayout layout) {
    const metricLineHeight = 16.0;
    final scaledLineHeight = metricLineHeight * layout.textScale;
    return layout.legacy(34) + math.max(0, scaledLineHeight - metricLineHeight);
  }

  static double detectionSectionHeightFor(DashboardResponsiveLayout layout) =>
      detectionVerticalGap * 2 + detectionBarHeightFor(layout);

  static double _trafficSectionMinHeightFor(DashboardResponsiveLayout layout) {
    final donutColumn =
        headerHeightFor(layout) +
        trafficTitleToChartGapFor(layout) +
        layout.legacy(78);
    final latencyColumn =
        headerHeightFor(layout) +
        latencyHeaderToRowsGapFor(layout) +
        layout.legacy(25) * 3 +
        latencyRowGapFor(layout) * 2;
    if (layout.requiresReflow) {
      return donutColumn + layout.geometry(12) + latencyColumn;
    }
    return math.max(donutColumn, latencyColumn);
  }

  static double naturalOuterHeightFor(DashboardResponsiveLayout layout) {
    return layout.legacy(16) +
        naturalInnerHeightFor(layout) +
        pixelRoundingAllowance;
  }

  static double naturalInnerHeightFor(DashboardResponsiveLayout layout) {
    final reflowHeaderExtra = layout.requiresReflow ? layout.geometry(32) : 0.0;
    final reflowTextExtra = layout.requiresReflow
        ? layout.legacy(72) * math.max(0, layout.textScale - 1)
        : 0.0;
    return headerHeightFor(layout) +
        reflowHeaderExtra +
        reflowTextExtra +
        headerToChartGapFor(layout) +
        chartHeightFor(layout) +
        chartToDividerGapFor(layout) +
        dividerHeight +
        dividerToTrafficGapFor(layout) +
        _trafficSectionMinHeightFor(layout) +
        trafficToDividerGapFor(layout) +
        dividerHeight +
        detectionSectionHeightFor(layout);
  }

  @visibleForTesting
  static NetworkOverviewCardLayout layoutFor({
    required double availableOuterHeight,
    required DashboardResponsiveLayout responsiveLayout,
    required double contentExpansionFraction,
  }) {
    final naturalOuterHeight = naturalOuterHeightFor(responsiveLayout);
    final resolvedOuterHeight = math.max(
      availableOuterHeight,
      naturalOuterHeight,
    );
    final extraHeight = resolvedOuterHeight - naturalOuterHeight;
    final distributedExtraHeight =
        extraHeight * contentExpansionFraction.clamp(0.0, 1.0);
    return NetworkOverviewCardLayout(
      headerHeight: headerHeightFor(responsiveLayout),
      chartHeight:
          chartHeightFor(responsiveLayout) + distributedExtraHeight * 0.40,
      headerToChartGap:
          headerToChartGapFor(responsiveLayout) + distributedExtraHeight * 0.10,
      chartToDividerGap:
          chartToDividerGapFor(responsiveLayout) +
          distributedExtraHeight * 0.075,
      dividerToTrafficGap:
          dividerToTrafficGapFor(responsiveLayout) +
          distributedExtraHeight * 0.075,
      trafficTitleToChartGap:
          trafficTitleToChartGapFor(responsiveLayout) +
          distributedExtraHeight * 0.10,
      latencyHeaderToRowsGap:
          latencyHeaderToRowsGapFor(responsiveLayout) +
          distributedExtraHeight * 0.06,
      latencyRowGap:
          latencyRowGapFor(responsiveLayout) + distributedExtraHeight * 0.02,
      afterTrafficGap:
          trafficToDividerGapFor(responsiveLayout) +
          distributedExtraHeight * 0.02,
      detectionTopGap: detectionVerticalGap,
      detectionBottomGap: detectionVerticalGap,
    );
  }
}

const _trafficChartMaxY = 0.2;
const _uploadChartCenterY = 0.13;
const _downloadChartCenterY = 0.077;
const _trafficChartHalfSpan =
    (_uploadChartCenterY - _downloadChartCenterY) * 0.45;

List<Point> _trafficSeries(
  List<Traffic> traffics,
  num Function(Traffic traffic) valueOf,
  List<double> placeholder,
  double centerY,
) {
  final values = traffics
      .map((traffic) => valueOf(traffic).toDouble())
      .toList();
  final hasRealData = values.any((value) => value > 0);
  final source = hasRealData ? values : placeholder;
  final minValue = source.reduce((a, b) => a < b ? a : b);
  final maxValue = source.reduce((a, b) => a > b ? a : b);
  final valueSpan = maxValue - minValue;
  return source.asMap().entries.map((entry) {
    final normalized = valueSpan == 0
        ? 0.5
        : (entry.value - minValue) / valueSpan;
    final y =
        centerY -
        _trafficChartHalfSpan +
        normalized * _trafficChartHalfSpan * 2;
    return Point(entry.key.toDouble(), y);
  }).toList();
}

class SurgeNetworkOverviewCard extends StatelessWidget {
  const SurgeNetworkOverviewCard({
    super.key,
    required this.layout,
    this.contentExpansionFraction = 0,
  });

  /// Keeps latency results/timer across Row ↔ Column reflow.
  static final GlobalKey _overviewLatencyHostKey = GlobalKey(
    debugLabel: 'overviewLatencyHost',
  );

  final DashboardResponsiveLayout layout;
  final double contentExpansionFraction;

  @override
  Widget build(BuildContext context) {
    if (NavigationTrace.enabled) {
      NavigationTrace.noteHotspotBuild('network_overview');
    }
    final surge = SurgeTheme.of(context);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        layout.cardHorizontalPadding,
        layout.legacy(16),
        layout.cardHorizontalPadding,
        0,
      ),
      decoration: BoxDecoration(
        color: surge.card,
        borderRadius: BorderRadius.circular(layout.cardRadius),
        border: Border.all(
          color: surge.separator,
          width: surge.spacing.hairline,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final cardLayout = NetworkOverviewCardLayoutCalculator.layoutFor(
            availableOuterHeight: constraints.maxHeight.isFinite
                ? constraints.maxHeight + layout.legacy(16)
                : NetworkOverviewCardLayoutCalculator.naturalOuterHeightFor(
                    layout,
                  ),
            responsiveLayout: layout,
            contentExpansionFraction: contentExpansionFraction,
          );
          final trafficSection = layout.requiresReflow
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _OverviewTrafficTotals(
                      layout: layout,
                      cardLayout: cardLayout,
                    ),
                    SizedBox(height: layout.geometry(12)),
                    _OverviewLatencyHost(
                      key: _overviewLatencyHostKey,
                      layout: layout,
                      cardLayout: cardLayout,
                    ),
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: layout.geometry(112),
                      child: _OverviewTrafficTotals(
                        layout: layout,
                        cardLayout: cardLayout,
                      ),
                    ),
                    Expanded(
                      child: _OverviewLatencyHost(
                        key: _overviewLatencyHostKey,
                        layout: layout,
                        cardLayout: cardLayout,
                      ),
                    ),
                  ],
                );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _OverviewHeader(layout: layout, cardLayout: cardLayout),
              SizedBox(height: cardLayout.headerToChartGap),
              _OverviewSpeedCharts(layout: layout, cardLayout: cardLayout),
              SizedBox(height: cardLayout.chartToDividerGap),
              Container(height: 1, color: surge.separator),
              SizedBox(height: cardLayout.dividerToTrafficGap),
              trafficSection,
              SizedBox(height: cardLayout.afterTrafficGap),
              Container(height: 1, color: surge.separator),
              SizedBox(height: cardLayout.detectionTopGap),
              _OverviewDetectionHost(layout: layout),
              SizedBox(height: cardLayout.detectionBottomGap),
            ],
          );
        },
      ),
    );
  }
}

class _OverviewHeader extends ConsumerWidget {
  const _OverviewHeader({required this.layout, required this.cardLayout});

  final DashboardResponsiveLayout layout;
  final NetworkOverviewCardLayout cardLayout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final surge = SurgeTheme.of(context);
    final isStart = ref.watch(isStartProvider);
    final overviewLabels = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: layout.textIcon(18),
          height: cardLayout.headerHeight,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Icon(
              SurgeIcons.network,
              color: isStart ? surge.primary : surge.inactive,
              size: layout.textIcon(18),
            ),
          ),
        ),
        SizedBox(width: layout.geometry(8)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.appLocalizations.networkOverview,
                style: context.typography.cardTitle.copyWith(
                  color: surge.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    final semantic = surge.semantic;
    final uploadColor = isStart
        ? semantic.dashboardDynamicActive
        : semantic.dashboardInactive;
    final downloadColor = isStart
        ? semantic.dashboardActiveGreen
        : semantic.dashboardInactiveVariant;
    final liveSpeed = ValueListenableBuilder<Traffic>(
      valueListenable: currentSpeedNotifier,
      builder: (_, speed, _) => _LiveSpeedBadge(
        up: speed.up,
        down: speed.down,
        upColor: uploadColor,
        downColor: downloadColor,
        layout: layout,
        reflow: layout.requiresReflow,
      ),
    );
    if (layout.requiresReflow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          overviewLabels,
          SizedBox(height: layout.geometry(8)),
          Align(alignment: Alignment.centerRight, child: liveSpeed),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: overviewLabels),
        SizedBox(width: layout.geometry(12)),
        liveSpeed,
      ],
    );
  }
}

class _OverviewSpeedCharts extends ConsumerWidget {
  const _OverviewSpeedCharts({required this.layout, required this.cardLayout});

  final DashboardResponsiveLayout layout;
  final NetworkOverviewCardLayout cardLayout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (NavigationTrace.enabled) {
      NavigationTrace.noteHotspotEvent('traffic_history_update');
    }
    final surge = SurgeTheme.of(context);
    final semantic = surge.semantic;
    final traffics = ref.watch(trafficsProvider).list;
    final isStart = ref.watch(isStartProvider);
    final uploadPoints = _trafficSeries(
      traffics,
      (traffic) => traffic.up,
      const [0.13, 0.13, 0.13, 0.13, 0.13, 0.13, 0.13, 0.13],
      _uploadChartCenterY,
    );
    final downloadPoints = _trafficSeries(
      traffics,
      (traffic) => traffic.down,
      const [0.077, 0.077, 0.077, 0.077, 0.077, 0.077, 0.077, 0.077],
      _downloadChartCenterY,
    );
    final uploadColor = isStart
        ? semantic.dashboardDynamicActive
        : semantic.dashboardInactive;
    final downloadColor = isStart
        ? semantic.dashboardActiveGreen
        : semantic.dashboardInactiveVariant;
    final lineFillStartAlpha = isStart ? 0.16 : 1.0;
    final lineFillEndAlpha = isStart ? 0.03 : 0.08;
    return SizedBox(
      height: cardLayout.chartHeight,
      child: Stack(
        children: [
          Positioned.fill(
            child: LineChart(
              points: uploadPoints,
              color: uploadColor,
              gradient: true,
              gradientStartAlpha: lineFillStartAlpha,
              gradientEndAlpha: lineFillEndAlpha,
              duration: commonDuration,
              minY: 0,
              maxY: _trafficChartMaxY,
            ),
          ),
          Positioned.fill(
            child: LineChart(
              points: downloadPoints,
              color: downloadColor,
              gradient: true,
              gradientStartAlpha: lineFillStartAlpha,
              gradientEndAlpha: lineFillEndAlpha,
              duration: commonDuration,
              minY: 0,
              maxY: _trafficChartMaxY,
            ),
          ),
        ],
      ),
    );
  }
}

class _OverviewTrafficTotals extends ConsumerWidget {
  const _OverviewTrafficTotals({
    required this.layout,
    required this.cardLayout,
  });

  final DashboardResponsiveLayout layout;
  final NetworkOverviewCardLayout cardLayout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (NavigationTrace.enabled) {
      NavigationTrace.noteHotspotEvent('total_traffic_update');
    }
    final surge = SurgeTheme.of(context);
    final semantic = surge.semantic;
    final totalTraffic = ref.watch(totalTrafficProvider);
    final isStart = ref.watch(isStartProvider);
    final uploadColor = isStart
        ? semantic.dashboardDynamicActive
        : semantic.dashboardInactive;
    final downloadColor = isStart
        ? semantic.dashboardActiveGreen
        : semantic.dashboardInactiveVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: layout.textIcon(18),
              height: cardLayout.headerHeight,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Icon(
                  SurgeIcons.traffic,
                  size: layout.textIcon(18),
                  color: isStart ? surge.primary : surge.inactive,
                ),
              ),
            ),
            SizedBox(width: layout.geometry(8)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.appLocalizations.trafficUsage,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.typography.cardTitle.copyWith(
                      color: surge.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        SizedBox(height: cardLayout.trafficTitleToChartGap),
        Padding(
          padding: EdgeInsets.only(left: layout.geometry(2)),
          child: SizedBox(
            width: layout.legacy(78),
            height: layout.legacy(78),
            child: DonutChart(
              data: [
                DonutChartData(
                  value: totalTraffic.up.toDouble(),
                  color: uploadColor,
                ),
                DonutChartData(
                  value: totalTraffic.down.toDouble(),
                  color: downloadColor,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _OverviewDetectionHost extends ConsumerWidget {
  const _OverviewDetectionHost({required this.layout});

  final DashboardResponsiveLayout layout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (NavigationTrace.enabled) {
      NavigationTrace.noteHotspotEvent('network_detection_update');
    }
    final surge = SurgeTheme.of(context);
    final networkIpInfo = ref.watch(
      networkDetectionProvider.select((s) => s.ipInfo),
    );
    final networkIsLoading = ref.watch(
      networkDetectionProvider.select((s) => s.isLoading),
    );
    final networkHasChecked = ref.watch(
      networkDetectionProvider.select((s) => s.hasChecked),
    );
    final isForeground = ref.watch(appForegroundProvider);
    final isDashboardActive = ref.watch(
      currentPageLabelProvider.select((l) => l == PageLabel.dashboard),
    );
    return _NetworkDetectionBar(
      ipInfo: networkIpInfo,
      isLoading: networkIsLoading,
      hasChecked: networkHasChecked,
      shouldAnimate: isForeground && isDashboardActive && networkIsLoading,
      primaryColor: surge.primary,
      textColor: surge.textPrimary,
      secondaryTextColor: surge.textSecondary,
      fillColor: surge.fill,
      dangerColor: surge.red,
      label: context.appLocalizations.networkDetection,
      layout: layout,
    );
  }
}

/// Test-only mount/dispose counters. Production never reads these.
@visibleForTesting
class OverviewLatencyHostLifecycle {
  OverviewLatencyHostLifecycle._();

  static int mounts = 0;
  static int disposes = 0;

  static void reset() {
    mounts = 0;
    disposes = 0;
  }
}

class _OverviewLatencyHost extends ConsumerStatefulWidget {
  const _OverviewLatencyHost({
    super.key,
    required this.layout,
    required this.cardLayout,
  });

  final DashboardResponsiveLayout layout;
  final NetworkOverviewCardLayout cardLayout;

  @override
  ConsumerState<_OverviewLatencyHost> createState() =>
      _OverviewLatencyHostState();
}

class _OverviewLatencyHostState extends ConsumerState<_OverviewLatencyHost> {
  static const _latencyRefreshInterval = Duration(seconds: 60);
  static const _pageLabel = PageLabel.dashboard;
  static const _coalesceWindow = Duration(milliseconds: 200);

  late final NetworkDiagnosticsSession _session;
  Timer? _latencyRefreshTimer;
  Timer? _coalesceTimer;
  var _pendingRouteChange = false;
  String _pendingReason = 'periodic';

  Map<String, NetworkDiagnosticTargetState> get _latencyResults =>
      _session.store.states;

  @override
  void initState() {
    super.initState();
    OverviewLatencyHostLifecycle.mounts++;
    _session = NetworkDiagnosticsSession(
      listConnections: () => CoreController().getConnections(),
      coreCountryLookup: (ip) async {
        final info = await CoreController().getCountryCode(ip);
        return info?.countryCode;
      },
    );
    ref.listenManual(appForegroundProvider, (prev, next) {
      _syncLatencyRefreshTimer();
      if (next) {
        _requestRefresh(reason: 'foreground', routeChange: true);
      }
    });
    ref.listenManual(currentPageLabelProvider, (prev, next) {
      _syncLatencyRefreshTimer();
      if (next == _pageLabel) {
        _requestRefresh(reason: 'dashboard_active', routeChange: true);
      }
    });
    ref.listenManual(isStartProvider, (prev, next) {
      if (prev != next) {
        _requestRefresh(
          reason: next ? 'vpn_start' : 'vpn_stop',
          routeChange: true,
        );
      }
    });
    ref.listenManual(checkIpNumProvider, (prev, next) {
      if (prev != next) {
        _requestRefresh(reason: 'connectivity', routeChange: true);
      }
    });
    ref.listenManual(isSmartStoppedProvider, (prev, next) {
      if (prev != next) {
        _requestRefresh(reason: 'smart_stop', routeChange: true);
      }
    });
    NetworkDiagnosticsRevision.addListener(_onRevision);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_shouldRunLatencyRefresh(ref)) {
        _requestRefresh(reason: 'dashboard_active', routeChange: false);
      }
      _syncLatencyRefreshTimer();
    });
  }

  void _onRevision() {
    _requestRefresh(reason: 'route_revision', routeChange: true);
  }

  @override
  void dispose() {
    OverviewLatencyHostLifecycle.disposes++;
    NetworkDiagnosticsRevision.removeListener(_onRevision);
    if (NavigationTrace.enabled) {
      NavigationTrace.networkLatencyTimerActive = false;
    }
    _latencyRefreshTimer?.cancel();
    _coalesceTimer?.cancel();
    super.dispose();
  }

  bool _shouldRunLatencyRefresh(WidgetRef ref) {
    final uiAutoRefresh = ref.read(uiAutoRefreshEnabledProvider);
    final isDashboardPage = ref.read(currentPageLabelProvider) == _pageLabel;
    return uiAutoRefresh && isDashboardPage;
  }

  bool _shouldUseClashRoute(WidgetRef ref) {
    final isRunning = ref.read(isStartProvider);
    final isSmartStopped = ref.read(isSmartStoppedProvider);
    return isRunning && !isSmartStopped;
  }

  void _syncLatencyRefreshTimer() {
    if (!_shouldRunLatencyRefresh(ref)) {
      if (_latencyRefreshTimer != null) {
        _latencyRefreshTimer?.cancel();
        _latencyRefreshTimer = null;
      }
      if (NavigationTrace.enabled) {
        NavigationTrace.networkLatencyTimerActive = false;
      }
      return;
    }
    if (_latencyRefreshTimer != null) return;
    _latencyRefreshTimer = Timer.periodic(_latencyRefreshInterval, (_) {
      _requestRefresh(reason: 'periodic', routeChange: false);
    });
    if (NavigationTrace.enabled) {
      NavigationTrace.networkLatencyTimerActive = true;
    }
  }

  void _requestRefresh({
    required String reason,
    required bool routeChange,
    bool immediate = false,
  }) {
    if (immediate) {
      _coalesceTimer?.cancel();
      unawaited(_runRefresh(reason: reason, routeChange: routeChange));
      return;
    }
    _pendingRouteChange = _pendingRouteChange || routeChange;
    _pendingReason = reason;
    _coalesceTimer?.cancel();
    _coalesceTimer = Timer(_coalesceWindow, () {
      final pendingChange = _pendingRouteChange;
      _pendingRouteChange = false;
      unawaited(
        _runRefresh(reason: _pendingReason, routeChange: pendingChange),
      );
    });
  }

  Future<void> _runRefresh({
    required String reason,
    required bool routeChange,
  }) async {
    if (!mounted) return;
    final hasProxy = _shouldUseClashRoute(ref);
    final mixedPort = hasProxy
        ? ref.read(patchClashConfigProvider).mixedPort
        : null;
    await _session.refresh(
      mixedPort: mixedPort != 0 ? mixedPort : null,
      routeChange: routeChange,
      reason: reason,
      onChanged: () {
        if (mounted) {
          _latencySetState(() {});
        }
      },
    );
  }

  void _latencySetState(VoidCallback fn) {
    if (NavigationTrace.enabled) {
      NavigationTrace.noteHotspotEvent('latency_setState');
    }
    setState(fn);
  }

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    final semantic = surge.semantic;
    final isForeground = ref.watch(appForegroundProvider);
    final isDashboardActive = ref.watch(
      currentPageLabelProvider.select((l) => l == PageLabel.dashboard),
    );
    final hasRefreshing = _latencyResults.values.any((r) => r.refreshing);
    final shouldAnimatePending =
        isForeground && isDashboardActive && hasRefreshing;
    final cardLayout = widget.cardLayout;
    final responsiveLayout = widget.layout;
    return Column(
      children: [
        SizedBox(
          height: cardLayout.headerHeight,
          child: Row(
            children: [
              const Spacer(),
              _OverviewTotalTrafficBadge(layout: responsiveLayout),
            ],
          ),
        ),
        SizedBox(height: cardLayout.latencyHeaderToRowsGap),
        PlatformLatencyPanel(
          targets: NetworkDiagnosticTarget.all,
          results: _latencyResults,
          fallbackCountryCode: null,
          activeColor: semantic.dashboardDynamicActive,
          fillColor: surge.fill,
          textColor: surge.textPrimary,
          secondaryTextColor: surge.textSecondary,
          dangerColor: surge.red,
          latencyGood: semantic.latencyGood,
          latencyMedium: semantic.latencyMedium,
          latencyBad: semantic.latencyBad,
          onRetest: () => _requestRefresh(
            reason: 'manual',
            routeChange: false,
            immediate: true,
          ),
          shouldAnimatePending: shouldAnimatePending,
          rowGap: cardLayout.latencyRowGap,
          layout: responsiveLayout,
        ),
      ],
    );
  }
}

class _OverviewTotalTrafficBadge extends ConsumerWidget {
  const _OverviewTotalTrafficBadge({required this.layout});

  final DashboardResponsiveLayout layout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final surge = SurgeTheme.of(context);
    final semantic = surge.semantic;
    final totalTraffic = ref.watch(totalTrafficProvider);
    final isStart = ref.watch(isStartProvider);
    return _TotalTrafficBadge(
      up: totalTraffic.up,
      down: totalTraffic.down,
      upColor: isStart
          ? semantic.dashboardDynamicActive
          : semantic.dashboardInactive,
      downColor: isStart
          ? semantic.dashboardActiveGreen
          : semantic.dashboardInactiveVariant,
      layout: layout,
    );
  }
}

class _LiveSpeedBadge extends StatelessWidget {
  const _LiveSpeedBadge({
    required this.up,
    required this.down,
    required this.upColor,
    required this.downColor,
    required this.layout,
    required this.reflow,
  });

  final num up;
  final num down;
  final Color upColor;
  final Color downColor;
  final DashboardResponsiveLayout layout;
  final bool reflow;

  @override
  Widget build(BuildContext context) {
    final lines = [
      _LiveSpeedLine(
        icon: SurgeIcons.arrowUp,
        value: '${up.traffic.show}/s',
        color: upColor,
        layout: layout,
      ),
      _LiveSpeedLine(
        icon: SurgeIcons.arrowDown,
        value: '${down.traffic.show}/s',
        color: downColor,
        layout: layout,
      ),
    ];
    return reflow
        ? Wrap(
            spacing: layout.geometry(12),
            runSpacing: layout.geometry(6),
            alignment: WrapAlignment.end,
            children: lines,
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              lines.first,
              SizedBox(width: layout.geometry(12)),
              lines.last,
            ],
          );
  }
}

class _LiveSpeedLine extends StatelessWidget {
  const _LiveSpeedLine({
    required this.icon,
    required this.value,
    required this.color,
    required this.layout,
  });

  final IconData icon;
  final String value;
  final Color color;
  final DashboardResponsiveLayout layout;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: layout.textIcon(14), color: color),
        SizedBox(width: layout.geometry(4)),
        Text(value, style: context.typography.metric.copyWith(color: color)),
      ],
    );
  }
}

class _NetworkDetectionBar extends StatelessWidget {
  const _NetworkDetectionBar({
    required this.ipInfo,
    required this.isLoading,
    required this.hasChecked,
    required this.shouldAnimate,
    required this.primaryColor,
    required this.textColor,
    required this.secondaryTextColor,
    required this.fillColor,
    required this.dangerColor,
    required this.label,
    required this.layout,
  });

  final DashboardResponsiveLayout layout;

  final IpInfo? ipInfo;
  final bool isLoading;
  final bool hasChecked;
  final bool shouldAnimate;
  final Color primaryColor;
  final Color textColor;
  final Color secondaryTextColor;
  final Color fillColor;
  final Color dangerColor;
  final String label;

  String _countryCodeToEmoji(String countryCode) {
    final code = countryCode.toUpperCase();
    if (code.length != 2) return countryCode;
    final firstLetter = code.codeUnitAt(0) - 0x41 + 0x1F1E6;
    final secondLetter = code.codeUnitAt(1) - 0x41 + 0x1F1E6;
    return String.fromCharCode(firstLetter) + String.fromCharCode(secondLetter);
  }

  @override
  Widget build(BuildContext context) {
    final height = NetworkOverviewCardLayoutCalculator.detectionBarHeightFor(
      layout,
    );
    // Local variables for type promotion (fields can't be promoted by null check)
    final localIpInfo = ipInfo;
    final localIsLoading = isLoading;

    Widget valueWidget;
    if (localIpInfo != null) {
      valueWidget = Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            _countryCodeToEmoji(localIpInfo.countryCode),
            maxLines: 1,
            style: context.typography.controlLabel.copyWith(
              fontFamily: FontFamily.twEmoji.value,
            ),
          ),
          SizedBox(width: layout.geometry(6)),
          Flexible(
            child: TooltipText(
              text: Text(
                localIpInfo.ip,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: context.typography.dashboardIpValue.copyWith(
                  color: textColor,
                ),
              ),
            ),
          ),
        ],
      );
    } else if (localIsLoading) {
      valueWidget = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RepaintBoundary(
            child: SizedBox(
              width: layout.geometry(12),
              height: layout.geometry(12),
              child: CommonCircleLoading(
                color: primaryColor,
                active: shouldAnimate,
              ),
            ),
          ),
          SizedBox(width: layout.geometry(6)),
          Text(
            context.appLocalizations.loading,
            maxLines: 1,
            style: context.typography.compactMetric.copyWith(
              color: secondaryTextColor,
            ),
          ),
        ],
      );
    } else if (hasChecked) {
      valueWidget = Text(
        'Timeout',
        maxLines: 1,
        style: context.typography.compactMetric.copyWith(color: dangerColor),
      );
    } else {
      valueWidget = const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      height: height,
      padding: EdgeInsets.symmetric(horizontal: layout.geometry(14)),
      decoration: BoxDecoration(
        color: fillColor,
        borderRadius: BorderRadius.circular(layout.geometry(22)),
      ),
      child: Row(
        children: [
          Icon(
            SurgeIcons.networkCheck,
            size: layout.geometry(16),
            color: primaryColor,
          ),
          SizedBox(width: layout.geometry(8)),
          Text(
            label,
            maxLines: 1,
            softWrap: false,
            style: context.typography.supporting.copyWith(
              color: secondaryTextColor,
            ),
          ),
          SizedBox(width: layout.geometry(12)),
          Flexible(
            child: Align(alignment: Alignment.centerRight, child: valueWidget),
          ),
        ],
      ),
    );
  }
}

class _TotalTrafficBadge extends StatelessWidget {
  const _TotalTrafficBadge({
    required this.up,
    required this.down,
    required this.upColor,
    required this.downColor,
    required this.layout,
  });

  final num up;
  final num down;
  final Color upColor;
  final Color downColor;
  final DashboardResponsiveLayout layout;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _TrafficAmount(
          icon: SurgeIcons.arrowUp,
          value: up,
          color: upColor,
          layout: layout,
        ),
        SizedBox(width: layout.geometry(12)),
        _TrafficAmount(
          icon: SurgeIcons.arrowDown,
          value: down,
          color: downColor,
          layout: layout,
        ),
      ],
    );
  }
}

class _TrafficAmount extends StatelessWidget {
  const _TrafficAmount({
    required this.icon,
    required this.value,
    required this.color,
    required this.layout,
  });

  final IconData icon;
  final num value;
  final Color color;
  final DashboardResponsiveLayout layout;

  @override
  Widget build(BuildContext context) {
    final formatted = value.traffic.show;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: layout.textIcon(14), color: color),
        SizedBox(width: layout.geometry(4)),
        Text(
          formatted,
          style: context.typography.metric.copyWith(color: color),
        ),
      ],
    );
  }
}

@visibleForTesting
class PlatformLatencyPanel extends StatelessWidget {
  const PlatformLatencyPanel({
    super.key,
    required this.targets,
    required this.results,
    required this.fallbackCountryCode,
    required this.activeColor,
    required this.fillColor,
    required this.textColor,
    required this.secondaryTextColor,
    required this.dangerColor,
    required this.latencyGood,
    required this.latencyMedium,
    required this.latencyBad,
    required this.onRetest,
    required this.shouldAnimatePending,
    required this.rowGap,
    required this.layout,
  });

  final List<NetworkDiagnosticTarget> targets;
  final Map<String, NetworkDiagnosticTargetState> results;
  final String? fallbackCountryCode;
  final Color activeColor;
  final Color fillColor;
  final Color textColor;
  final Color secondaryTextColor;
  final Color dangerColor;
  final Color latencyGood;
  final Color latencyMedium;
  final Color latencyBad;
  final VoidCallback onRetest;
  final bool shouldAnimatePending;
  final double rowGap;
  final DashboardResponsiveLayout layout;

  Color _flowColor(NetworkDiagnosticTargetState? result) {
    if (result == null || result.latencyMs == null) return activeColor;
    final latency = result.latencyMs;
    if (latency == null) return latencyBad;
    if (latency < 180) return latencyGood;
    if (latency < 420) return latencyMedium;
    return latencyBad;
  }

  Color _trackColor(NetworkDiagnosticTargetState? result) {
    final flow = _flowColor(result);
    return Color.lerp(flow, Colors.black, 0.76)!.withValues(alpha: 0.58);
  }

  double _barWidth(NetworkDiagnosticTargetState? result) {
    if (result == null || result.latencyMs == null) return 1;
    final latency = result.latencyMs;
    if (latency == null) return 1;
    return (latency / 640).clamp(0.08, 1).toDouble();
  }

  String _valueLabel(NetworkDiagnosticTargetState? result) {
    if (result?.latencyStatus == NetworkDiagnosticLatencyStatus.timeout) {
      return 'Timeout';
    }
    final latency = result?.latencyMs;
    return latency == null ? '-' : '${latency.toString().padLeft(3, '0')}ms';
  }

  Widget _value(BuildContext context, NetworkDiagnosticTargetState? result) {
    final timedOut =
        result?.latencyStatus == NetworkDiagnosticLatencyStatus.timeout;
    final hasLatency = result?.latencyMs != null;
    final color = timedOut
        ? dangerColor
        : hasLatency
        ? textColor
        : secondaryTextColor;
    final opacity = !timedOut && result?.refreshing == true
        ? (hasLatency ? 0.82 : 0.55)
        : 1.0;
    return Opacity(
      opacity: opacity,
      // Keep glyph edges away from the opacity layer's raster bounds, even
      // when a device font has taller ascenders/descenders. This is inside
      // the shared fit, so all labels retain the same scale and alignment.
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(
          _valueLabel(result),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.visible,
          style: _valueStyle(context).copyWith(color: color),
        ),
      ),
    );
  }

  TextStyle _valueStyle(BuildContext context) {
    // A font-size multiplier is not a reliable ascent/descent budget for
    // OEM or user-selected fonts. Use the actual font's vertical metrics.
    return context.typography.dashboardLatencyValue;
  }

  double _sharedValueWidth(BuildContext context) {
    var width = layout.geometry(50);
    final painter = TextPainter(
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
      maxLines: 1,
    );
    var style = DefaultTextStyle.of(context).style.merge(_valueStyle(context));
    style = context.resolveBoldText(style);
    for (final target in targets) {
      painter.text = TextSpan(
        text: _valueLabel(results[target.name]),
        style: style,
      );
      painter.layout();
      // Leave a little room for glyph edges and fractional pixel rounding.
      width = math.max(width, painter.width.ceilToDouble() + 2);
    }
    painter.dispose();
    return width;
  }

  @override
  Widget build(BuildContext context) {
    final valueWidth = _sharedValueWidth(context);
    return Column(
      children: [
        for (final target in targets) ...[
          // Do not show fallback country code in pending state;
          // only use the resolved countryCode from a completed probe.
          _PlatformLatencyRow(
            target: target,
            countryCode: results[target.name]?.countryCode,
            trackColor: _trackColor(results[target.name]),
            flowColor: _flowColor(results[target.name]),
            barWidthFactor: _barWidth(results[target.name]),
            textColor: textColor,
            secondaryTextColor: secondaryTextColor,
            trailing: SizedBox(
              // Every row fits the same natural width into the same column,
              // so a long value scales all three labels by the same amount.
              width: valueWidth,
              child: Align(
                alignment: Alignment.centerRight,
                child: _value(context, results[target.name]),
              ),
            ),
            onRetest: onRetest,
            active:
                shouldAnimatePending &&
                (results[target.name]?.refreshing ?? false),
            dimmed: results[target.name]?.refreshing == true,
            layout: layout,
          ),
          if (target != targets.last) SizedBox(height: rowGap),
        ],
      ],
    );
  }
}

class _PlatformLatencyRow extends StatelessWidget {
  const _PlatformLatencyRow({
    required this.target,
    required this.countryCode,
    required this.trackColor,
    required this.flowColor,
    required this.barWidthFactor,
    required this.textColor,
    required this.secondaryTextColor,
    required this.trailing,
    required this.onRetest,
    this.active = false,
    this.dimmed = false,
    required this.layout,
  });

  final NetworkDiagnosticTarget target;
  final String? countryCode;
  final Color trackColor;
  final Color flowColor;
  final double barWidthFactor;
  final Color textColor;
  final Color secondaryTextColor;
  final Widget trailing;
  final VoidCallback onRetest;
  final bool active;
  final bool dimmed;
  final DashboardResponsiveLayout layout;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _PlatformBrandIcon(target: target, layout: layout),
        SizedBox(width: layout.geometry(6)),
        Opacity(
          opacity: dimmed ? 0.82 : 1,
          child: _RouteFlagBadge(countryCode: countryCode, layout: layout),
        ),
        SizedBox(width: layout.geometry(8)),
        Expanded(
          child: SurgePressable(
            compact: true,
            behavior: HitTestBehavior.opaque,
            onTap: onRetest,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: layout.legacy(8)),
              child: _FlowingLatencyBar(
                widthFactor: barWidthFactor,
                trackColor: trackColor,
                flowColor: flowColor,
                layout: layout,
                active: active,
              ),
            ),
          ),
        ),
        SizedBox(width: layout.geometry(8)),
        SizedBox(
          width: layout.geometry(50),
          // Geometry shrinks on narrow phones independently of system fonts.
          // Lay out the complete value before fitting it, including long
          // latencies and Timeout, rather than clipping a constrained Text.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: trailing,
          ),
        ),
      ],
    );
  }
}

class _PlatformBrandIcon extends StatelessWidget {
  const _PlatformBrandIcon({required this.target, required this.layout});

  final NetworkDiagnosticTarget target;
  final DashboardResponsiveLayout layout;

  @override
  Widget build(BuildContext context) {
    final name = target.name.toLowerCase();
    if (name == 'youtube') {
      return _BrandImageIcon(
        tooltip: target.name,
        assetPath: 'assets/images/icon/latency_youtube.png',
        layout: layout,
      );
    }
    if (name == 'chatgpt') {
      return _BrandImageIcon(
        tooltip: target.name,
        assetPath: 'assets/images/icon/latency_chatgpt.png',
        tintInDarkMode: true,
        layout: layout,
      );
    }
    return _BrandImageIcon(
      tooltip: target.name,
      assetPath: 'assets/images/icon/latency_github.png',
      tintInDarkMode: true,
      layout: layout,
    );
  }
}

class _BrandImageIcon extends StatelessWidget {
  const _BrandImageIcon({
    required this.tooltip,
    required this.assetPath,
    this.tintInDarkMode = false,
    required this.layout,
  });

  final String tooltip;
  final String assetPath;
  final bool tintInDarkMode;
  final DashboardResponsiveLayout layout;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tintColor = tintInDarkMode && isDark
        ? SurgeTheme.of(context).textPrimary
        : null;
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: layout.legacy(25),
        height: layout.legacy(25),
        child: Image.asset(
          assetPath,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
          color: tintColor,
          colorBlendMode: tintColor == null ? null : BlendMode.srcIn,
        ),
      ),
    );
  }
}

class _RouteFlagBadge extends StatelessWidget {
  const _RouteFlagBadge({required this.countryCode, required this.layout});

  final String? countryCode;
  final DashboardResponsiveLayout layout;

  String _countryCodeToEmoji(String code) {
    final c = code.toUpperCase();
    if (c.length != 2) return '';
    final firstLetter = c.codeUnitAt(0) - 0x41 + 0x1F1E6;
    final secondLetter = c.codeUnitAt(1) - 0x41 + 0x1F1E6;
    return String.fromCharCode(firstLetter) + String.fromCharCode(secondLetter);
  }

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    final flag = countryCode?.length == 2
        ? _countryCodeToEmoji(countryCode!)
        : null;
    return SizedBox(
      width: layout.legacy(20),
      height: layout.legacy(20),
      child: flag == null || flag.isEmpty
          ? Center(
              child: Icon(
                SurgeIcons.network,
                size: layout.geometry(13),
                color: surge.textSecondary,
              ),
            )
          : Center(
              child: Text(
                flag,
                maxLines: 1,
                style: context.typography.controlLabel.copyWith(
                  fontFamily: 'Twemoji',
                ),
              ),
            ),
    );
  }
}

class _FlowingLatencyBar extends StatefulWidget {
  const _FlowingLatencyBar({
    required this.widthFactor,
    required this.trackColor,
    required this.flowColor,
    required this.layout,
    this.active = false,
  });

  final double widthFactor;
  final Color trackColor;
  final Color flowColor;
  final DashboardResponsiveLayout layout;
  final bool active;

  @override
  State<_FlowingLatencyBar> createState() => _FlowingLatencyBarState();
}

class _FlowingLatencyBarState extends State<_FlowingLatencyBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: SurgeMotion.latencyFlow,
    );
    if (widget.active) {
      _controller.repeat();
    }
    if (NavigationTrace.enabled) {
      NavigationTrace.networkLatencyBarRepeating = _controller.isAnimating;
    }
  }

  @override
  void didUpdateWidget(covariant _FlowingLatencyBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
    }
    if (NavigationTrace.enabled) {
      NavigationTrace.networkLatencyBarRepeating = _controller.isAnimating;
    }
  }

  @override
  void dispose() {
    if (NavigationTrace.enabled) {
      NavigationTrace.networkLatencyBarRepeating = false;
    }
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(surge.radii.chart),
        child: SizedBox(
          height: widget.layout.legacy(8),
          child: Stack(
            children: [
              Positioned.fill(child: ColoredBox(color: widget.trackColor)),
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: widget.widthFactor,
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) {
                    final sweep = _controller.value;
                    return DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment(-1.8 + 3.6 * sweep, 0),
                          end: Alignment(-0.2 + 3.6 * sweep, 0),
                          colors: [
                            widget.flowColor.withValues(alpha: 0.70),
                            widget.flowColor,
                            widget.flowColor.withValues(alpha: 0.74),
                          ],
                          stops: const [0, 0.48, 1],
                        ),
                      ),
                      child: const SizedBox.expand(),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
