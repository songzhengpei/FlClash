import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/views/dashboard/dashboard_layout.dart';
import 'package:fl_clash/views/proxies/common.dart' as proxy_common;
import 'package:fl_clash/widgets/surge/surge.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _heroFillDuration = SurgeMotion.heroFill;
const _statusLightPulseDuration = SurgeMotion.statusLightPulse;

bool heroOutboundFillActive({
  required bool isStart,
  required bool isSmartStopped,
}) {
  return isStart || isSmartStopped;
}

/// Smart pause shares the flatter dynamic-color treatment so its warm state
/// does not gain an extra static-theme gradient.
bool heroUsesDynamicSurfaceTreatment({
  required bool dynamicColor,
  required bool isSmartPaused,
}) {
  return dynamicColor || isSmartPaused;
}

/// True only when the active-fill color actually changed. First mount with
/// begin == end is a visual no-op and must not start the 1500ms ticker.
bool heroActiveFillShouldAnimate({
  required Color? previous,
  required Color next,
}) {
  return previous != null && previous != next;
}

/// Status-light pulse / connecting chrome. PAUSED must not pulse even if
/// Core is attaching or a leftover connecting timer is still true.
bool heroConnectingPulseActive({
  required bool isSmartStopped,
  required CoreStatus coreStatus,
  required bool showConnecting,
}) {
  return !isSmartStopped &&
      (coreStatus == CoreStatus.connecting || showConnecting);
}

class SurgeDashboardHero extends ConsumerStatefulWidget {
  const SurgeDashboardHero({
    super.key,
    required this.layout,
    this.allocatedHeight,
  });

  final DashboardResponsiveLayout layout;
  final double? allocatedHeight;

  @override
  ConsumerState<SurgeDashboardHero> createState() => _SurgeDashboardHeroState();
}

