import 'package:flutter/material.dart';

import 'surge_pressable.dart';
import 'surge_theme_extension.dart';

class SurgeDataListItem extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry margin;
  final EdgeInsetsGeometry padding;

  const SurgeDataListItem({
    super.key,
    required this.child,
    this.onTap,
    this.margin = const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
  });

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    final borderRadius = BorderRadius.circular(surge.radii.list);
    return Padding(
      padding: margin,
      child: SurgePressable(
        onTap: onTap,
        borderRadius: borderRadius,
        scaleFeedback: false,
        child: Material(
          color: Colors.transparent,
          clipBehavior: Clip.antiAlias,
          borderRadius: borderRadius,
          child: Ink(
            decoration: BoxDecoration(
              color: surge.card,
              borderRadius: borderRadius,
              border: Border.all(
                color: surge.separator.withValues(alpha: 0.78),
                width: 0.7,
              ),
            ),
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}

class SurgeDataHeader extends StatelessWidget {
  final String text;

  const SurgeDataHeader({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
      child: Text(
        text,
        style: context.typography.supporting.copyWith(
          color: surge.textSecondary,
        ),
      ),
    );
  }
}
