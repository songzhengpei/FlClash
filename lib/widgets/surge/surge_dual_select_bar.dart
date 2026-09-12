import 'package:fl_clash/common/icons.dart';
import 'package:flutter/material.dart';

import 'surge_pressable.dart';
import 'surge_theme_extension.dart';

/// Two equal selection targets inside a single Soft OS pill.
///
/// The caller supplies dimensions so dense dashboard layouts retain their
/// established geometry while future pages share the same interaction model.
class SurgeDualSelectBar extends StatelessWidget {
  const SurgeDualSelectBar({
    super.key,
    required this.firstLabel,
    required this.secondLabel,
    required this.onFirstTap,
    required this.onSecondTap,
    required this.height,
    required this.padding,
    required this.radius,
    required this.itemRadius,
    required this.dividerHeight,
    required this.dividerMargin,
    required this.labelStyle,
    required this.iconSize,
    required this.labelGap,
    this.itemVerticalInset = 0,
  });

  final String firstLabel;
  final String secondLabel;
  final VoidCallback? onFirstTap;
  final VoidCallback? onSecondTap;
  final double height;
  final EdgeInsetsGeometry padding;
  final double radius;
  final double itemRadius;
  final double dividerHeight;
  final double dividerMargin;
  final TextStyle labelStyle;
  final double iconSize;
  final double labelGap;
  final double itemVerticalInset;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    return Container(
      width: double.infinity,
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        color: surge.fill,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _SurgeDualSelectTarget(
              label: firstLabel,
              onTap: onFirstTap,
              radius: itemRadius,
              labelStyle: labelStyle,
              iconSize: iconSize,
              labelGap: labelGap,
              verticalInset: itemVerticalInset,
            ),
          ),
          Container(
            width: 1,
            height: dividerHeight,
            margin: EdgeInsets.symmetric(horizontal: dividerMargin),
            color: surge.separator,
          ),
          Expanded(
            child: _SurgeDualSelectTarget(
              label: secondLabel,
              onTap: onSecondTap,
              radius: itemRadius,
              labelStyle: labelStyle,
              iconSize: iconSize,
              labelGap: labelGap,
              verticalInset: itemVerticalInset,
            ),
          ),
        ],
      ),
    );
  }
}

class _SurgeDualSelectTarget extends StatelessWidget {
  const _SurgeDualSelectTarget({
    required this.label,
    required this.onTap,
    required this.radius,
    required this.labelStyle,
    required this.iconSize,
    required this.labelGap,
    required this.verticalInset,
  });

  final String label;
  final VoidCallback? onTap;
  final double radius;
  final TextStyle labelStyle;
  final double iconSize;
  final double labelGap;
  final double verticalInset;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: verticalInset),
      child: SurgePressable(
        compact: true,
        scaleFeedback: false,
        overlayOpacity: 0.04,
        borderRadius: BorderRadius.circular(radius),
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: labelStyle.copyWith(color: surge.textPrimary),
              ),
            ),
            SizedBox(width: labelGap),
            Icon(SurgeIcons.expand, size: iconSize, color: surge.textSecondary),
          ],
        ),
      ),
    );
  }
}