class _SurgeDashboardHeroState extends ConsumerState<SurgeDashboardHero>
    with TickerProviderStateMixin {
  Timer? _failureTimer;
  Timer? _connectingTimer;
  bool _showFailure = false;
  bool _showConnecting = false;
  String? _transitionKind;
  late final AnimationController _fillController;
  late final AnimationController _sheenController;
  late final Animation<double> _fillAnimation;

  @override
  void initState() {
    super.initState();
    final isStart = ref.read(isStartProvider);
    final isSmartStopped = ref.read(isSmartStoppedProvider);
    _fillController = AnimationController(
      vsync: this,
      duration: _heroFillDuration,
      value:
          heroOutboundFillActive(
            isStart: isStart,
            isSmartStopped: isSmartStopped,
          )
          ? 1
          : 0,
    );
    _fillAnimation = CurvedAnimation(
      parent: _fillController,
      curve: Curves.easeInOutCubic,
      reverseCurve: Curves.easeInOutCubic,
    );
    _sheenController = AnimationController(
      vsync: this,
      duration: SurgeMotion.heroSheen,
    );
  }

  @override
  void dispose() {
    if (NavigationTrace.enabled) {
      NavigationTrace.dashboardHeroMounted = false;
      NavigationTrace.dashboardSheenRepeating = false;
    }
    _failureTimer?.cancel();
    _connectingTimer?.cancel();
    _fillController.dispose();
    _sheenController.dispose();
    super.dispose();
  }

  String _modeLabel(Mode mode) {
    return switch (mode) {
      Mode.rule => 'Rule',
      Mode.global => 'Global',
      Mode.direct => 'Direct',
    };
  }

  void _handleSwitchStart(WidgetRef ref) {
    final nextIsStart = !ref.read(isStartProvider);
    final kind = nextIsStart ? 'start' : 'stop';
    if (mounted) {
      setState(() => _transitionKind = kind);
      _sheenController.repeat();
    }
    if (nextIsStart) {
      _startConnectingAnimation();
      _fillController.forward();
    } else {
      _fillController.reverse();
    }
    unawaited(() async {
      try {
        // Register intent immediately. SetupAction owns the attachment wait,
        // so a later Stop can invalidate this tap while startup is pending.
        await globalState.container
            .read(setupActionProvider.notifier)
            .updateStatus(nextIsStart);
      } finally {
        if (mounted) {
          setState(() => _transitionKind = null);
          _sheenController.stop();
        }
      }
    }());
  }

  void _handleChangeMode(Mode mode, WidgetRef ref) {
    ref.read(setupActionProvider.notifier).changeMode(mode);
  }

  void _syncOutboundFill({
    required bool isStart,
    required bool isSmartStopped,
  }) {
    if (heroOutboundFillActive(
      isStart: isStart,
      isSmartStopped: isSmartStopped,
    )) {
      _fillController.forward();
    } else {
      _fillController.reverse();
    }
  }

  void _startConnectingAnimation() {
    _connectingTimer?.cancel();
    if (mounted) {
      setState(() => _showConnecting = true);
    }
    _connectingTimer = Timer(_heroFillDuration, () {
      if (mounted) {
        setState(() => _showConnecting = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (NavigationTrace.enabled) {
      NavigationTrace.noteHotspotBuild('dashboard_hero');
      NavigationTrace.dashboardHeroMounted = true;
      NavigationTrace.dashboardSheenRepeating = _sheenController.isAnimating;
    }
    final surge =
        Theme.of(context).extension<SurgeTheme>() ?? SurgeTheme.light();
    final appLocalizations = context.appLocalizations;
    final isStart = ref.watch(isStartProvider);
    final isSmartResuming = ref.watch(isSmartResumingProvider);
    final isSmartStopped = ref.watch(isSmartStoppedProvider);
    final isSmartPaused = isSmartStopped && !isStart;
    final mode = ref.watch(
      patchClashConfigProvider.select((state) => state.mode),
    );
    final coreStatus = ref.watch(coreStatusProvider);
    final connecting = heroConnectingPulseActive(
      isSmartStopped: isSmartStopped,
      coreStatus: coreStatus,
      showConnecting: _showConnecting,
    );
    final transitionStart = _transitionKind == 'start';
    final transitionStop = _transitionKind == 'stop';
    final transitionPausing = _transitionKind == 'pausing';
    final buttonLabel = transitionPausing
        ? appLocalizations.pausing
        : isSmartResuming
        ? appLocalizations.resuming
        : transitionStop
        ? appLocalizations.stopping
        : (transitionStart || connecting)
        ? appLocalizations.starting
        : isSmartPaused
        ? appLocalizations.resume
        : isStart
        ? appLocalizations.stop
        : appLocalizations.start;
    final buttonLoading =
        transitionPausing ||
        isSmartResuming ||
        transitionStart ||
        transitionStop ||
        connecting;
    final dynamicColor = ref.watch(
      themeSettingProvider.select((state) => state.dynamicColor),
    );
    final currentProfile = ref.watch(currentProfileProvider);
    final profileLabel =
        currentProfile?.realLabel.takeFirstValid(['SlClash']) ?? 'SlClash';
    final statusLabel = isSmartPaused
        ? appLocalizations.smartStopped
        : isStart
        ? appLocalizations.connected
        : appLocalizations.disconnected;
    ref.listen(isStartProvider, (previous, next) {
      final smartStopped = ref.read(isSmartStoppedProvider);
      _syncOutboundFill(isStart: next, isSmartStopped: smartStopped);
      // Visible providers can publish an intermediate RUNNING/PAUSED snapshot
      // before updateStatus has finished reconciling the native transition.
      // Keep the action disabled until _handleSwitchStart's Future completes;
      // otherwise the button can change meaning underneath a rapid second tap.
    });

    ref.listen(isSmartStoppedProvider, (previous, next) {
      _syncOutboundFill(
        isStart: ref.read(isStartProvider),
        isSmartStopped: next,
      );
      // Auto smart-stop triggered during start transition → "暂停中"
      if (next && previous == false && _transitionKind == 'start') {
        _sheenController.repeat();
        if (mounted) setState(() => _transitionKind = 'pausing');
      }
    });

    ref.listen(coreStatusProvider, (previous, next) {
      final isFailedStart =
          previous == CoreStatus.connecting && next == CoreStatus.disconnected;
      if (next == CoreStatus.disconnected &&
          !ref.read(isSmartStoppedProvider)) {
        _fillController.reverse();
      }
      if (next != CoreStatus.disconnected || !isFailedStart) {
        _failureTimer?.cancel();
        if (_showFailure && mounted) {
          setState(() => _showFailure = false);
        }
        return;
      }
      _failureTimer?.cancel();
      if (mounted) {
        setState(() => _showFailure = true);
      }
      _failureTimer = Timer(const Duration(seconds: 15), () {
        if (mounted) {
          setState(() => _showFailure = false);
        }
      });
    });

    final layout = widget.layout;
    final subscriptionSelector = _SubscriptionSelectorBar(
      profileLabel: profileLabel,
      currentProfileId: currentProfile?.id,
      coreStatus: coreStatus,
      isStart: isStart,
      isSmartPaused: isSmartPaused,
      showConnecting: _showConnecting,
      showFailure: _showFailure,
      layout: layout,
    );
    final actionButton = _HeroActionButton(
      layout: layout,
      isStart: isStart,
      isSmartPaused: isSmartPaused,
      isSmartResuming: isSmartResuming,
      loading: buttonLoading,
      label: buttonLabel,
      sheenController: _sheenController,
      onPressed: buttonLoading
          ? null
          : () {
              if (isSmartPaused) {
                ref.read(smartAutoStopManagerProvider.notifier).resumeNow();
              } else {
                _handleSwitchStart(ref);
              }
            },
    );
    final contentLayout = DashboardHeroLayoutCalculator.layoutFor(
      responsiveLayout: layout,
      availableOuterHeight: widget.allocatedHeight ?? layout.heroNaturalHeight,
    );

    return Container(
      width: double.infinity,
      constraints: widget.allocatedHeight == null
          ? null
          : BoxConstraints(minHeight: widget.allocatedHeight!),
      padding: EdgeInsets.fromLTRB(
        layout.cardHorizontalPadding,
        layout.legacy(18),
        layout.cardHorizontalPadding,
        layout.legacy(18),
      ),
      decoration: BoxDecoration(
        color: surge.card,
        borderRadius: BorderRadius.circular(layout.cardRadius),
        border: Border.all(
          color: surge.separator,
          width: surge.spacing.hairline,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (layout.requiresReflow)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                subscriptionSelector,
                SizedBox(height: layout.legacy(8)),
                Align(alignment: Alignment.centerRight, child: actionButton),
              ],
            )
          else
            Row(
              children: [
                Expanded(child: subscriptionSelector),
                SizedBox(width: layout.geometry(12)),
                actionButton,
              ],
            ),
          SizedBox(height: contentLayout.topRowToModeGap),
          AnimatedBuilder(
            animation: _fillAnimation,
            builder: (context, _) {
              return _HeroModeCard(
                fillProgress: _fillAnimation.value,
                modeLabel: '${_modeLabel(mode)} Mode',
                title: appLocalizations.outboundTraffic,
                active: isStart,
                isSmartPaused: isSmartPaused,
                dynamicColor: dynamicColor,
                connecting: connecting,
                failed: _showFailure,
                statusLabel: statusLabel,
                height: contentLayout.modeCardHeight,
                layout: layout,
              );
            },
          ),
          SizedBox(height: contentLayout.modeToSwitchGap),
          _ModeSwitch(
            value: mode,
            onChanged: (value) => _handleChangeMode(value, ref),
            layout: layout,
          ),
          SizedBox(height: contentLayout.switchToSelectorGap),
          _HeroProxySelectorBar(layout: layout),
        ],
      ),
    );
  }
}

class _HeroModeCard extends StatelessWidget {
  const _HeroModeCard({
    required this.fillProgress,
    required this.title,
    required this.modeLabel,
    required this.active,
    required this.isSmartPaused,
    required this.dynamicColor,
    required this.connecting,
    required this.failed,
    required this.statusLabel,
    required this.height,
    required this.layout,
  });

  final double fillProgress;
  final String title;
  final String modeLabel;
  final bool active;
  final bool isSmartPaused;
  final bool dynamicColor;
  final bool connecting;
  final bool failed;
  final String statusLabel;
  final double height;
  final DashboardResponsiveLayout layout;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(layout.geometry(24)),
      child: _HeroModeCardSurface(
        title: title,
        modeLabel: modeLabel,
        active: active,
        isSmartPaused: isSmartPaused,
        dynamicColor: dynamicColor,
        connecting: connecting,
        failed: failed,
        statusLabel: statusLabel,
        fillProgress: fillProgress.clamp(0.0, 1.0),
        height: height,
        layout: layout,
      ),
    );
  }
}

