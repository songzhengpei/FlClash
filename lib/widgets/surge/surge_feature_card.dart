import 'package:flutter/material.dart';

import 'surge_pressable.dart';
import 'surge_theme_extension.dart';

class SurgeFeatureCard extends StatelessWidget {
  const SurgeFeatureCard({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.trailing,
    this.color,
    this.gradient,
    this.onTap,
    this.child,
    this.height,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;
  final Color? color;
  final Gradient? gradient;
  final VoidCallback? onTap;
  final Widget? child;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    final baseColor = color ?? surge.primary;
    final onBaseColor = color == null ? surge.onPrimary : Colors.white;
    final radius = BorderRadius.circular(surge.radii.card);
    final effectiveGradient =
        gradient ??
        LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [baseColor, Color.lerp(baseColor, Colors.black, 0.14)!],
        );

    return SurgePressable(
      onTap: onTap,
      borderRadius: radius,
      scaleFeedback: false,
      child: Material(
        color: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        borderRadius: radius,
        child: Ink(
          height: height,
          decoration: BoxDecoration(
            borderRadius: radius,
            gradient: effectiveGradient,
            boxShadow: [
              BoxShadow(
                color: baseColor.withValues(alpha: 0.18),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Padding(
            padding: EdgeInsets.all(surge.spacing.cardPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, color: onBaseColor, size: 24),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            maxLines: 2,
                            style: context.typography.cardTitle.copyWith(
                              color: onBaseColor,
                            ),
                          ),
                          if (subtitle != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              subtitle!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: context.typography.supporting.copyWith(
                                color: onBaseColor.withValues(alpha: 0.78),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (trailing != null) ...[
                      const SizedBox(width: 12),
                      trailing!,
                    ],
                  ],
                ),
                if (child != null) ...[const SizedBox(height: 14), child!],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
