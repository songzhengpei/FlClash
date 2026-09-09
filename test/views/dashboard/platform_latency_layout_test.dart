import 'package:fl_clash/common/network_diagnostics_models.dart';
import 'package:fl_clash/theme/typography/text_theme.dart';
import 'package:fl_clash/views/dashboard/dashboard_layout.dart';
import 'package:fl_clash/views/dashboard/widgets/network_overview_card.dart';
import 'package:fl_clash/widgets/surge/surge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final width in [280.0, 320.0, 360.0, 384.0]) {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets('complete latency at ${width}dp and ${scale}x text', (
        tester,
      ) async {
        final layout = DashboardResponsiveLayout.fromViewport(
          viewportWidth: width,
          viewportHeight: 850,
          textScaler: TextScaler.linear(scale),
        );
        final textTheme = buildSlclashTextTheme();
        final typography = SurgeTypography.fromTextTheme(textTheme);
        for (final latency in [590, 617, 942, 9999, 123456, null]) {
          final label = latency == null ? 'Timeout' : '${latency}ms';
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(
                textTheme: textTheme,
                extensions: [
                  SurgeTheme.light(),
                  typography.copyWith(
                    // Wider glyph spacing also exercises OEM/custom fonts.
                    dashboardLatencyValue: typography.dashboardLatencyValue
                        .copyWith(letterSpacing: 1.5),
                  ),
                ],
              ),
              home: MediaQuery(
                data: MediaQueryData(
                  textScaler: TextScaler.linear(scale),
                  boldText: scale > 1,
                ),
                child: Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: layout.cardInnerWidth * 0.7,
                      child: PlatformLatencyPanel(
                        targets: NetworkDiagnosticTarget.all,
                        results: {
                          'GitHub': const NetworkDiagnosticTargetState(
                            target: NetworkDiagnosticTarget.github,
                            latencyMs: 123,
                          ),
                          'ChatGPT': const NetworkDiagnosticTargetState(
                            target: NetworkDiagnosticTarget.chatgpt,
                            latencyMs: 456,
                          ),
                          'YouTube': NetworkDiagnosticTargetState(
                            target: NetworkDiagnosticTarget.youtube,
                            latencyMs: latency,
                            latencyStatus: latency == null
                                ? NetworkDiagnosticLatencyStatus.timeout
                                : NetworkDiagnosticLatencyStatus.fresh,
                          ),
                        },
                        fallbackCountryCode: null,
                        activeColor: Colors.green,
                        fillColor: Colors.grey,
                        textColor: Colors.black,
                        secondaryTextColor: Colors.grey,
                        dangerColor: Colors.red,
                        latencyGood: Colors.green,
                        latencyMedium: Colors.orange,
                        latencyBad: Colors.red,
                        onRetest: () {},
                        shouldAnimatePending: false,
                        rowGap: 8,
                        layout: layout,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          final paragraph = tester.renderObject<RenderParagraph>(
            find.text(label),
          );
          final intrinsicWidth = paragraph.getMaxIntrinsicWidth(
            double.infinity,
          );
          // No characters may be clipped before painting/scaling.
          expect(
            paragraph.size.width,
            greaterThanOrEqualTo(intrinsicWidth - 0.01),
          );
          expect(paragraph.didExceedMaxLines, isFalse);
          final panelRect = tester.getRect(find.byType(PlatformLatencyPanel));
          final topLeft = paragraph.localToGlobal(Offset.zero);
          final bottomRight = paragraph.localToGlobal(
            paragraph.size.bottomRight(Offset.zero),
          );
          expect(topLeft.dx, greaterThanOrEqualTo(panelRect.left));
          expect(bottomRight.dx, lessThanOrEqualTo(panelRect.right + 0.01));
          final sharedScale = paragraph
              .getTransformTo(null)
              .getMaxScaleOnAxis();
          for (final otherLabel in ['123ms', '456ms']) {
            final other = tester.renderObject<RenderParagraph>(
              find.text(otherLabel),
            );
            expect(
              other.getTransformTo(null).getMaxScaleOnAxis(),
              closeTo(sharedScale, 0.0001),
              reason: 'All three values must use the same visual font size',
            );
            expect(
              other.localToGlobal(other.size.bottomRight(Offset.zero)).dx,
              closeTo(bottomRight.dx, 0.01),
            );
          }
          expect(tester.takeException(), isNull);
        }
      });
    }
  }
}