class _HeroModeCardSurface extends StatelessWidget {
  const _HeroModeCardSurface({
    required this.title,
    required this.modeLabel,
    required this.active,
    required this.isSmartPaused,
    required this.dynamicColor,
    required this.connecting,
    required this.failed,
    required this.statusLabel,
    required this.fillProgress,
    required this.height,
    required this.layout,
  });

  final String title;
  final String modeLabel;
  final bool active;
  final bool isSmartPaused;
  final bool dynamicColor;
  final bool connecting;
  final bool failed;
  final String statusLabel;
  final double fillProgress;
  final double height;
  final DashboardResponsiveLayout layout;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    final progress = fillProgress.clamp(0.0, 1.0);
    final useDynamicSurface = heroUsesDynamicSurfaceTreatment(
      dynamicColor: dynamicColor,
      isSmartPaused: isSmartPaused,
    );
    final activeFill = isSmartPaused
        ? surge.semantic.paused
        : surge.semantic.dashboardDynamicActive;
    const foregroundColor = Colors.white;
    final secondaryAlpha = lerpDouble(
      0.82,
      useDynamicSurface ? 0.92 : 0.82,
      progress,
    );
    final secondaryColor = foregroundColor.withValues(alpha: secondaryAlpha);
    final onBlue = progress > 0.5;

