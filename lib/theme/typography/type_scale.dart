import 'package:flutter/material.dart';

import 'font_families.dart';

/// The single source of truth for every structural typography value.
abstract final class SlclashTypeScale {
  static const _letterSpacing = 0.0;

  static const rootAppBarTitle = TextStyle(
    fontSize: 20,
    height: 1.3,
    fontWeight: FontWeight.w600,
    letterSpacing: _letterSpacing,
  );
  static const screenTitle = TextStyle(
    fontSize: 19,
    height: 1.4737,
    fontWeight: FontWeight.w500,
    letterSpacing: _letterSpacing,
  );
  static const appBarTitle = TextStyle(
    fontSize: 19,
    height: 1.3,
    fontWeight: FontWeight.w500,
    letterSpacing: _letterSpacing,
  );
  static const dialogTitle = TextStyle(
    fontSize: 18,
    height: 1.3333,
    fontWeight: FontWeight.w600,
    letterSpacing: _letterSpacing,
  );
  static const sectionTitle = TextStyle(
    fontSize: 14,
    height: 1.4667,
    fontWeight: FontWeight.w500,
    letterSpacing: _letterSpacing,
  );
  static const mediaCheckTitle = TextStyle(
    fontSize: 16,
    height: 1.25,
    fontWeight: FontWeight.w500,
    letterSpacing: _letterSpacing,
  );
  static const mediaControlMetricLabel = TextStyle(
    fontSize: 12,
    height: 1,
    fontWeight: FontWeight.w600,
    letterSpacing: _letterSpacing,
  );
  static const mediaFilterTitle = TextStyle(
    fontSize: 14,
    height: 1.4286,
    fontWeight: FontWeight.w600,
    letterSpacing: _letterSpacing,
  );
  static const mediaFilterSubtitle = TextStyle(
    fontFamily: SlclashFontFamilies.jetBrainsMono,
    fontSize: 12,
    height: 1.3333,
    fontWeight: FontWeight.w500,
    letterSpacing: _letterSpacing,
  );
  static const mediaObservationInterval = TextStyle(
    fontSize: 13,
    height: 1.2308,
    fontWeight: FontWeight.w600,
    letterSpacing: _letterSpacing,
  );
  static const mediaResultTitle = TextStyle(
    fontSize: 12,
    height: 1.3333,
    fontWeight: FontWeight.w600,
    letterSpacing: _letterSpacing,
  );
  static const mediaRunButtonLabel = TextStyle(
    fontSize: 12,
    height: 1.3333,
    fontWeight: FontWeight.w600,
    letterSpacing: _letterSpacing,
  );
  static const cardTitle = TextStyle(
    fontSize: 16,
    height: 1.125,
    fontWeight: FontWeight.w500,
    letterSpacing: _letterSpacing,
  );
  static const rowTitle = TextStyle(
    fontSize: 15,
    height: 1.4667,
    fontWeight: FontWeight.w500,
    letterSpacing: _letterSpacing,
  );
  static const toolTileSubtitle = TextStyle(
    fontSize: 13,
    height: 1.2308,
    fontWeight: FontWeight.w400,
    letterSpacing: _letterSpacing,
  );
  static const toolTileTitle = TextStyle(
    fontSize: 16,
    height: 1.4667,
    fontWeight: FontWeight.w400,
    letterSpacing: _letterSpacing,
  );
  static const compactDescription = TextStyle(
    fontSize: 12,
    height: 1.4667,
    fontWeight: FontWeight.w400,
    letterSpacing: _letterSpacing,
  );
  static const body = TextStyle(
    fontSize: 15,
    height: 1.4667,
    fontWeight: FontWeight.w400,
    letterSpacing: _letterSpacing,
  );
  static const supporting = TextStyle(
    fontSize: 13,
    height: 1.2308,
    fontWeight: FontWeight.w400,
    letterSpacing: _letterSpacing,
  );
  static const controlLabel = TextStyle(
    fontSize: 14,
    height: 1.4286,
    fontWeight: FontWeight.w600,
    letterSpacing: _letterSpacing,
  );
  static const navigationLabel = TextStyle(
    fontSize: 11,
    height: 1.0,
    fontWeight: FontWeight.w500,
    letterSpacing: _letterSpacing,
  );
  static const selectedNavigationLabel = TextStyle(
    fontSize: 11,
    height: 1.0,
    fontWeight: FontWeight.w600,
    letterSpacing: _letterSpacing,
  );
  static const badgeLabel = TextStyle(
    fontSize: 11,
    height: 1,
    fontWeight: FontWeight.w600,
    letterSpacing: _letterSpacing,
  );
  static const profileTypeLabel = TextStyle(
    fontSize: 10.5,
    height: 1,
    fontWeight: FontWeight.w600,
    letterSpacing: _letterSpacing,
  );
  static const selectedRowTitle = TextStyle(
    fontSize: 15,
    height: 1.4667,
    fontWeight: FontWeight.w600,
    letterSpacing: _letterSpacing,
  );
  static const modeTabLabel = TextStyle(
    fontSize: 14,
    height: 1.4667,
    fontWeight: FontWeight.w500,
    letterSpacing: _letterSpacing,
  );
  static const selectedModeTabLabel = TextStyle(
    fontSize: 14,
    height: 1.4667,
    fontWeight: FontWeight.w600,
    letterSpacing: _letterSpacing,
  );
  static const selectorLabel = TextStyle(
    fontSize: 13,
    height: 1.2308,
    fontWeight: FontWeight.w600,
    letterSpacing: _letterSpacing,
  );
  static const metricLarge = TextStyle(
    fontSize: 24,
    height: 1.25,
    fontWeight: FontWeight.w600,
    letterSpacing: _letterSpacing,
  );
  static const metric = TextStyle(
    fontSize: 14,
    height: 1.2857,
    fontWeight: FontWeight.w600,
    letterSpacing: _letterSpacing,
  );
  static const compactMetric = TextStyle(
    fontSize: 13,
    height: 1.2308,
    fontWeight: FontWeight.w400,
    letterSpacing: _letterSpacing,
  );
  static const technical = TextStyle(
    fontFamily: SlclashFontFamilies.jetBrainsMono,
    fontSize: 13,
    height: 1.3846,
    fontWeight: FontWeight.w500,
    letterSpacing: _letterSpacing,
  );
  static const detailLabel = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    letterSpacing: _letterSpacing,
  );
  static const compactRowTitle = TextStyle(
    fontSize: 14,
    height: 1.4286,
    fontWeight: FontWeight.w400,
    letterSpacing: _letterSpacing,
  );
  static const proxyGroupTitle = TextStyle(
    fontSize: 16,
    height: 1.2941,
    fontWeight: FontWeight.w500,
    letterSpacing: _letterSpacing,
  );
  static const proxySelectorLabel = TextStyle(
    fontSize: 12,
    height: 1.3846,
    fontWeight: FontWeight.w400,
    letterSpacing: _letterSpacing,
  );
  static const proxyCardSubtitle = TextStyle(
    fontSize: 12,
    height: 1.3846,
    fontWeight: FontWeight.w400,
    letterSpacing: _letterSpacing,
  );
  static const featuredTitle = TextStyle(
    fontSize: 17,
    height: 1.4667,
    fontWeight: FontWeight.w500,
    letterSpacing: _letterSpacing,
  );
  static const pillLabel = TextStyle(
    fontSize: 12,
    height: 1.0,
    fontWeight: FontWeight.w600,
    letterSpacing: _letterSpacing,
  );
  static const itemLabel = TextStyle(
    fontSize: 14,
    height: 1.4667,
    fontWeight: FontWeight.w500,
    letterSpacing: _letterSpacing,
  );
  static const previewLabel = TextStyle(
    fontSize: 13,
    height: 1.4286,
    fontWeight: FontWeight.w500,
    letterSpacing: _letterSpacing,
  );
  static const sheetRowTitle = TextStyle(
    fontSize: 14,
    height: 1.4667,
    fontWeight: FontWeight.w600,
    letterSpacing: _letterSpacing,
  );
  static const sheetLabel = TextStyle(
    fontSize: 12,
    height: 1.0,
    fontWeight: FontWeight.w400,
    letterSpacing: _letterSpacing,
  );
  static const sheetTitle = TextStyle(
    fontSize: 18,
    height: 1.3,
    fontWeight: FontWeight.w500,
    letterSpacing: _letterSpacing,
  );
  static const countLabel = TextStyle(
    fontSize: 12,
    height: 1.2308,
    fontWeight: FontWeight.w400,
    letterSpacing: _letterSpacing,
  );
  static const chartLabel = TextStyle(
    fontFamily: SlclashFontFamilies.jetBrainsMono,
    fontSize: 10,
    height: 1.4,
    fontWeight: FontWeight.w500,
    letterSpacing: _letterSpacing,
  );
  static const techLabel = TextStyle(
    fontSize: 13,
    height: 1.3846,
    fontWeight: FontWeight.w500,
    letterSpacing: _letterSpacing,
  );
  static const dashboardMetric = TextStyle(
    fontSize: 14,
    height: 1.2857,
    fontWeight: FontWeight.w700,
    letterSpacing: _letterSpacing,
  );
  static const dashboardIpValue = TextStyle(
    fontSize: 13,
    height: 1.2857,
    fontWeight: FontWeight.w600,
    letterSpacing: _letterSpacing,
  );
  static const dashboardLatencyValue = TextStyle(
    fontSize: 12,
    height: 0,
    fontWeight: FontWeight.w500,
    letterSpacing: _letterSpacing,
  );
  static const dashboardDetectionValue = TextStyle(
    fontSize: 16,
    height: 1.2857,
    fontWeight: FontWeight.w700,
    letterSpacing: _letterSpacing,
  );

  // Material-only fallback slots. They are intentionally not exposed through
  // SurgeTypography, so product code cannot use them as semantic roles.
  static const materialDisplayLarge = TextStyle(
    fontSize: 32,
    height: 1.25,
    fontWeight: FontWeight.w600,
    letterSpacing: _letterSpacing,
  );
  static const materialDisplayMedium = TextStyle(
    fontSize: 28,
    height: 1.2857,
    fontWeight: FontWeight.w600,
    letterSpacing: _letterSpacing,
  );
  static const materialBodySmall = TextStyle(
    fontSize: 11,
    height: 1.4545,
    fontWeight: FontWeight.w400,
    letterSpacing: _letterSpacing,
  );
}
