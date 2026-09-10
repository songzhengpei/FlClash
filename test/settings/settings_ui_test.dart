import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/providers/settings_apply.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/services/settings/settings_apply_queue.dart';
import 'package:fl_clash/services/settings/settings_contract.dart';
import 'package:fl_clash/views/config/dns.dart';
import 'package:fl_clash/views/config/network.dart';
import 'package:fl_clash/widgets/settings_apply_status.dart';
import 'package:fl_clash/widgets/input.dart';
import 'package:fl_clash/widgets/surge/surge.dart';
import 'package:fl_clash/theme/typography/text_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Widget app(Widget child) {
  final textTheme = buildSlclashTextTheme();
  return MaterialApp(
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    theme: ThemeData(
      textTheme: textTheme,
      extensions: [
        SurgeTheme.light(),
        SurgeTypography.fromTextTheme(textTheme),
      ],
    ),
    home: Scaffold(body: child),
  );
}

class StatusStub extends SettingsApply {
  StatusStub(this.initial);
  final SettingsApplyStatus initial;
  int retries = 0;
  void publish(SettingsApplyStatus next) {
    state = next;
  }

  @override
  SettingsApplyStatus build() => initial;
  @override
  void retry() {
    retries++;
  }
}

void main() {
  for (final retry in [false, true]) {
    testWidgets('failure dialog shares About styling and returns $retry', (
      tester,
    ) async {
      bool? result;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            viewSizeProvider.overrideWithBuild((_, _) => const Size(400, 800)),
          ],
          child: app(
            Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showDialog<bool>(
                    context: context,
                    builder: (_) => const SettingsApplyFailureDialog(
                      message: 'Native recovery failed',
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byType(SurgeDialogActionRow), findsOneWidget);
      expect(find.byType(InputDecorator), findsOneWidget);
      expect(find.text('Native recovery failed'), findsOneWidget);
      await tester.tap(find.text(retry ? 'Retry' : 'Close'));
      await tester.pumpAndSettle();
      expect(result, retry);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('DNS hijacking is read-only and explains automatic capture', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(child: app(const DNSHijackingItem())),
    );
    expect(find.byType(Switch), findsNothing);
    expect(find.textContaining('Automatic'), findsOneWidget);
  });

  for (final source in DnsSettingsSource.values) {
    testWidgets('DNS preset edit gate matches $source', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dnsSettingsSourceProvider.overrideWith((ref) async => source),
          ],
          child: app(const DnsListView()),
        ),
      );
      await tester.pumpAndSettle();
      final gate = find
          .ancestor(
            of: find.byType(DnsOptions),
            matching: find.byType(IgnorePointer),
          )
          .first;
      expect(gate, findsOneWidget);
      expect(
        tester.widget<IgnorePointer>(gate).ignoring,
        source == DnsSettingsSource.subscription,
      );
      expect(find.byType(OverrideItem), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DnsListView)),
      );
      final before = container.read(patchClashConfigProvider).dns.enable;
      await tester.tap(find.byType(StatusItem), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(
        container.read(patchClashConfigProvider).dns.enable,
        source == DnsSettingsSource.subscription ? before : !before,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'feedback uses notifications, leaves page unchanged, and exposes retry',
    (tester) async {
      final stub = StatusStub(
        const SettingsApplyStatus(SettingsApplyPhase.idle),
      );
      final messages = <String>[];
      VoidCallback? retry;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsApplyProvider.overrideWith(() => stub),
            initProvider.overrideWithBuild((ref, _) => true),
          ],
          child: app(
            SettingsApplyFeedback(
              onMessage: (message, action) {
                messages.add(message);
                retry = action;
              },
              child: const Text('Page content'),
            ),
          ),
        ),
      );
      stub.publish(const SettingsApplyStatus(SettingsApplyPhase.applied));
      await tester.pump();
      expect(messages.last, 'Settings applied');
      expect(find.text('Settings applied'), findsNothing);
      expect(find.text('Page content'), findsOneWidget);
      stub.publish(
        const SettingsApplyStatus(
          SettingsApplyPhase.failed,
          error: 'restore failed: native unavailable',
        ),
      );
      await tester.pump();
      expect(messages.last, contains('restore failed'));
      retry!();
      expect(stub.retries, 1);
      stub.publish(
        const SettingsApplyStatus(SettingsApplyPhase.applying, reconnect: true),
      );
      await tester.pump();
      expect(messages.last, contains('briefly reconnect'));
    },
  );
}
