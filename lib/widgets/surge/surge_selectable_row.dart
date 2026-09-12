import 'package:flutter/material.dart';

import 'surge_pressable.dart';
import 'surge_theme_extension.dart';

/// Visual presentations for a selected item without duplicating selection
/// semantics in list, card, and sheet implementations.
enum SurgeSelectionPresentation { list, menu, subtle }

/// Position within a visually grouped list.
enum SurgeSelectableRowPosition { single, first, middle, last }

class SurgeSelectableRow extends StatelessWidget {
  const SurgeSelectableRow({
    super.key,
    required this.child,
    required this.selected,
    this.onTap,
    this.onLongPress,
    this.position = SurgeSelectableRowPosition.single,
    this.presentation = SurgeSelectionPresentation.list,
    this.showBorder = false,
    this.showShadow = false,
    this.showDivider = false,
    this.dividerInsets = const EdgeInsets.symmetric(horizontal: 16),
    this.selectedIndicatorLeft = 14,
    this.selectedIndicatorHeight = 28,
    this.selectedIndicatorWidth = 3,
    this.borderOpacity = 0.74,
    this.dividerOpacity = 0.62,
    this.radius,
    this.selectedSurfaceColor,
    this.unselectedSurfaceColor,
    this.selectedBorderColor,
    this.unselectedBorderColor,
    this.selectedBorderWidth,
    this.unselectedBorderWidth,
  });

  final Widget child;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final SurgeSelectableRowPosition position;
  final SurgeSelectionPresentation presentation;
  final bool showBorder;
  final bool showShadow;
  final bool showDivider;
  final EdgeInsetsGeometry dividerInsets;
  final double selectedIndicatorLeft;
  final double selectedIndicatorHeight;
  final double selectedIndicatorWidth;
  final double borderOpacity;
  final double dividerOpacity;
  final double? radius;
  final Color? selectedSurfaceColor;
  final Color? unselectedSurfaceColor;
  final Color? selectedBorderColor;
  final Color? unselectedBorderColor;
  final double? selectedBorderWidth;
  final double? unselectedBorderWidth;

  bool get _isFirst =>
      position == SurgeSelectableRowPosition.first ||
      position == SurgeSelectableRowPosition.single;

  bool get _isLast =>
      position == SurgeSelectableRowPosition.last ||
      position == SurgeSelectableRowPosition.single;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    final rowRadius = BorderRadius.vertical(
      top: _isFirst ? Radius.circular(radius ?? surge.radii.card) : Radius.zero,
      bottom: _isLast
          ? Radius.circular(radius ?? surge.radii.card)
          : Radius.zero,
    );
    final borderColor = selected
        ? selectedBorderColor ??
              surge.separator.withValues(alpha: borderOpacity)
        : unselectedBorderColor ??
              surge.separator.withValues(alpha: borderOpacity);
    final borderWidth = selected
        ? selectedBorderWidth ?? surge.spacing.hairline
        : unselectedBorderWidth ?? surge.spacing.hairline;
    final border = !showBorder
        ? null
        : Border(
            left: BorderSide(color: borderColor, width: borderWidth),
            right: BorderSide(color: borderColor, width: borderWidth),
            top: _isFirst
                ? BorderSide(color: borderColor, width: borderWidth)
                : BorderSide.none,
            bottom: _isLast
                ? BorderSide(color: borderColor, width: borderWidth)
                : BorderSide.none,
          );
    final surface = selected
        ? selectedSurfaceColor ??
              Color.alphaBlend(
                surge.primary.withValues(alpha: surge.opacity.selectedSurface),
                surge.card,
              )
        : unselectedSurfaceColor ?? surge.card;
    final isGrouped = position != SurgeSelectableRowPosition.single;

    return Semantics(
      selected: selected,
      child: SurgePressable(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: rowRadius,
        overlayInsets: isGrouped
            ? EdgeInsets.symmetric(vertical: surge.spacing.hairline)
            : EdgeInsets.zero,
        overlayBaseColor: isGrouped ? surface : null,
        scaleFeedback: false,
        child: Material(
          color: Colors.transparent,
          clipBehavior: Clip.antiAlias,
          borderRadius: rowRadius,
          child: Ink(
            decoration: BoxDecoration(
              color: surface,
              borderRadius: rowRadius,
              border: border,
              boxShadow: showShadow && _isFirst
                  ? [
                      BoxShadow(
                        color: surge.shadow.withValues(alpha: 0.10),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            child: Stack(
              children: [
                child,
                if (showDivider)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Padding(
                      padding: dividerInsets,
                      child: Divider(
                        height: 0,
                        thickness: surge.spacing.hairline,
                        color: surge.separator.withValues(
                          alpha: dividerOpacity,
                        ),
                      ),
                    ),
                  ),
                if (selected && presentation == SurgeSelectionPresentation.list)
                  Positioned(
                    left: selectedIndicatorLeft,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: Container(
                        width: selectedIndicatorWidth,
                        height: selectedIndicatorHeight,
                        decoration: BoxDecoration(
                          color: surge.primary.withValues(alpha: 0.64),
                          borderRadius: BorderRadius.circular(
                            selectedIndicatorWidth / 2,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