    return HeroActiveFill(
      activeFill: activeFill,
      builder: (context, animatedActiveFill, child) {
        final fillColor = Color.lerp(
          surge.semantic.dashboardInactive,
          animatedActiveFill,
          progress,
        )!;
        return Container(
          width: double.infinity,
          constraints: BoxConstraints(minHeight: height),
          height: layout.requiresReflow ? null : height,
          padding: EdgeInsets.symmetric(
            horizontal: layout.geometry(18),
            vertical: layout.legacy(10),
          ),
          decoration: BoxDecoration(
            color: fillColor,
            gradient: !useDynamicSurface && progress > 0.001
                ? LinearGradient(
                    colors: [
                      fillColor,
                      Color.lerp(fillColor, Colors.black, 0.16)!,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : null,
          ),
          child: child,
        );
      },
      child: Builder(
        builder: (context) {
          final routeIcon = Container(
            width: layout.geometry(38),
            height: layout.geometry(38),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(layout.geometry(16)),
            ),
            child: Icon(
              SurgeIcons.outboundMode,
              color: Colors.white,
              size: layout.geometry(21),
            ),
          );
          final labels = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.typography.cardTitle.copyWith(
                  color: foregroundColor,
                ),
              ),
              SizedBox(height: layout.geometry(4)),
              Text(
                modeLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.typography.supporting.copyWith(
                  color: secondaryColor,
                ),
              ),
            ],
          );
          final status = _StatusPill(
            active: active,
            isSmartPaused: isSmartPaused,
            connecting: connecting,
            failed: failed,
            label: statusLabel,
            dynamicColor: useDynamicSurface,
            onBlue: onBlue,
            layout: layout,
          );
          if (layout.requiresReflow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    routeIcon,
                    SizedBox(width: layout.geometry(12)),
                    Expanded(child: labels),
                  ],
                ),
                SizedBox(height: layout.geometry(8)),
                Align(alignment: Alignment.centerRight, child: status),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              routeIcon,
              SizedBox(width: layout.geometry(12)),
              Expanded(child: labels),
              SizedBox(width: layout.geometry(10)),
              status,
            ],
          );
        },
      ),
    );
  }
}

class HeroActiveFill extends StatefulWidget {
  const HeroActiveFill({
    super.key,
    required this.activeFill,
    required this.builder,
    required this.child,
  });

  final Color activeFill;
  final Widget Function(BuildContext context, Color fill, Widget? child)
  builder;
  final Widget child;

  @override
  State<HeroActiveFill> createState() => HeroActiveFillState();
}

class HeroActiveFillState extends State<HeroActiveFill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _curve;
  ColorTween? _tween;
  late Color _displayed;

  /// True only while a real activeFill color transition is ticking.
  @visibleForTesting
  bool get debugIsAnimating => _controller.isAnimating;

  @override
  void initState() {
    super.initState();
    _displayed = widget.activeFill;
    _controller = AnimationController(vsync: this, duration: _heroFillDuration);
    _curve = CurvedAnimation(parent: _controller, curve: Curves.easeInOutCubic);
    _controller.addStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) {
      return;
    }
    _displayed = widget.activeFill;
    _tween = null;
    if (mounted) {
      setState(() {});
    }
  }

  Color _currentVisualColor() {
    final tween = _tween;
    if (tween == null || !_controller.isAnimating) {
      return _displayed;
    }
    return tween.evaluate(_curve) ?? _displayed;
  }

  @override
  void didUpdateWidget(covariant HeroActiveFill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!heroActiveFillShouldAnimate(
      previous: oldWidget.activeFill,
      next: widget.activeFill,
    )) {
      return;
    }
    final from = _currentVisualColor();
    _displayed = from;
    _tween = ColorTween(begin: from, end: widget.activeFill);
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_onStatus);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tween = _tween;
    if (tween == null || !_controller.isAnimating) {
      return widget.builder(context, widget.activeFill, widget.child);
    }
    return AnimatedBuilder(
      animation: _curve,
      builder: (context, child) {
        return widget.builder(
          context,
          tween.evaluate(_curve) ?? widget.activeFill,
          child,
        );
      },
      child: widget.child,
    );
  }
}

class _HeroActionButton extends StatelessWidget {
  const _HeroActionButton({
    required this.isStart,
    required this.isSmartPaused,
    required this.isSmartResuming,
    required this.loading,
    required this.label,
    required this.sheenController,
    required this.onPressed,
    required this.layout,
  });

  final bool isStart;
  final bool isSmartPaused;
  final bool isSmartResuming;
  final bool loading;
  final String label;
  final AnimationController sheenController;
  final VoidCallback? onPressed;
  final DashboardResponsiveLayout layout;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    final Color baseColor;
    if (isSmartPaused ||
        isSmartResuming ||
        label == context.appLocalizations.pausing) {
      baseColor = surge.semantic.state.heroPause;
    } else if ((isStart && !loading) ||
        label == context.appLocalizations.stopping) {
      baseColor = surge.semantic.state.heroStop;
    } else {
      baseColor = surge.semantic.state.heroStart;
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [baseColor, Color.lerp(baseColor, Colors.black, 0.16)!],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(layout.geometry(18)),
        boxShadow: [
          BoxShadow(
            color: baseColor.withValues(alpha: 0.2),
            blurRadius: layout.geometry(14),
            offset: Offset(0, layout.geometry(6)),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(layout.geometry(18)),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: layout.geometry(74),
              minHeight: layout.legacy(28),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: layout.geometry(12),
                vertical: layout.legacy(4),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Shimmer layer — only visible when loading
                  if (loading)
                    Positioned.fill(
                      child: _ActionButtonSheen(controller: sheenController),
                    ),
                  // Text label
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: context.typography.controlLabel.copyWith(
                          color: surge.semantic.state.onHeroAction,
                        ),
                      ),
                      // Animated dots during loading
                      if (loading) ...[
                        const SizedBox(width: 2),
                        _LoadingDots(controller: sheenController),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Sliding sheen gradient that sweeps across the button during loading.
class _ActionButtonSheen extends StatelessWidget {
  const _ActionButtonSheen({required this.controller});

  final AnimationController controller;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(surge.radii.card),
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, child) {
          return FractionalTranslation(
            translation: Offset(-1.4 + controller.value * 2.8, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: 52,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.white.withValues(alpha: 0),
                      Colors.white.withValues(alpha: 0.18),
                      Colors.white.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Three subtle dots that pulse during loading.
class _LoadingDots extends StatelessWidget {
  const _LoadingDots({required this.controller});

  final AnimationController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final t = controller.value;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Dot(opacity: _dotOpacity(t, 0)),
            _Dot(opacity: _dotOpacity(t, 1)),
            _Dot(opacity: _dotOpacity(t, 2)),
          ],
        );
      },
    );
  }

  double _dotOpacity(double t, int index) {
    final phase = (t + index / 3) % 1;
    return phase < 0.5 ? phase * 2 : (1 - phase) * 2;
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.opacity});

  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 3,
      height: 3,
      margin: const EdgeInsets.symmetric(horizontal: 1.5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: opacity.clamp(0.0, 1.0)),
        shape: BoxShape.circle,
      ),
    );
  }
}

