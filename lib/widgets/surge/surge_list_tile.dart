import 'package:fl_clash/common/icons.dart';
import 'package:flutter/material.dart';

import 'surge_pressable.dart';
import 'surge_theme_extension.dart';

class SurgeListTile extends StatelessWidget {
  const SurgeListTile({
    super.key,
    required this.title,
    this.leading,
    this.subtitle,
    this.trailing,
    this.showChevron = false,
    this.onTap,
    this.dense = false,
    this.showDivider = true,
    this.destructive = false,
    this.enabled = true,
    this.titleTextStyle,
    this.subtitleTextStyle,
  });

  final Widget? leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final bool showChevron;
  final VoidCallback? onTap;
  final bool dense;
  final bool showDivider;
  final bool destructive;
  final bool enabled;
  final TextStyle? titleTextStyle;
  final TextStyle? subtitleTextStyle;

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    final titleColor = !enabled
        ? surge.textSecondary.withValues(alpha: 0.45)
        : destructive
        ? surge.red
        : surge.textPrimary;
    final minHeight = dense ? 52.0 : 64.0;
    final hasSubtitle = subtitle != null && subtitle!.isNotEmpty;

    return SurgePressable(
      onTap: enabled ? onTap : null,
      enabled: enabled,
      scaleFeedback: false,
      overlayInsets: EdgeInsets.symmetric(vertical: surge.spacing.hairline),
      overlayBaseColor: surge.card,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Row(
                children: [
                  if (leading != null) ...[
                    IconTheme.merge(
                      data: IconThemeData(
                        color: destructive ? surge.red : surge.primary,
                        size: 21,
                      ),
                      child: leading!,
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 14),
                      child: Row(
                        children: [
                          Expanded(
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                vertical: hasSubtitle ? 8 : 0,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style:
                                        (titleTextStyle ??
                                                context.typography.rowTitle)
                                            .copyWith(color: titleColor),
                                  ),
                                  if (hasSubtitle) ...[
                                    const SizedBox(height: 3),
                                    Text(
                                      subtitle!,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style:
                                          (subtitleTextStyle ??
                                          context.typography.supporting),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          if (trailing != null) ...[
                            const SizedBox(width: 12),
                            trailing!,
                          ],
                          if (showChevron) ...[
                            const SizedBox(width: 8),
                            Icon(
                              SurgeIcons.chevronRight,
                              color: surge.textSecondary.withValues(alpha: 0.7),
                              size: 22,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (showDivider)
              Positioned(
                left: leading == null ? 16 : 49,
                right: 0,
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
    );
  }
}
