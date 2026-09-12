import 'package:fl_clash/widgets/surge/surge.dart';
import 'package:fl_clash/theme/typography/text_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) {
  final textTheme = buildSlclashTextTheme();
  final typography = SurgeTypography.fromTextTheme(textTheme);
  return MaterialApp(
    theme: ThemeData(
      textTheme: textTheme,
      extensions: [SurgeTheme.light(), typography],
    ),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  test('motion tokens keep the agreed interaction rhythm', () {
    expect(SurgeMotion.press, const Duration(milliseconds: 110));
    expect(SurgeMotion.state, const Duration(milliseconds: 160));
    expect(SurgeMotion.reveal, const Duration(milliseconds: 180));
    expect(SurgeMotion.container, const Duration(milliseconds: 220));
    expect(SurgeMotion.pageEnter, const Duration(milliseconds: 280));
    expect(SurgeMotion.pageExit, const Duration(milliseconds: 210));
    expect(SurgeMotion.sheetEnter, const Duration(milliseconds: 300));
    expect(SurgeMotion.sheetExit, const Duration(milliseconds: 200));
    expect(SurgeMotion.pressedScale, 0.98);
  });

  testWidgets('press feedback starts immediately and resets after cancel', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        SurgePressable(
          onTap: () {},
          borderRadius: BorderRadius.circular(12),
          child: const SizedBox(width: 100, height: 48),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(SurgePressable)),
    );
    await tester.pump();
    expect(
      tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
      0.98,
    );
    await gesture.cancel();
    await tester.pump();
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
  });

  testWidgets('disabled pressable neither animates nor invokes tap', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _app(
        SurgePressable(
          enabled: false,
          onTap: () => taps++,
          child: const SizedBox(width: 100, height: 48),
        ),
      ),
    );
    await tester.tap(find.byType(SurgePressable));
    await tester.pump();
    expect(taps, 0);
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
  });

  testWidgets('pressed overlay can cover adjacent dividers', (tester) async {
    await tester.pumpWidget(
      _app(
        SurgePressable(
          onTap: () {},
          scaleFeedback: false,
          overlayInsets: const EdgeInsets.symmetric(vertical: 1),
          overlayBaseColor: Colors.black,
          child: const SizedBox(width: 100, height: 48),
        ),
      ),
    );

    final positionedFinder = find.descendant(
      of: find.byType(SurgePressable),
      matching: find.byType(Positioned),
    );
    expect(positionedFinder, findsNWidgets(3));
    final overlay = tester.widget<Positioned>(positionedFinder.first);
    expect(overlay.top, -1);
    expect(overlay.bottom, -1);
    expect(overlay.left, 0);
    expect(overlay.right, 0);
    final topDividerCover = tester.widget<Positioned>(positionedFinder.at(1));
    final bottomDividerCover = tester.widget<Positioned>(
      positionedFinder.at(2),
    );
    expect(topDividerCover.top, -1);
    expect(topDividerCover.height, 2);
    expect(bottomDividerCover.bottom, -1);
    expect(bottomDividerCover.height, 2);
  });

  testWidgets('long press remains interactive without a tap callback', (
    tester,
  ) async {
    var longPresses = 0;
    await tester.pumpWidget(
      _app(
        SurgePressable(
          onLongPress: () => longPresses++,
          child: const SizedBox(width: 100, height: 48),
        ),
      ),
    );

    await tester.longPress(find.byType(SurgePressable));
    expect(longPresses, 1);
  });

  testWidgets('animated reveal preserves child while changing visibility', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const SurgeAnimatedReveal(
          visible: false,
          child: Text('advanced option'),
        ),
      ),
    );
    expect(find.text('advanced option'), findsNothing);
    await tester.pumpWidget(
      _app(
        const SurgeAnimatedReveal(
          visible: true,
          child: Text('advanced option'),
        ),
      ),
    );
    await tester.pump(SurgeMotion.container);
    expect(find.text('advanced option'), findsOneWidget);
  });

  testWidgets('Soft OS select pill opens popup and reports selection', (
    tester,
  ) async {
    var value = 'a';
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) => SizedBox(
            width: 180,
            child: SoftOsSelectPill<String>(
              value: value,
              semanticLabel: 'profile',
              items: const [
                SoftOsSelectItem(value: 'a', label: 'Alpha'),
                SoftOsSelectItem(value: 'b', label: 'Beta'),
              ],
              onChanged: (next) => setState(() => value = next),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(find.text('Beta'), findsOneWidget);
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    expect(find.text('Beta'), findsOneWidget);
  });

  testWidgets('status button exposes active icon and label', (tester) async {
    await tester.pumpWidget(
      _app(
        const SurgeStatusButton(
          isActive: true,
          activeLabel: 'Stop',
          inactiveLabel: 'Start',
          activeIcon: Icons.stop_rounded,
        ),
      ),
    );
    expect(find.text('Stop'), findsOneWidget);
    expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
  });
}