class _SubscriptionSelectorBar extends ConsumerWidget {
  const _SubscriptionSelectorBar({
    required this.profileLabel,
    required this.currentProfileId,
    required this.coreStatus,
    required this.isStart,
    required this.isSmartPaused,
    required this.showConnecting,
    required this.showFailure,
    required this.layout,
  });

  final String profileLabel;
  final int? currentProfileId;
  final CoreStatus coreStatus;
  final bool isStart;
  final bool isSmartPaused;
  final bool showConnecting;
  final bool showFailure;
  final DashboardResponsiveLayout layout;

  Color _statusColor(SurgeTheme surge) {
    if (showFailure) return surge.red;
    if (isSmartPaused) return surge.orange;
    if (coreStatus == CoreStatus.connecting || showConnecting || isStart) {
      return surge.semantic.connected;
    }
    return surge.textSecondary.withValues(alpha: 0.48);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final surge = SurgeTheme.of(context);
    final profiles = ref.watch(profilesProvider);
    final statusColor = _statusColor(surge);

    return SurgePressable(
      onTap: () => _showSubscriptionSelectorSheet(
        context,
        ref,
        profiles,
        currentProfileId,
      ),
      behavior: HitTestBehavior.opaque,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              profileLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.typography.screenTitle.copyWith(
                color: surge.textPrimary,
              ),
            ),
          ),
          SizedBox(width: layout.geometry(4)),
          AnimatedContainer(
            duration: SurgeMotion.reveal,
            child: Icon(
              SurgeIcons.expand,
              size: layout.legacy(18),
              color: statusColor,
            ),
          ),
        ],
      ),
    );
  }

  void _showSubscriptionSelectorSheet(
    BuildContext context,
    WidgetRef ref,
    List<Profile> profiles,
    int? currentProfileId,
  ) {
    showSheet(
      context: context,
      props: const SheetProps(isScrollControlled: false),
      builder: (sheetContext) {
        final surge = SurgeTheme.of(sheetContext);
        return AdaptiveSheetScaffold(
          title: context.appLocalizations.selectProfile,
          appBarActions: const [],
          body: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            itemCount: profiles.length,
            itemBuilder: (context, index) {
              final profile = profiles[index];
              final isSelected = profile.id == currentProfileId;
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: SurgeSelectableRow(
                  selected: isSelected,
                  onTap: () {
                    ref
                        .read(proxiesActionProvider.notifier)
                        .beginRuntimeProfileTransition(profile.id);
                    ref.read(currentProfileIdProvider.notifier).value =
                        profile.id;
                    Navigator.of(context).pop();
                  },
                  presentation: SurgeSelectionPresentation.menu,
                  showBorder: true,
                  radius: surge.radii.menuRow,
                  selectedSurfaceColor: surge.selectedFill,
                  unselectedSurfaceColor: surge.fill,
                  selectedBorderColor: surge.primary.withValues(alpha: 0.48),
                  unselectedBorderColor: surge.separator,
                  selectedBorderWidth: 1,
                  unselectedBorderWidth: surge.spacing.hairline,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        if (isSelected) ...[
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: surge.semantic.connected,
                              shape: BoxShape.circle,
                            ),
                            margin: const EdgeInsets.only(right: 8),
                          ),
                        ],
                        Expanded(
                          child: Text(
                            profile.realLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.typography.sheetRowTitle.copyWith(
                              color: surge.textPrimary,
                            ),
                          ),
                        ),
                        Text(
                          profile.type == ProfileType.url
                              ? 'URL'
                              : context.appLocalizations.local,
                          style: context.typography.sheetLabel.copyWith(
                            color: surge.textSecondary,
                          ),
                        ),
                        if (isSelected) ...[
                          const SizedBox(width: 8),
                          Icon(
                            SurgeIcons.success,
                            size: 18,
                            color: surge.primary,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.active,
    required this.isSmartPaused,
    required this.connecting,
    required this.failed,
    required this.label,
    required this.dynamicColor,
    required this.onBlue,
    required this.layout,
  });

  final bool active;
  final bool isSmartPaused;
  final bool connecting;
  final bool failed;
  final String label;
  final bool dynamicColor;
  final bool onBlue;
  final DashboardResponsiveLayout layout;

  @override
  Widget build(BuildContext context) {
    final pillAlpha = onBlue && dynamicColor ? 0.24 : 0.18;
    final background = Colors.white.withValues(alpha: pillAlpha);
    final borderColor = onBlue
        ? Colors.white.withValues(alpha: dynamicColor ? 0.28 : 0.16)
        : Colors.white.withValues(alpha: 0.18);
    const textColor = Colors.white;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: layout.geometry(12),
        vertical: layout.legacy(9),
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(layout.geometry(20)),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PillStatusLight(
            active: active,
            isSmartPaused: isSmartPaused,
            connecting: connecting,
            failed: failed,
            onBlue: onBlue,
            size: layout.geometry(8),
          ),
          SizedBox(width: layout.geometry(7)),
          Text(
            label,
            maxLines: 1,
            softWrap: false,
            style: context.typography.badgeLabel.copyWith(color: textColor),
          ),
        ],
      ),
    );
  }
}

