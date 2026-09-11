import 'dart:ui' as ui;

import 'package:fl_clash/common/network_diagnostics_models.dart';
import 'package:fl_clash/theme/typography/text_theme.dart';
import 'package:fl_clash/views/dashboard/dashboard_layout.dart';
import 'package:fl_clash/views/dashboard/widgets/network_overview_card.dart';
import 'package:fl_clash/widgets/surge/surge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Compare only the value column: flags and bars may change during refresh.
Future<List<int>> _valuePixels(GlobalKey key, double width) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  const ratio = 3.75;
  final image = await boundary.toImage(pixelRatio: ratio);
  final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final bytes = data.buffer.asUint8List();
  final startX = image.width - (width * ratio).floor();
  final pixels = <int>[];
  for (var y = 0; y < image.height; y++) {
    pixels.addAll(
      bytes.sublist((y * image.width + startX) * 4, (y + 1) * image.width * 4),
    );
  }
  image.dispose();
  return pixels;
}

void main() {
  setUpAll(() async {
    final loader = FontLoader('LatencyPaintFont')
      ..addFont(rootBundle.load('assets/fonts/JetBrainsMono-Regular.ttf'));
    await loader.load();
  });

  for (final width in [320.0, 376.0, 384.0]) {
    testWidgets('refresh completion preserves value pixels at ${width}dp', (
      tester,
    ) async {
      final key = GlobalKey();
      final layout = DashboardResponsiveLayout.fromViewport(
        viewportWidth: width,
        viewportHeight: 850,
        textScaler: const TextScaler.linear(1.3),
      );
      final typography = SurgeTypography.fromTextTheme(buildSlclashTextTheme());
      final refresh = ValueNotifier(true);
      addTearDown(refresh.dispose);
      for (final latency in [863, 123456, null]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              extensions: [
                SurgeTheme.light(),
                typography.copyWith(
                  dashboardLatencyValue: typography.dashboardLatencyValue
                      .copyWith(fontFamily: 'LatencyPaintFont'),
                ),
              ],
            ),
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
              child: Scaffold(
                body: Center(
                  child: ValueListenableBuilder<bool>(
                    valueListenable: refresh,
                    builder: (context, refreshing, child) => RepaintBoundary(
                      key: key,
                      child: ColoredBox(
                        color: Colors.white,
                        child: SizedBox(
                          width: layout.cardInnerWidth * 0.7,
                          child: PlatformLatencyPanel(
                            targets: NetworkDiagnosticTarget.all,
                            results: {
                              for (final target in NetworkDiagnosticTarget.all)
                                target.name: NetworkDiagnosticTargetState(
                                  target: target,
                                  latencyMs: latency,
                                  refreshing: refreshing,
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
              ),
            ),
          ),
        );
        await tester.pump();
        final before = await tester.runAsync(
          () => _valuePixels(key, layout.geometry(50)),
        );
        for (final state in [false, true, false]) {
          refresh.value = state;
          await tester.pump();
          expect(
            await tester.runAsync(() => _valuePixels(key, layout.geometry(50))),
            orderedEquals(before!),
            reason:
                'Unchanged values must not change pixels when refreshing toggles',
          );
        }
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
