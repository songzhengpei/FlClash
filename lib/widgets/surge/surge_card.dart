import 'package:flutter/material.dart';

import 'surge_pressable.dart';
import 'surge_theme_extension.dart';

class SurgeCard extends StatelessWidget {
  const SurgeCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.borderRadius,
    this.backgroundColor,
    this.onTap,
    this.height,
    this.width,
    this.shadow = true,
    this.border,
    this.clipBehavior = Clip.antiAlias,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double? borderRadius;
  final Color? backgroundColor;
  final VoidCallback? onTap;
  final double? height;
  final double? width;
  final bool shadow;
  final BoxBorder? border;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    final radius = BorderRadius.circular(borderRadius ?? surge.radii.card);
    final decoration = BoxDecoration(
      color: backgroundColor ?? surge.card,
      border: border ?? Border.all(color: surge.separator, width: 0.5),
      borderRadius: radius,
      boxShadow: shadow
          ? [
              BoxShadow(
                color: surge.shadow.withValues(alpha: 0.55),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ]
          : null,
    );

    return Padding(
      padding: margin ?? EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: radius,
        child: SurgePressable(
          onTap: onTap,
          borderRadius: radius,
          scaleFeedback: false,
          child: Material(
            color: Colors.transparent,
            clipBehavior: clipBehavior,
            child: Ink(
              height: height,
              width: width,
              decoration: decoration,
              child: Padding(
                padding: padding ?? EdgeInsets.all(surge.spacing.cardPadding),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shared no-shadow list surface for grouped rows. [SurgeCard] owns clipping,
/// so callers do not need to duplicate a matching [ClipRRect].
class SurgeListSurface extends StatelessWidget {
  const SurgeListSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    return SurgeCard(
      padding: EdgeInsets.zero,
      borderRadius: surge.radii.card,
      shadow: false,
      child: child,
    );
  }
}