class _PillStatusLight extends StatefulWidget {
  const _PillStatusLight({
    required this.active,
    required this.isSmartPaused,
    required this.connecting,
    required this.failed,
    required this.onBlue,
    required this.size,
  });

  final bool active;
  final bool isSmartPaused;
  final bool connecting;
  final bool failed;
  final bool onBlue;
  final double size;

  @override
  State<_PillStatusLight> createState() => _PillStatusLightState();
}

class _PillStatusLightState extends State<_PillStatusLight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: _statusLightPulseDuration,
      lowerBound: 0.35,
      upperBound: 1,
    );
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _PillStatusLight oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _syncAnimation() {
    if (widget.connecting) {
      if (!_controller.isAnimating) {
        _controller.repeat(reverse: true);
      }
    } else {
      _controller.stop();
      _controller.value = 1;
    }
  }

  Color _color(SurgeTheme surge) {
    if (widget.failed) return surge.semantic.statusLightError;
    if (widget.isSmartPaused) return surge.semantic.statusLightPaused;
    if (widget.connecting || widget.active) {
      return surge.semantic.statusLightActive;
    }
    return widget.onBlue
        ? Colors.white.withValues(alpha: 0.75)
        : Colors.white.withValues(alpha: 0.72);
  }

  @override
  Widget build(BuildContext context) {
    if (NavigationTrace.enabled) {
      NavigationTrace.dashboardPulseRepeating = _controller.isAnimating;
    }
    final surge = SurgeTheme.of(context);
    final color = _color(surge);

    return FadeTransition(
      opacity: _opacity,
      child: AnimatedContainer(
        duration: SurgeMotion.reveal,
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: color.withValues(
                alpha:
                    !widget.active &&
                        !widget.connecting &&
                        !widget.failed &&
                        !widget.isSmartPaused
                    ? 0
                    : 0.32,
              ),
              blurRadius: 8,
              spreadRadius: 1,
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({
    required this.value,
    required this.onChanged,
    required this.layout,
  });

  final Mode value;
  final ValueChanged<Mode> onChanged;
  final DashboardResponsiveLayout layout;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    return SurgeSlidingSegmentedControl<Mode>(
      value: value,
      onChanged: onChanged,
      items: [
        SurgeSegmentedItem(
          value: Mode.rule,
          label: context.appLocalizations.rule,
        ),
        SurgeSegmentedItem(
          value: Mode.direct,
          label: context.appLocalizations.direct,
        ),
        SurgeSegmentedItem(
          value: Mode.global,
          label: context.appLocalizations.global,
        ),
      ],
      height: layout.legacy(34),
      padding: EdgeInsets.all(layout.legacy(3)),
      backgroundColor: surge.fill,
      selectedSurfaceColor: surge.elevatedCard,
      selectedColor: surge.textPrimary,
      unselectedColor: surge.textSecondary,
      outerRadius: layout.geometry(26),
      selectedRadius: layout.geometry(24),
      labelStyle: context.typography.modeTabLabel,
      selectedLabelStyle: context.typography.selectedModeTabLabel,
      indicatorDuration: SurgeMotion.container,
      textDuration: SurgeMotion.state,
    );
  }
}

class _HeroProxySelectorBar extends ConsumerWidget {
  const _HeroProxySelectorBar({required this.layout});

  final DashboardResponsiveLayout layout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(currentGroupsStateProvider).value;
    final currentGroupName = ref.watch(
      currentProfileProvider.select((state) => state?.currentGroupName ?? ''),
    );
    final selectedGroupName =
        currentGroupName.isNotEmpty &&
            groups.any((g) => g.name == currentGroupName)
        ? currentGroupName
        : (groups.isNotEmpty ? groups.first.name : '');

    final selectedProxyName = selectedGroupName.isNotEmpty
        ? ref.watch(selectedProxyNameProvider(selectedGroupName))
        : null;

    return SurgeDualSelectBar(
      firstLabel: selectedGroupName.isEmpty ? '-' : selectedGroupName,
      secondLabel: selectedProxyName == null || selectedProxyName.isEmpty
          ? '-'
          : selectedProxyName,
      onFirstTap: () =>
          _showGroupSelectorSheet(context, ref, groups, selectedGroupName),
      onSecondTap: selectedGroupName.isNotEmpty
          ? () => _showNodeSelectorSheet(
              context,
              ref,
              selectedGroupName,
              selectedProxyName ?? '',
            )
          : null,
      height: layout.legacy(34),
      padding: EdgeInsets.symmetric(horizontal: layout.geometry(14)),
      radius: layout.geometry(22),
      itemRadius: layout.geometry(18),
      dividerHeight: layout.geometry(16),
      dividerMargin: layout.geometry(10),
      iconSize: layout.geometry(16),
      labelGap: layout.geometry(2),
      itemVerticalInset: layout.legacy(3),
      labelStyle: context.typography.selectorLabel,
    );
  }

  void _showGroupSelectorSheet(
    BuildContext context,
    WidgetRef ref,
    List<Group> groups,
    String selectedGroupName,
  ) {
    showSheet(
      context: context,
      props: const SheetProps(isScrollControlled: true),
      builder: (sheetContext) {
        final surge = SurgeTheme.of(sheetContext);
        return SizedBox(
          height: MediaQuery.of(context).size.height * 0.65,
          child: AdaptiveSheetScaffold(
            title: sheetContext.appLocalizations.proxyGroup,
            appBarActions: const [],
            body: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              itemCount: groups.length,
              itemBuilder: (context, index) {
                final group = groups[index];
                final isSelected = group.name == selectedGroupName;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: SurgeSelectableRow(
                    selected: isSelected,
                    onTap: () {
                      proxy_common.updateCurrentGroupName(group.name);
                      Navigator.of(context).pop();
                    },
                    presentation: SurgeSelectionPresentation.menu,
                    showBorder: true,
                    radius: surge.radii.menuRow,
                    selectedSurfaceColor: surge.selectedFill,
                    unselectedSurfaceColor: surge.fill,
                    selectedBorderColor: surge.primary.withValues(alpha: 0.48),
                    unselectedBorderColor: surge.separator,
                    selectedBorderWidth: 1,
                    unselectedBorderWidth: surge.spacing.hairline,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          if (isSelected) ...[
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: surge.semantic.connected,
                                shape: BoxShape.circle,
                              ),
                              margin: const EdgeInsets.only(right: 8),
                            ),
                          ],
                          Expanded(
                            child: Text(
                              group.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.typography.sheetRowTitle.copyWith(
                                color: surge.textPrimary,
                              ),
                            ),
                          ),
                          Text(
                            group.type.name,
                            style: context.typography.sheetLabel.copyWith(
                              color: surge.textSecondary,
                            ),
                          ),
                          if (isSelected) ...[
                            const SizedBox(width: 8),
                            Icon(
                              SurgeIcons.success,
                              size: 18,
                              color: surge.primary,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  void _showNodeSelectorSheet(
    BuildContext context,
    WidgetRef ref,
    String groupName,
    String currentProxyName,
  ) {
    final groups = ref.read(groupsProvider);
    final matchingGroups = groups.where((g) => g.name == groupName);
    final group = matchingGroups.isNotEmpty
        ? matchingGroups.first
        : groups.first;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.65,
        child: _NodeSelectionSheet(
          group: group,
          currentProxyName: currentProxyName,
        ),
      ),
    );
  }
}

class _NodeSelectionSheet extends ConsumerStatefulWidget {
  const _NodeSelectionSheet({
    required this.group,
    required this.currentProxyName,
  });

  final Group group;
  final String currentProxyName;

  @override
  ConsumerState<_NodeSelectionSheet> createState() =>
      _NodeSelectionSheetState();
}

class _NodeSelectionSheetState extends ConsumerState<_NodeSelectionSheet> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  String _searchQuery = '';
  bool _isDelayTesting = false;

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _delayTest() async {
    if (_isDelayTesting) return;
    setState(() => _isDelayTesting = true);
    await proxy_common.delayTest(widget.group.all, widget.group.testUrl);
    if (mounted) setState(() => _isDelayTesting = false);
  }

  void _scrollToSelected() {
    final proxies = widget.group.all;
    final selectedIndex = proxies.indexWhere(
      (p) => p.name == widget.currentProxyName,
    );
    if (selectedIndex == -1) return;
    // Each node card: padding vertical 10*2 + text ~18 + bottom margin 6 = ~44
    // Use a safe offset that ensures the item is visible near the top
    final targetOffset = (selectedIndex * 44.0) - 80;
    _scrollController.animateTo(
      targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: SurgeMotion.scroll,
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    final filteredProxies = widget.group.all
        .where(
          (p) =>
              _searchQuery.isEmpty ||
              p.name.toLowerCase().contains(_searchQuery.toLowerCase()),
        )
        .toList();

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        children: [
          // Drag handle
          Container(
            width: 28,
            height: 4,
            margin: const EdgeInsets.only(top: 6),
            decoration: ShapeDecoration(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // Title bar: same structure as AdaptiveSheetScaffold bottomSheet
          SizedBox(
            height: 48,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  SoftOsActionButton(
                    icon: SurgeIcons.close,
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    compact: true,
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        context.appLocalizations.nodes,
                        style: context.typography.sheetTitle,
                      ),
                    ),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          // Search field with embedded action buttons
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: TextField(
              controller: _searchController,
              onChanged: (value) => setState(() => _searchQuery = value),
              style: context.typography.body,
              decoration: InputDecoration(
                hintText: context.appLocalizations.search,
                hintStyle: context.typography.body.copyWith(
                  color: surge.textSecondary,
                ),
                prefixIcon: Icon(
                  SurgeIcons.search,
                  color: surge.textSecondary,
                  size: 20,
                ),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.all(4),
                      onPressed: _scrollToSelected,
                      iconSize: 20,
                      icon: Icon(
                        SurgeIcons.selector,
                        color: surge.textSecondary,
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.all(4),
                      onPressed: _isDelayTesting ? null : _delayTest,
                      iconSize: 20,
                      icon: _isDelayTesting
                          ? SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: surge.textSecondary,
                              ),
                            )
                          : Icon(
                              SurgeIcons.networkPing,
                              color: surge.textSecondary,
                            ),
                    ),
                  ],
                ),
                isDense: true,
                filled: true,
                fillColor: surge.fill,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(surge.radii.input),
                  borderSide: BorderSide(color: surge.separator),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(surge.radii.input),
                  borderSide: BorderSide(color: surge.separator),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(surge.radii.input),
                  borderSide: BorderSide(color: surge.primary, width: 1.5),
                ),
              ),
            ),
          ),
          // Node list
          Expanded(
            child: filteredProxies.isEmpty
                ? Center(
                    child: Text(
                      context.appLocalizations.noData,
                      style: context.typography.supporting,
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
                    itemCount: filteredProxies.length,
                    itemBuilder: (context, index) {
                      final proxy = filteredProxies[index];
                      return _NodeCard(
                        proxy: proxy,
                        group: widget.group,
                        isSelected: proxy.name == widget.currentProxyName,
                        onTap: () {
                          if (proxy_common.applyProxyGroupMemberTap(
                            group: widget.group,
                            tappedName: proxy.name,
                          )) {
                            Navigator.of(context).pop();
                          }
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _NodeCard extends ConsumerWidget {
  const _NodeCard({
    required this.proxy,
    required this.group,
    required this.isSelected,
    required this.onTap,
  });

  final Proxy proxy;
  final Group group;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final surge = SurgeTheme.of(context);
    final delay = ref.watch(
      delayProvider(proxyName: proxy.name, testUrl: group.testUrl),
    );
    final delayColor = delay == null
        ? surge.textSecondary
        : delay == 0
        ? surge.textSecondary
        : delay < 0
        ? surge.red
        : utils.getDelayColor(delay) ?? surge.textSecondary;
    final delayLabel = delay == null
        ? ''
        : delay == 0
        ? '...'
        : delay > 0
        ? '${delay}ms'
        : 'Timeout';

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: SurgeSelectableRow(
        selected: isSelected,
        onTap: onTap,
        presentation: SurgeSelectionPresentation.menu,
        showBorder: true,
        radius: surge.radii.menuRow,
        selectedSurfaceColor: surge.selectedFill,
        unselectedSurfaceColor: surge.fill,
        selectedBorderColor: surge.primary.withValues(alpha: 0.48),
        unselectedBorderColor: surge.separator,
        selectedBorderWidth: 1,
        unselectedBorderWidth: surge.spacing.hairline,
        child: SizedBox(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                if (isSelected) ...[
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: surge.semantic.connected,
                      shape: BoxShape.circle,
                    ),
                    margin: const EdgeInsets.only(right: 8),
                  ),
                ],
                Expanded(
                  child: Text(
                    proxy.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.typography.sheetRowTitle.copyWith(
                      color: surge.textPrimary,
                    ),
                  ),
                ),
                if (delayLabel.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: delayColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(surge.radii.metric),
                    ),
                    child: Text(
                      delayLabel,
                      style: context.typography.sheetLabel.copyWith(
                        color: delayColor,
                      ),
                    ),
                  ),
                ],
                if (isSelected) ...[
                  const SizedBox(width: 8),
                  Icon(
                    SurgeIcons.success,
                    size: SurgeIconSize.compact,
                    color: surge.primary,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
