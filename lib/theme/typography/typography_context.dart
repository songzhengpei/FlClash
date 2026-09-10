import 'package:flutter/material.dart';

import 'surge_typography.dart';

extension SlclashTypographyContext on BuildContext {
  SurgeTypography get typography {
    final typography = Theme.of(this).extension<SurgeTypography>();
    assert(
      typography != null,
      'SurgeTypography is not registered in ThemeData.extensions.',
    );
    return typography!;
  }

  TextStyle resolveBoldText(BuildContext context, TextStyle style) {
    if (MediaQuery.boldTextOf(context)) {
      return style.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    return style;
  }
}
