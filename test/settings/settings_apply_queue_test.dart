import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/services/settings/settings_apply_queue.dart';
import 'package:fl_clash/services/settings/settings_runtime.dart';

void main() {
  const initial = Config(currentProfileId: 1, themeProps: defaultThemeProps);
  for (final running in [false, true]) {
    test('profile switch is silent while running=$running', () {
      fakeAsync((clock) {
        var config = initial;
        final phases = <SettingsApplyPhase>[];
        var calls = 0;
        final queue = SettingsApplyQueue(
          baseline: initial,
          read: () => config,
          canApply: () => running,
          apply: (_, _, _) async {
            calls++;
          },
          restorePreferences: (_) async {},
          onStatus: (status) => phases.add(status.phase),
        );
        config = initial.copyWith(currentProfileId: 2);
        queue.change(initial, config);
        // The existing profile owner acknowledges the immediate application.
        queue.acknowledged(config);
        clock.elapse(const Duration(seconds: 2));
        expect(phases, everyElement(SettingsApplyPhase.idle));
        expect(calls, 0);
        // Real saved edits while stopped must still report deferred.
        final previous = config;
        config = config.copyWith.patchClashConfig.dns(preferH3: true);
        queue.change(previous, config);
        expect(
          phases.last,
          running ? SettingsApplyPhase.pending : SettingsApplyPhase.deferred,
        );
        queue.dispose();
      });
    });
  }
  test(
    'reload debounce merges a subsequent hot change into one transaction',
    () {
      fakeAsync((clock) {
        var config = initial;
        final applied = <Config>[];
        final queue = SettingsApplyQueue(
          baseline: initial,
          read: () => config,
          canApply: () => true,
          apply: (c, kind, valid) async {
            expect(valid(), true);
            applied.add(c);
          },
          restorePreferences: (c) async {
            config = c;
          },
          onStatus: (_) {},
        );
        void edit(Config next) {
          final old = config;
          config = next;
          queue.change(old, next);
        }

        edit(config.copyWith.patchClashConfig.dns(preferH3: true));
        clock.elapse(const Duration(milliseconds: 800));
        edit(config.copyWith.patchClashConfig(allowLan: true));
        clock.elapse(const Duration(milliseconds: 999));
        expect(applied, isEmpty);
        clock.elapse(const Duration(milliseconds: 1));
        clock.flushMicrotasks();
        expect(applied, hasLength(1));
        expect(applied.single.patchClashConfig.allowLan, true);
        queue.dispose();
      });
    },
  );
  test('failure restores failed values while preserving a newer edit', () {
    fakeAsync((clock) {
      var config = initial;
      final completion = Completer<void>();
      var calls = 0;
      final queue = SettingsApplyQueue(
        baseline: initial,
        read: () => config,
        canApply: () => true,
        apply: (_, _, _) {
          calls++;
          return calls == 1 ? completion.future : Future.value();
        },
        restorePreferences: (c) async {
          config = c;
        },
        onStatus: (_) {},
      );
      var old = config;
      config = config.copyWith.patchClashConfig.dns(preferH3: true);
      queue.change(old, config);
      clock.elapse(const Duration(seconds: 1));
      old = config;
      config = config.copyWith.patchClashConfig.dns(nameserver: ['9.9.9.9']);
      queue.change(old, config);
      completion.completeError(const SettingsApplyFailure('invalid'));
      clock.flushMicrotasks();
      expect(config.patchClashConfig.dns.preferH3, false);
      expect(config.patchClashConfig.dns.nameserver, ['9.9.9.9']);
      clock.elapse(const Duration(seconds: 1));
      clock.flushMicrotasks();
      expect(calls, 2);
      queue.dispose();
    });
  });
  test('stop or pause cancels pending work and never starts a VPN', () {
    fakeAsync((clock) {
      var config = initial;
      var running = true;
      var calls = 0;
      final queue = SettingsApplyQueue(
        baseline: initial,
        read: () => config,
        canApply: () => running,
        apply: (_, _, _) async {
          calls++;
        },
        restorePreferences: (_) async {},
        onStatus: (_) {},
      );
      config = initial.copyWith.patchClashConfig.dns(preferH3: true);
      queue.change(initial, config);
      running = false;
      queue.sessionChanged();
      clock.elapse(const Duration(seconds: 3));
      expect(calls, 0);
      queue.dispose();
    });
  });
  test('a switched profile cannot receive rollback from the old attempt', () {
    fakeAsync((clock) {
      var config = initial;
      var restores = 0;
      final completion = Completer<void>();
      final queue = SettingsApplyQueue(
        baseline: initial,
        read: () => config,
        canApply: () => true,
        apply: (_, _, _) => completion.future,
        restorePreferences: (_) async {
          restores++;
        },
        onStatus: (_) {},
      );
      config = initial.copyWith.patchClashConfig.dns(preferH3: true);
      queue.change(initial, config);
      clock.elapse(const Duration(seconds: 1));
      final old = config;
      config = config.copyWith(currentProfileId: 2);
      queue.change(old, config);
      completion.completeError(const SettingsApplyFailure('old failure'));
      clock.flushMicrotasks();
      expect(restores, 0);
      queue.dispose();
    });
  });
  test('unchanged initialization does not apply; failure does not loop', () {
    fakeAsync((clock) {
      var config = initial;
      var calls = 0;
      final queue = SettingsApplyQueue(
        baseline: initial,
        read: () => config,
        canApply: () => true,
        apply: (_, _, _) async {
          calls++;
          throw const SettingsApplyFailure('failed');
        },
        restorePreferences: (c) async {
          config = c;
        },
        onStatus: (_) {},
      );
      queue.change(initial, initial);
      clock.elapse(const Duration(seconds: 2));
      expect(calls, 0);
      config = initial.copyWith.patchClashConfig.dns(preferH3: true);
      queue.change(initial, config);
      clock.elapse(const Duration(seconds: 1));
      clock.flushMicrotasks();
      clock.elapse(const Duration(minutes: 1));
      expect(calls, 1);
      expect(config, initial);
      queue.dispose();
    });
  });
  test('same-value newer edit survives failed attempt (ABA)', () {
    fakeAsync((clock) {
      var config = initial;
      final completion = Completer<void>();
      final queue = SettingsApplyQueue(
        baseline: initial,
        read: () => config,
        canApply: () => true,
        apply: (_, _, _) => completion.future,
        restorePreferences: (c) async {
          config = c;
        },
        onStatus: (_) {},
      );
      void edit(bool value) {
        final old = config;
        config = config.copyWith.patchClashConfig.dns(preferH3: value);
        queue.change(old, config);
      }

      edit(true);
      clock.elapse(const Duration(seconds: 1));
      edit(false);
      edit(true);
      completion.completeError(const SettingsApplyFailure('failed'));
      clock.flushMicrotasks();
      expect(config.patchClashConfig.dns.preferH3, true);
      queue.dispose();
    });
  });
  test('saved editor changes merge, restore once, and retry explicitly', () {
    fakeAsync((clock) {
      var calls = 0;
      var restored = 0;
      final phases = <SettingsApplyPhase>[];
      final queue = SettingsApplyQueue(
        baseline: initial,
        read: () => initial,
        canApply: () => true,
        apply: (_, _, _) async {
          calls++;
          if (calls == 1)
            throw const SettingsApplyFailure('failed', restoreError: 'offline');
        },
        restorePreferences: (_) async {},
        onStatus: (s) => phases.add(s.phase),
      );
      queue.savedEdit(() async {
        restored++;
      });
      clock.elapse(const Duration(milliseconds: 800));
      queue.savedEdit(() async {
        restored++;
      });
      clock.elapse(const Duration(milliseconds: 999));
      expect(calls, 0);
      clock.elapse(const Duration(milliseconds: 1));
      clock.flushMicrotasks();
      expect(calls, 1);
      expect(restored, 2);
      expect(phases.last, SettingsApplyPhase.failed);
      clock.elapse(const Duration(minutes: 1));
      expect(calls, 1);
      queue.retry();
      clock.elapse(const Duration(seconds: 1));
      clock.flushMicrotasks();
      expect(calls, 2);
      expect(phases.last, SettingsApplyPhase.applied);
      queue.dispose();
    });
  });
  test(
    'core acknowledgement cannot swallow pending settings on profile switch',
    () {
      fakeAsync((clock) {
        var config = initial;
        final applied = <Config>[];
        final queue = SettingsApplyQueue(
          baseline: initial,
          read: () => config,
          canApply: () => true,
          apply: (c, _, _) async {
            applied.add(c);
          },
          restorePreferences: (_) async {},
          onStatus: (_) {},
        );
        config = config.copyWith.vpnProps(ipv6: true);
        queue.change(initial, config);
        final previous = config;
        config = config.copyWith(currentProfileId: 2);
        queue.change(previous, config);
        queue.acknowledged(initial.copyWith(currentProfileId: 2));
        clock.elapse(const Duration(seconds: 1));
        clock.flushMicrotasks();
        expect(applied.single.currentProfileId, 2);
        expect(applied.single.vpnProps.ipv6, true);
        queue.dispose();
      });
    },
  );
  test('explicit start acknowledges saved edits without a duplicate reload', () {
    fakeAsync((clock) {
      var running = false; var calls = 0;
      final queue = SettingsApplyQueue(baseline: initial, read: () => initial,
        canApply: () => running, apply: (_, _, _) async { calls++; },
        restorePreferences: (_) async {}, onStatus: (_) {});
      queue.savedEdit(() async {});
      final fence = settingsSavedEditRevision;
      running = true;
      queue.acknowledged(initial, savedRevision: fence);
      queue.sessionChanged();
      clock.elapse(const Duration(seconds: 2));
      expect(calls, 0);
      queue.savedEdit(() async {});
      queue.acknowledged(initial, savedRevision: fence);
      clock.elapse(const Duration(seconds: 1)); clock.flushMicrotasks();
      expect(calls, 1);
      queue.dispose();
    });
  });

}
