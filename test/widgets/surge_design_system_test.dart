import 'dart:io';
import 'dart:ui' show Tristate;
import 'package:fl_clash/widgets/app_bar/sl_app_bar_action.dart';
import 'package:fl_clash/widgets/surge/surge.dart';
import 'package:fl_clash/theme/static_theme.dart';
import 'package:fl_clash/theme/typography/text_theme.dart';
import 'package:fl_clash/widgets/inherited.dart';
import 'package:fl_clash/widgets/list.dart';
import 'package:fl_clash/widgets/sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

ThemeData _theme(SurgeTheme surge) {
  final textTheme = buildSlclashTextTheme();
  final typography = SurgeTypography.fromTextTheme(textTheme);
  return ThemeData(textTheme: textTheme, extensions: [surge, typography]);
}

SurgeTypography _typography() =>
    SurgeTypography.fromTextTheme(buildSlclashTextTheme());

Widget _host(Widget child, {SurgeTheme? surge}) {
  return MaterialApp(
    theme: _theme(surge ?? SurgeTheme.light()),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  group('SurgeTheme semantic tokens', () {
    test('retain the established dashboard palette in the light theme', () {
      final surge = SurgeTheme.light();

      expect(surge.semantic.dashboardDynamicActive, const Color(0xFFA06B3B));
      expect(surge.semantic.dashboardActiveGreen, const Color(0xFF5BA66A));
      expect(surge.semantic.paused, const Color(0xFFDC851B));
      expect(surge.semantic.state.profileActive, const Color(0xFF34C759));
      expect(surge.semantic.latencyGood, const Color(0xFFADDFAD));
      expect(surge.semantic.latencyMedium, const Color(0xFFF1C892));
      expect(surge.semantic.latencyBad, const Color(0xFFFFBBBD));
      expect(surge.semantic.statusLightPaused, const Color(0xFFFF9500));
      expect(
        surge.semantic.profileSelectionBorderFixed,
        const Color(0xFFD8DAE0),
      );
      final typography = _typography();
      expect(typography.chartLabel.fontSize, 10);
      expect(typography.metric.fontSize, 14);
      expect(typography.metric.fontWeight, FontWeight.w600);
      expect(typography.compactMetric.fontSize, 13);
      expect(typography.compactMetric.fontWeight, FontWeight.w400);
      expect(typography.supporting.fontWeight, FontWeight.w400);
      expect(typography.body.fontSize, 15);
      expect(surge.controls.minimumTapExtent, 44);
      expect(surge.controls.actionTapExtent, 48);
      expect(surge.controls.actionVisualHeight, 34);
      expect(surge.controls.actionVisualWidth, 40);
      expect(surge.controls.compactActionVisualWidth, 38);
      expect(surge.controls.actionDockButtonWidth, 44);
      expect(surge.controls.shortTextActionVisualWidth, 55);
      expect(surge.controls.shortTextActionTapWidth, 56);
      expect(surge.controls.dockButtonWidth, 36);
      expect(surge.opacity.selectedSurface, 0.045);
      expect(surge.opacity.actionForeground, 0.96);
      expect(surge.opacity.actionDisabledForeground, 0.46);
      expect(surge.radii.menuRow, 12);
      expect(surge.radii.input, 10);
      expect(surge.radii.metric, 10);
      expect(surge.radii.chart, 4);
      expect(surge.radii.compact, 8);
      expect(surge.radii.segmentedIndicator, 13);
      expect(surge.radii.button, 999);
    });

    testWidgets('semantic typography extension reads the active theme', (
      tester,
    ) async {
      late TextStyle style;
      final surge = SurgeTheme.dark();

      await tester.pumpWidget(
        MaterialApp(
          home: Theme(
            data: _theme(surge),
            child: Builder(
              builder: (context) {
                style = context.typography.cardTitle;
                return const SizedBox();
              },
            ),
          ),
        ),
      );

      expect(style.color, isNull);
      expect(style.fontSize, 16);
      expect(style.fontWeight, FontWeight.w500);
    });

    test('retain dark and dynamic-color mappings without changing tokens', () {
      final dark = SurgeTheme.dark();
      final dynamicScheme = ColorScheme.fromSeed(
        seedColor: const Color(0xFF6750A4),
        brightness: Brightness.dark,
      );
      final dynamic = SurgeTheme.fromColorScheme(dynamicScheme);

      expect(dark.background, const Color(0xFF08090B));
      expect(dark.card, const Color(0xFF17191D));
      expect(dark.elevatedCard, const Color(0xFF202328));
      expect(dark.primary, const Color(0xFF67B0FF));
      expect(_typography().cardTitle.color, isNull);
      expect(dynamic.background, dynamicScheme.surface);
      expect(dynamic.card, dynamicScheme.surfaceContainerLow);
      expect(dynamic.primary, dynamicScheme.primary);
      expect(dynamic.textPrimary, dynamicScheme.onSurface);
      expect(dynamic.semantic.error, const Color(0xFFFF453A));
      expect(dynamic.semantic.state.profileActive, dynamic.green);
      expect(dynamic.controls.minimumTapExtent, 44);
      expect(SurgeMotion.press, const Duration(milliseconds: 110));
      expect(SurgeMotion.container, const Duration(milliseconds: 220));
    });
  });

  group('Surge reusable controls', () {
    testWidgets('custom switch consumes centralized active state colors', (
      tester,
    ) async {
      for (final spec in StaticThemeSpec.values) {
        final surge = SurgeTheme.fromColors(
          spec.colors,
          stateColors: spec.stateColors,
        );
        await tester.pumpWidget(
          _host(SurgeSwitch(value: true, onChanged: (_) {}), surge: surge),
        );
        await tester.pumpAndSettle();

        final decorations = tester
            .widgetList<Container>(find.byType(Container))
            .map((widget) => widget.decoration)
            .whereType<BoxDecoration>()
            .toList();
        expect(
          decorations.any(
            (decoration) =>
                decoration.color == surge.semantic.state.toggleActive,
          ),
          isTrue,
        );
        expect(
          decorations.any(
            (decoration) =>
                decoration.color == surge.semantic.state.onToggleActive,
          ),
          isTrue,
        );
      }
    });

    testWidgets('bottom navigation retains the mainline selected capsule', (
      tester,
    ) async {
      for (final spec in StaticThemeSpec.values) {
        final surge = SurgeTheme.fromColors(
          spec.colors,
          stateColors: spec.stateColors,
        );
        await tester.pumpWidget(
          _host(
            SizedBox(
              width: 360,
              height: 100,
              child: SurgeBottomNav(
                currentIndex: 0,
                items: const [
                  SurgeBottomNavItem(
                    icon: SurgeIcons.dashboardFilled,
                    iconOutlined: SurgeIcons.dashboard,
                    label: '仪表盘',
                  ),
                  SurgeBottomNavItem(
                    icon: SurgeIcons.proxiesFilled,
                    iconOutlined: SurgeIcons.proxiesOutlined,
                    label: '代理',
                  ),
                ],
                onTap: (_) {},
              ),
            ),
            surge: surge,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(AnimatedPositioned), findsOneWidget);
        expect(
          tester.widget<Icon>(find.byIcon(SurgeIcons.dashboardFilled)).color,
          surge.primary,
        );
        expect(
          tester.widget<Icon>(find.byIcon(SurgeIcons.proxiesOutlined)).color,
          surge.textSecondary,
        );
        final navDecoration = tester
            .widgetList<DecoratedBox>(find.byType(DecoratedBox))
            .map((widget) => widget.decoration)
            .whereType<BoxDecoration>()
            .singleWhere(
              (decoration) =>
                  decoration.color ==
                  Color.alphaBlend(surge.navBar, surge.background),
            );
        expect(navDecoration.border!.top.color, surge.separator);
      }
    });

    testWidgets('adaptive sheet can align its app bar and body surface', (
      tester,
    ) async {
      const surface = Color(0xFF123456);
      await tester.pumpWidget(
        _host(
          const SizedBox(
            height: 320,
            child: SheetProvider(
              type: SheetType.bottomSheet,
              child: AdaptiveSheetScaffold(
                title: 'Provider',
                surfaceColor: surface,
                appBarActions: [
                  SlAppBarIconAction(icon: SurgeIcons.info, tooltip: 'Info'),
                ],
                body: ColoredBox(color: surface),
              ),
            ),
          ),
        ),
      );

      expect(
        tester.widget<AppBar>(find.byType(AppBar)).backgroundColor,
        surface,
      );
      expect(
        tester
            .widgetList<ColoredBox>(find.byType(ColoredBox))
            .where((widget) => widget.color == surface),
        hasLength(2),
      );
      final sheetActionDecorations = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .map((widget) => widget.decoration)
          .whereType<BoxDecoration>()
          .where((decoration) => decoration.color == surface);
      expect(sheetActionDecorations, hasLength(2));
    });

    testWidgets('list surface keeps the established card geometry', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const SizedBox(
            width: 280,
            child: SurgeListSurface(child: SizedBox(height: 44)),
          ),
        ),
      );

      final card = tester.widget<SurgeCard>(find.byType(SurgeCard));
      expect(card.padding, EdgeInsets.zero);
      expect(card.borderRadius, 18);
      expect(card.shadow, isFalse);
    });

    testWidgets('Soft OS actions keep their established tap targets', (
      tester,
    ) async {
      var actionTaps = 0;
      var iconTaps = 0;

      await tester.pumpWidget(
        _host(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SoftOsActionButton(
                icon: SurgeIcons.confirm,
                onPressed: () => actionTaps += 1,
              ),
              SoftOsIconButton(
                icon: SurgeIcons.close,
                onPressed: () => iconTaps += 1,
              ),
            ],
          ),
        ),
      );

      final actionContext = tester.element(find.byType(SoftOsActionButton));
      final surge = SurgeTheme.of(actionContext);
      final metrics = SoftOsMetrics.of(actionContext);
      final actionTarget = metrics.tap(surge.controls.actionTapExtent);
      final iconTarget = metrics.tap(surge.controls.iconButtonTapExtent);
      expect(
        tester.getSize(find.byType(SoftOsActionButton)),
        Size.square(actionTarget),
      );
      expect(
        tester.getSize(find.byType(SoftOsIconButton)),
        Size.square(iconTarget),
      );
      expect(
        actionTarget,
        greaterThanOrEqualTo(surge.controls.minimumTapExtent),
      );
      expect(iconTarget, greaterThanOrEqualTo(surge.controls.minimumTapExtent));
      await tester.tap(find.byType(SoftOsActionButton));
      await tester.tap(find.byType(SoftOsIconButton));
      expect(actionTaps, 1);
      expect(iconTaps, 1);
    });

    testWidgets('app-bar action template is scoped to its capsule icons', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SoftOsAppBarActionTemplate(
                child: SoftOsActionButton(
                  icon: SurgeIcons.search,
                  onPressed: () {},
                ),
              ),
              SoftOsActionButton(icon: SurgeIcons.search, onPressed: () {}),
            ],
          ),
        ),
      );

      final icons = tester.widgetList<Icon>(find.byIcon(SurgeIcons.search));
      final templateContext = tester.element(
        find.byType(SoftOsAppBarActionTemplate),
      );
      final metrics = SoftOsMetrics.of(templateContext);
      expect(icons.map((icon) => icon.size), [
        metrics.value(18),
        metrics.value(16),
      ]);
    });

    testWidgets('selectable rows preserve selected semantics and callbacks', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      var taps = 0;

      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 280,
            child: SurgeSelectableRow(
              selected: true,
              presentation: SurgeSelectionPresentation.list,
              onTap: () => taps += 1,
              child: const SizedBox(
                height: 44,
                child: Center(child: Text('节点 A')),
              ),
            ),
          ),
        ),
      );

      expect(tester.getSize(find.byType(SurgeSelectableRow)).height, 44);
      final semanticsData = tester
          .getSemantics(find.byType(SurgeSelectableRow))
          .getSemanticsData();
      expect(semanticsData.label, '节点 A');
      expect(semanticsData.flagsCollection.isButton, isTrue);
      expect(semanticsData.flagsCollection.isSelected, Tristate.isTrue);
      expect(semanticsData.hasAction(SemanticsAction.tap), isTrue);

      await tester.tap(find.text('节点 A'));
      expect(taps, 1);
      semantics.dispose();
    });

    testWidgets('dual selector preserves its targets and disabled state', (
      tester,
    ) async {
      var secondTaps = 0;

      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 320,
            child: SurgeDualSelectBar(
              firstLabel: '规则模式',
              secondLabel: '当前节点',
              onFirstTap: null,
              onSecondTap: () => secondTaps += 1,
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              radius: 22,
              itemRadius: 18,
              dividerHeight: 20,
              dividerMargin: 4,
              labelStyle: _typography().rowTitle,
              iconSize: 16,
              labelGap: 4,
              itemVerticalInset: 3,
            ),
          ),
        ),
      );

      expect(tester.getSize(find.byType(SurgeDualSelectBar)).height, 44);
      final barRect = tester.getRect(find.byType(SurgeDualSelectBar));
      final firstTarget = find.byType(SurgePressable).at(0);
      final firstOverlay = find.descendant(
        of: firstTarget,
        matching: find.byType(ColoredBox),
      );
      final firstOverlayRect = tester.getRect(firstOverlay);
      expect(firstOverlayRect.left, closeTo(barRect.left + 4, 0.01));
      expect(firstOverlayRect.top, closeTo(barRect.top + 3, 0.01));
      expect(firstOverlayRect.bottom, closeTo(barRect.bottom - 3, 0.01));

      await tester.tap(find.text('规则模式'));
      await tester.tap(find.text('当前节点'));
      expect(secondTaps, 1);
    });

    testWidgets(
      'status pill publishes its label and blocks taps while loading',
      (tester) async {
        var taps = 0;

        await tester.pumpWidget(
          _host(
            SoftOsStatusPill(
              accentColor: SurgeTheme.light().primary,
              loading: true,
              semanticLabel: '同步状态',
              onPressed: () => taps += 1,
              child: const Text('正在切换'),
            ),
          ),
        );

        expect(find.bySemanticsLabel(RegExp('同步状态')), findsOneWidget);
        await tester.tap(find.text('正在切换'));
        expect(taps, 0);

        await tester.pumpWidget(
          _host(
            SoftOsStatusPill(
              accentColor: SurgeTheme.light().primary,
              semanticLabel: '同步状态',
              onPressed: () => taps += 1,
              child: const Text('已就绪'),
            ),
          ),
        );
        await tester.tap(find.text('已就绪'));
        expect(taps, 1);
      },
    );

    testWidgets('delay pill retains test, loading, value, and timeout states', (
      tester,
    ) async {
      var taps = 0;

      Future<void> pumpDelay(int? delay) {
        return tester.pumpWidget(
          _host(SurgeDelayPill(delay: delay, onTap: () => taps += 1)),
        );
      }

      await pumpDelay(null);
      expect(find.text('Test'), findsOneWidget);
      await tester.tap(find.byType(SurgeDelayPill));
      expect(taps, 1);

      await pumpDelay(0);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await pumpDelay(124);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('124 ms'), findsOneWidget);

      await pumpDelay(-1);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Timeout'), findsOneWidget);
    });

    testWidgets('sliding segmented control reports the selected item', (
      tester,
    ) async {
      var selected = 'rule';
      await tester.pumpWidget(
        MaterialApp(
          theme: _theme(SurgeTheme.light()),
          themeMode: ThemeMode.light,
          home: StatefulBuilder(
            builder: (context, setState) {
              final surge = SurgeTheme.of(context);
              return SurgeSlidingSegmentedControl<String>(
                value: selected,
                items: const [
                  SurgeSegmentedItem(value: 'rule', label: '规则'),
                  SurgeSegmentedItem(value: 'global', label: '全局'),
                ],
                onChanged: (value) => setState(() => selected = value),
                height: 34,
                padding: const EdgeInsets.all(3),
                backgroundColor: surge.fill,
                selectedSurfaceColor: surge.elevatedCard,
                selectedColor: surge.primary,
                unselectedColor: surge.textSecondary,
                outerRadius: 26,
                selectedRadius: 24,
                labelStyle: _typography().rowTitle,
              );
            },
          ),
        ),
      );

      await tester.tap(find.text('全局'));
      await tester.pumpAndSettle();
      expect(selected, 'global');
    });
  });

  test(
    'design-system source contract keeps icons and dashboard palette central',
    () {
      final sourceFiles = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'));
      final directIcons = RegExp(r'(?<!Surge)Icons\.');

      for (final file in sourceFiles) {
        if (file.path.replaceAll('\\', '/').endsWith('/common/icons.dart')) {
          continue;
        }
        expect(
          directIcons.hasMatch(file.readAsStringSync()),
          isFalse,
          reason: '${file.path} must use SurgeIcons',
        );
      }

      expect(
        File('lib/views/dashboard/widgets/dashboard_palette.dart').existsSync(),
        isFalse,
      );
      final dashboard = File(
        'lib/views/dashboard/widgets/surge_dashboard_hero.dart',
      ).readAsStringSync();
      expect(dashboard.contains('dashboard_palette'), isFalse);

      final themeSource = File(
        'lib/widgets/surge/surge_theme_extension.dart',
      ).readAsStringSync();
      expect(themeSource, isNot(contains('class SurgeTextStyles')));
      expect(themeSource, isNot(contains('SurgeTypography typography')));

      final bottomNav = File(
        'lib/widgets/surge/surge_bottom_nav.dart',
      ).readAsStringSync();
      expect(bottomNav, contains('AnimatedPositioned'));
      expect(bottomNav, contains('selected ? surge.primary'));

      final profiles = File(
        'lib/views/profiles/profiles.dart',
      ).readAsStringSync();
      expect(profiles, contains('color = surge.semantic.state.profileActive'));

      final providers = File(
        'lib/views/proxies/providers.dart',
      ).readAsStringSync();
      expect(providers, contains('surfaceColor: surge.background'));

      final application = File('lib/application.dart').readAsStringSync();
      expect(application, contains('semantic.state.toggleActive'));
      expect(application, contains('semantic.state.onToggleActive'));

      expect(dashboard, contains('semantic.state.heroStart'));
      expect(dashboard, contains('semantic.state.heroPause'));
      expect(dashboard, contains('semantic.state.heroStop'));
      expect(dashboard, contains('semantic.state.onHeroAction'));

      final dashboardCard = File(
        'lib/views/dashboard/widgets/surge_dashboard_card.dart',
      ).readAsStringSync();
      final overviewCard = File(
        'lib/views/dashboard/widgets/network_overview_card.dart',
      ).readAsStringSync();
      expect(
        dashboardCard,
        contains('Icon(icon, size: 17, color: iconColor ?? surge.primary)'),
      );
      expect(
        overviewCard,
        contains('color: isStart ? surge.primary : surge.inactive'),
      );
      final networkDetection = File(
        'lib/views/dashboard/widgets/network_detection.dart',
      ).readAsStringSync();
      expect(
        networkDetection,
        contains('final isStart = ref.watch(isStartProvider)'),
      );
      expect(
        networkDetection,
        contains('iconColor: isStart ? surge.primary : surge.inactive'),
      );
    },
  );
}
