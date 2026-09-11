import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/manager/core_manager.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shouldCollectCoreLogs', () {
    test('collects logs on foreground logs page', () {
      expect(
        shouldCollectCoreLogs(
          appForeground: true,
          currentPageLabel: PageLabel.logs,
        ),
        isTrue,
      );
    });

    test('does not collect logs outside logs page', () {
      expect(
        shouldCollectCoreLogs(
          appForeground: true,
          currentPageLabel: PageLabel.dashboard,
        ),
        isFalse,
      );
    });

    test('does not collect logs in background', () {
      expect(
        shouldCollectCoreLogs(
          appForeground: false,
          currentPageLabel: PageLabel.logs,
        ),
        isFalse,
      );
    });
  });

  group('shouldCollectCoreRequests', () {
    test('collects request events only on foreground requests page', () {
      expect(
        shouldCollectCoreRequests(
          appForeground: true,
          currentPageLabel: PageLabel.requests,
        ),
        isTrue,
      );
    });

    test('does not collect request events outside requests page', () {
      expect(
        shouldCollectCoreRequests(
          appForeground: true,
          currentPageLabel: PageLabel.dashboard,
        ),
        isFalse,
      );
    });

    test('does not collect request events in background', () {
      expect(
        shouldCollectCoreRequests(
          appForeground: false,
          currentPageLabel: PageLabel.requests,
        ),
        isFalse,
      );
    });
  });

  group('core crash notifier', () {
    test('idle connected binder death still resets core, without a toast', () {
      expect(
        shouldHandleCoreCrash(
          coreConnected: true,
          hasProtectableSession: false,
        ),
        isTrue,
      );
      expect(
        shouldNotifyCoreCrash(
          hasProtectableSession: false,
          appResumed: true,
          message: 'Service disconnected',
        ),
        isFalse,
      );
    });

    test('running or paused session loss still notifies in foreground', () {
      expect(
        shouldNotifyCoreCrash(
          hasProtectableSession: true,
          appResumed: true,
          message: 'Service disconnected',
        ),
        isTrue,
      );
      expect(
        shouldNotifyCoreCrash(
          hasProtectableSession: true,
          appResumed: false,
          message: 'Service disconnected',
        ),
        isFalse,
      );
    });
  });
}
