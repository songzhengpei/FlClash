import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/services/mihomo_config/runtime_config_commit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';

void main() {
  group('runtime activation authority', () {
    test('applied and unchanged are the only confirming setup outcomes', () {
      expect(
        setupOutcomeConfirmsRuntimeActivation(SetupConfigOutcome.applied),
        isTrue,
      );
      expect(
        setupOutcomeConfirmsRuntimeActivation(SetupConfigOutcome.unchanged),
        isTrue,
      );
      expect(
        setupOutcomeConfirmsRuntimeActivation(SetupConfigOutcome.failed),
        isFalse,
      );
      expect(
        setupOutcomeConfirmsRuntimeActivation(SetupConfigOutcome.superseded),
        isFalse,
      );
    });
  });

  group('runtime projection scheduling', () {
    test('production schedules preheat only after setup commit returns', () {
      final source = File('lib/providers/action.dart').readAsStringSync();
      final start = source.indexOf(
        'Future<SetupConfigOutcome> _applyProfileOutcome',
      );
      final end = source.indexOf(
        'Future<void> applyProfileForDisplay',
        start,
      );
      final method = source.substring(start, end);
      final commitAwait = method.indexOf('final outcome = await _setupConfig');
      final releaseTrace = method.indexOf('runtime_config_commit_released');
      final preheatSchedule = method.indexOf('schedulePostActivationPreheat');

      expect(commitAwait, greaterThanOrEqualTo(0));
      expect(releaseTrace, greaterThan(commitAwait));
      expect(preheatSchedule, greaterThan(releaseTrace));
      expect(
        method.substring(commitAwait, releaseTrace),
        isNot(contains('preheatComputedGroups')),
      );
    });

    test('commit completes before a blocked post-commit preheat', () async {
      final owner = RuntimeConfigCommitOwner();
      final preheatStarted = Completer<void>();
      final releasePreheat = Completer<void>();
      final generation = owner.beginRequest();

      final commit = owner.commit(
        generation: generation,
        transaction: (_) async {},
      );
      await commit;
      final preheat = Future<void>(() async {
        preheatStarted.complete();
        await releasePreheat.future;
      });
      await preheatStarted.future;

      final nextGeneration = owner.beginRequest();
      final nextCommit = owner.commit(
        generation: nextGeneration,
        transaction: (_) async {},
      );
      await expectLater(
        nextCommit.timeout(const Duration(seconds: 1)),
        completion(RuntimeConfigCommitOutcome.committed),
      );

      releasePreheat.complete();
      await preheat;
    });

    test('running refresh coalesces multiple requests into one trailing run', () async {
      var active = true;
      var dirty = false;
      var calls = 0;
      var trailing = 0;
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();

      bool takeDirty() {
        final value = dirty;
        dirty = false;
        return value;
      }

      final loop = runTrailingRuntimeRefreshLoop(
        isActive: () => active,
        takeDirty: takeDirty,
        refresh: () async {
          calls++;
          if (calls == 1) {
            firstStarted.complete();
            await releaseFirst.future;
          }
        },
        onTrailing: () => trailing++,
      );
      await firstStarted.future;
      dirty = true;
      dirty = true;
      releaseFirst.complete();
      await loop;

      expect(calls, 2);
      expect(trailing, 1);
      active = false;
    });

    test('stale identity suppresses its dirty trailing refresh', () async {
      var active = true;
      var dirty = false;
      var calls = 0;
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();

      final loop = runTrailingRuntimeRefreshLoop(
        isActive: () => active,
        takeDirty: () {
          final value = dirty;
          dirty = false;
          return value;
        },
        refresh: () async {
          calls++;
          firstStarted.complete();
          await releaseFirst.future;
        },
      );
      await firstStarted.future;
      dirty = true;
      active = false;
      releaseFirst.complete();
      await loop;

      expect(calls, 1);
    });

    test('old A dirty state cannot run in a new A epoch', () async {
      const oldA = RuntimeProfileIdentity(profileId: 1, epoch: 1);
      const newA = RuntimeProfileIdentity(profileId: 1, epoch: 3);
      var activeIdentity = oldA;
      var dirty = false;
      var calls = 0;
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();

      final loop = runTrailingRuntimeRefreshLoop(
        isActive: () => activeIdentity == oldA,
        takeDirty: () {
          final value = dirty;
          dirty = false;
          return value;
        },
        refresh: () async {
          calls++;
          firstStarted.complete();
          await releaseFirst.future;
        },
      );
      await firstStarted.future;
      dirty = true;
      activeIdentity = newA;
      releaseFirst.complete();
      await loop;

      expect(calls, 1);
    });

    test('provider projection read is singleflight per identity and name', () async {
      const identity = RuntimeProfileIdentity(profileId: 1, epoch: 1);
      final singleflight = RuntimeProviderProjectionSingleflight<String>();
      final fetchResult = Completer<String>();
      final published = <String?>[];
      var reads = 0;

      Future<String?> refresh() => singleflight.refresh(
        identity: identity,
        providerName: 'P',
        isActive: (_) => true,
        fetch: () {
          reads++;
          return fetchResult.future;
        },
        publish: published.add,
      );

      final updateCompletion = refresh();
      final loadedEvent = refresh();
      fetchResult.complete('mihomo-current');

      expect(await updateCompletion, 'mihomo-current');
      expect(await loadedEvent, 'mihomo-current');
      expect(reads, 1);
      expect(published, ['mihomo-current']);
    });

    test('stale provider projection is not published', () async {
      const identity = RuntimeProfileIdentity(profileId: 1, epoch: 1);
      final singleflight = RuntimeProviderProjectionSingleflight<String>();
      final fetchResult = Completer<String>();
      final published = <String?>[];
      var active = true;

      final refresh = singleflight.refresh(
        identity: identity,
        providerName: 'P',
        isActive: (_) => active,
        fetch: () => fetchResult.future,
        publish: published.add,
      );
      active = false;
      fetchResult.complete('stale-A');

      expect(await refresh, isNull);
      expect(published, isEmpty);
    });
  });

  group('runtime mutation identity', () {
    test(
      'provider update captured under A does not dispatch under B',
      () async {
        const identity = RuntimeProfileIdentity(profileId: 1, epoch: 0);
        var coreCalls = 0;

        final result = await runRuntimeMutationIfCurrent(
          identity: identity,
          isCurrent: (_) => false,
          mutation: () async {
            coreCalls++;
            return '';
          },
        );

        expect(result.current, isFalse);
        expect(coreCalls, 0);
      },
    );

    test(
      'provider completion from A cannot publish same-name DTO to B',
      () async {
        const identity = RuntimeProfileIdentity(profileId: 1, epoch: 0);
        var currentProfileId = 1;
        var currentEpoch = 0;
        var publications = 0;
        final completion = Completer<String>();

        final resultFuture = runRuntimeMutationIfCurrent(
          identity: identity,
          isCurrent: (value) => isRuntimeProfileIdentityCurrent(
            identity: value,
            currentProfileId: currentProfileId,
            currentEpoch: currentEpoch,
          ),
          mutation: () => completion.future,
        );
        currentProfileId = 2;
        currentEpoch = 1;
        completion.complete('same-provider');
        final result = await resultFuture;
        if (result.current) publications++;

        expect(publications, 0);
      },
    );

    test(
      'side-load captured before picker cannot dispatch after switch',
      () async {
        const identity = RuntimeProfileIdentity(profileId: 1, epoch: 0);
        var currentProfileId = 1;
        var currentEpoch = 0;
        var sideLoadCalls = 0;
        final picker = Completer<void>();

        final operation = () async {
          await picker.future;
          return runRuntimeMutationIfCurrent(
            identity: identity,
            isCurrent: (value) => isRuntimeProfileIdentityCurrent(
              identity: value,
              currentProfileId: currentProfileId,
              currentEpoch: currentEpoch,
            ),
            mutation: () async {
              sideLoadCalls++;
              return '';
            },
          );
        }();
        currentProfileId = 2;
        currentEpoch = 1;
        picker.complete();

        expect((await operation).current, isFalse);
        expect(sideLoadCalls, 0);
      },
    );

    test('manual delay completion from old A epoch is discarded', () async {
      const identity = RuntimeProfileIdentity(profileId: 1, epoch: 0);
      var currentEpoch = 0;
      final completion = Completer<Delay>();

      final resultFuture = runRuntimeMutationIfCurrent(
        identity: identity,
        isCurrent: (value) => isRuntimeProfileIdentityCurrent(
          identity: value,
          currentProfileId: 1,
          currentEpoch: currentEpoch,
        ),
        mutation: () => completion.future,
      );
      currentEpoch = 2;
      completion.complete(const Delay(url: 'u', name: 'x', value: 80));

      expect((await resultFuture).current, isFalse);
    });
  });

  group('UI stats timer desired state', () {
    const cases =
        <
          ({
            String name,
            bool foreground,
            bool running,
            bool smartPaused,
            bool expected,
          })
        >[
          (
            name: 'A RUNNING foreground',
            foreground: true,
            running: true,
            smartPaused: false,
            expected: true,
          ),
          (
            name: 'B RUNNING background',
            foreground: false,
            running: true,
            smartPaused: false,
            expected: false,
          ),
          (
            name: 'C background session reconcile',
            foreground: false,
            running: true,
            smartPaused: false,
            expected: false,
          ),
          (
            name: 'D RUNNING returns to foreground',
            foreground: true,
            running: true,
            smartPaused: false,
            expected: true,
          ),
          (
            name: 'E PAUSED foreground',
            foreground: true,
            running: false,
            smartPaused: true,
            expected: false,
          ),
          (
            name: 'F STOPPED foreground',
            foreground: true,
            running: false,
            smartPaused: false,
            expected: false,
          ),
          (
            name: 'G foreground RUNNING to PAUSED',
            foreground: true,
            running: false,
            smartPaused: true,
            expected: false,
          ),
          (
            name: 'H PAUSED to RUNNING in foreground',
            foreground: true,
            running: true,
            smartPaused: false,
            expected: true,
          ),
          (
            name: 'H PAUSED to RUNNING in background',
            foreground: false,
            running: true,
            smartPaused: false,
            expected: false,
          ),
        ];

    for (final testCase in cases) {
      test(testCase.name, () {
        expect(
          shouldRunUiStatsTimer(
            appForeground: testCase.foreground,
            sessionRunning: testCase.running,
            smartPaused: testCase.smartPaused,
          ),
          testCase.expected,
        );
      });
    }

    test('repeated convergence does not duplicate start, refresh, or stop', () {
      var timerActive = false;
      var starts = 0;
      var immediateRefreshes = 0;
      var stops = 0;

      void converge(bool shouldRun) {
        switch (uiStatsTimerEffect(
          shouldRun: shouldRun,
          isTimerActive: timerActive,
        )) {
          case UiStatsTimerEffect.none:
            return;
          case UiStatsTimerEffect.start:
            starts++;
            immediateRefreshes++;
            timerActive = true;
          case UiStatsTimerEffect.stop:
            stops++;
            timerActive = false;
        }
      }

      converge(true);
      converge(true);
      expect((starts, immediateRefreshes, stops), (1, 1, 0));

      converge(false);
      converge(false);
      expect((starts, immediateRefreshes, stops), (1, 1, 1));
    });
  });

  test('full stop clears smart pause and its manual override', () {
    final cleared = <String>[];
    convergeFullStopProviders(
      clearManualOverride: () => cleared.add('override'),
      clearSmartStopped: () => cleared.add('smartStopped'),
    );
    expect(cleared, ['override', 'smartStopped']);
  });

  group('ensureRestoreValidationCoreReady', () {
    test('connects and initializes the core once before validation', () async {
      var connectCalls = 0;
      var initCalls = 0;
      final ready = await ensureRestoreValidationCoreReady(
        isConnected: false,
        connectCore: () async {
          connectCalls++;
          return true;
        },
        isCoreInitialized: () async => false,
        initializeCore: () async {
          initCalls++;
          return true;
        },
      );

      expect(ready, isTrue);
      expect(connectCalls, 1);
      expect(initCalls, 1);
    });

    test('does not reconnect or initialize an available core', () async {
      var connectCalls = 0;
      var initCalls = 0;
      final ready = await ensureRestoreValidationCoreReady(
        isConnected: true,
        connectCore: () async {
          connectCalls++;
          return true;
        },
        isCoreInitialized: () async => true,
        initializeCore: () async {
          initCalls++;
          return true;
        },
      );

      expect(ready, isTrue);
      expect(connectCalls, 0);
      expect(initCalls, 0);
    });
  });

  test('activation failure remains a committed restore outcome', () async {
    final outcome = await activateCommittedRestore(
      applyProfile: () async => false,
      updateGroups: () async {},
    );
    expect(outcome.committed, true);
    expect(outcome.activationSucceeded, false);
    expect(outcome.activationError, isNotEmpty);
  });

  group('shouldFullSetupOnInit', () {
    test(
      'skips full setup when VPN is not running and auto run is disabled',
      () {
        expect(
          shouldFullSetupOnInit(isRunning: false, autoRun: false),
          isFalse,
        );
      },
    );

    test('runs full setup when VPN is already running', () {
      expect(shouldFullSetupOnInit(isRunning: true, autoRun: false), isTrue);
    });

    test('runs full setup when auto run is enabled', () {
      expect(shouldFullSetupOnInit(isRunning: false, autoRun: true), isTrue);
    });
  });

  group('task removal stop intent', () {
    test('only an explicit start clears the stop intent', () {
      expect(
        shouldClearTaskRemovalStop(isStart: true, isInit: false),
        isTrue,
      );
      expect(
        shouldClearTaskRemovalStop(isStart: true, isInit: true),
        isFalse,
      );
      expect(
        shouldClearTaskRemovalStop(isStart: false, isInit: false),
        isFalse,
      );
    });
  });

  group('running session reattach helpers', () {
    test('RUNNING and STARTING require full setup', () {
      expect(sessionRequiresFullSetup('RUNNING'), isTrue);
      expect(sessionRequiresFullSetup('STARTING'), isTrue);
      expect(sessionRequiresFullSetup('STOPPING'), isFalse);
      expect(sessionRequiresFullSetup('PAUSED'), isFalse);
      expect(sessionRequiresFullSetup('STOPPED'), isFalse);
    });

    test('only RUNNING skips the connect min delay', () {
      expect(shouldSkipConnectMinDelay('RUNNING'), isTrue);
      expect(shouldSkipConnectMinDelay('STARTING'), isFalse);
      expect(shouldSkipConnectMinDelay('STOPPED'), isFalse);
    });

    test('only RUNNING defers initCore group work to applyProfile', () {
      expect(shouldDeferInitCoreGroups('RUNNING'), isTrue);
      expect(shouldDeferInitCoreGroups('STARTING'), isFalse);
    });

    test('cold explicit Start has exactly one profile activation actor', () {
      var activationActors = 0;
      if (shouldInitCoreForceApply(
        wasInitialized: false,
        deferGroupSetup: false,
        callerOwnsProfileActivation: true,
        hasCurrentProfile: true,
        groupsNeedRefresh: true,
      )) {
        activationActors++;
      }
      activationActors++; // SetupAction.updateStatus owns explicit Start.
      expect(activationActors, 1);
    });

    test('init side effect cannot supersede explicit Start activation', () {
      expect(
        shouldInitCoreForceApply(
          wasInitialized: true,
          deferGroupSetup: false,
          callerOwnsProfileActivation: true,
          hasCurrentProfile: true,
          groupsNeedRefresh: true,
        ),
        isFalse,
      );
    });

    test('non-Start init profile behavior is unchanged', () {
      expect(
        shouldInitCoreForceApply(
          wasInitialized: false,
          deferGroupSetup: false,
          callerOwnsProfileActivation: false,
          hasCurrentProfile: true,
          groupsNeedRefresh: true,
        ),
        isTrue,
      );
      expect(
        shouldInitCoreForceApply(
          wasInitialized: true,
          deferGroupSetup: false,
          callerOwnsProfileActivation: false,
          hasCurrentProfile: true,
          groupsNeedRefresh: true,
        ),
        isTrue,
      );
    });

    test('PAUSED display attach remains independently authoritative', () {
      expect(shouldAttachCoreWithoutVpnSetup('PAUSED'), isTrue);
      expect(shouldDeferInitCoreGroups('PAUSED'), isFalse);
    });

    test('PAUSED restores smart-stop UI without the RUNNING fast path', () {
      expect(shouldRestoreSmartPaused('PAUSED'), isTrue);
      expect(shouldRestoreSmartPaused('STOPPED', smartPaused: true), isTrue);
      expect(shouldRestoreSmartPaused('RUNNING'), isFalse);
      expect(shouldSkipConnectMinDelay('PAUSED'), isFalse);
      expect(shouldDeferInitCoreGroups('PAUSED'), isFalse);
      expect(sessionRequiresFullSetup('PAUSED'), isFalse);
    });

    test('PAUSED attaches Core without restarting VPN', () {
      expect(shouldAttachCoreWithoutVpnSetup('PAUSED'), isTrue);
      expect(shouldAttachCoreWithoutVpnSetup('RUNNING'), isFalse);
      expect(shouldAttachCoreWithoutVpnSetup('STOPPED'), isFalse);
      expect(shouldAttachCoreWithoutVpnSetup(null), isFalse);
    });

    test('idle binder death is noise, live session loss is not', () {
      expect(isRemoteServiceDisconnectMessage('Service disconnected'), isTrue);
      expect(
        isRemoteServiceDisconnectMessage('Service binding ended unexpectedly'),
        isTrue,
      );
      expect(isRemoteServiceDisconnectMessage('init failed'), isFalse);
      expect(
        hasProtectableVpnSession(
          vpnUiRunning: false,
          smartPaused: false,
          nativeSession: 'STOPPED',
        ),
        isFalse,
      );
      expect(
        hasProtectableVpnSession(
          vpnUiRunning: true,
          smartPaused: false,
          nativeSession: 'STOPPED',
        ),
        isTrue,
      );
      expect(
        hasProtectableVpnSession(
          vpnUiRunning: false,
          smartPaused: true,
          nativeSession: 'PAUSED',
        ),
        isTrue,
      );
      expect(
        shouldNotifyRemoteServiceLoss(
          message: 'Service disconnected',
          hasSession: false,
        ),
        isFalse,
      );
      expect(
        shouldNotifyRemoteServiceLoss(
          message: 'Service disconnected',
          hasSession: true,
        ),
        isTrue,
      );
      expect(
        shouldNotifyRemoteServiceLoss(
          message: 'init failed',
          hasSession: false,
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
      expect(
        shouldNotifyCoreCrash(
          hasProtectableSession: true,
          appResumed: true,
          message: 'Service disconnected',
        ),
        isTrue,
      );
      expect(
        shouldHandleCoreCrash(
          coreConnected: true,
          hasProtectableSession: false,
        ),
        isTrue,
      );
    });

    test('smart resume starts the listener only after Core is ready', () {
      expect(
        shouldStartListenerAfterSmartResume(suspend: false, coreReady: true),
        isTrue,
      );
      expect(
        shouldStartListenerAfterSmartResume(suspend: false, coreReady: false),
        isFalse,
      );
      expect(
        shouldStartListenerAfterSmartResume(suspend: true, coreReady: true),
        isFalse,
      );
    });

    test('native session maps to visible UI state without guessing', () {
      expect(nativeSessionUiStateFor('RUNNING'), NativeSessionUiState.running);
      expect(nativeSessionUiStateFor('PAUSED'), NativeSessionUiState.paused);
      expect(nativeSessionUiStateFor('STOPPED'), NativeSessionUiState.stopped);
      expect(nativeSessionUiStateFor('STARTING'), NativeSessionUiState.pending);
      expect(nativeSessionUiStateFor('STOPPING'), NativeSessionUiState.pending);
      expect(nativeSessionUiStateFor(null), NativeSessionUiState.pending);
    });
  });

  group('vpnStartPolicy', () {
    test('user tap silences loading and stops VPN if apply or TUN fails', () {
      final policy = vpnStartPolicy(isInit: false);
      expect(policy.silence, isTrue);
      expect(policy.stopOnFailure, isTrue);
      expect(policy.seedRunTimeAtZero, isFalse);
    });

    test(
      'init shows loading, does not stop VPN on failure, and seeds runTime',
      () {
        final policy = vpnStartPolicy(isInit: true);
        expect(policy.silence, isFalse);
        expect(policy.stopOnFailure, isFalse);
        expect(policy.seedRunTimeAtZero, isTrue);
      },
    );
  });

  group('shouldReconnectCoreOnResume', () {
    test(
      'does not reconnect core on Android when VPN is stopped and groups exist',
      () {
        expect(
          shouldReconnectCoreOnResume(
            isAndroid: true,
            isRunning: false,
            hasGroups: true,
          ),
          isFalse,
        );
      },
    );

    test(
      'reconnects core on Android when VPN is stopped but groups are empty (initial load)',
      () {
        expect(
          shouldReconnectCoreOnResume(
            isAndroid: true,
            isRunning: false,
            hasGroups: false,
          ),
          isTrue,
        );
      },
    );

    test('reconnects core on Android when VPN is running', () {
      expect(
        shouldReconnectCoreOnResume(
          isAndroid: true,
          isRunning: true,
          hasGroups: true,
        ),
        isTrue,
      );
    });

    test('does not reconnect core on non-Android platforms', () {
      expect(
        shouldReconnectCoreOnResume(
          isAndroid: false,
          isRunning: true,
          hasGroups: true,
        ),
        isFalse,
      );
    });
  });

  group('hasExternalProviderDefinitions', () {
    test('is false when config has no providers', () {
      expect(hasExternalProviderDefinitions(const ClashConfig()), isFalse);
    });

    test('is true when config has proxy providers', () {
      final config = ClashConfig.fromJson({
        'proxy-providers': {'provider1': <String, Object?>{}},
      });

      expect(hasExternalProviderDefinitions(config), isTrue);
    });

    test('is true when config has rule providers', () {
      final config = ClashConfig.fromJson({
        'rule-providers': {'rules1': <String, Object?>{}},
      });

      expect(hasExternalProviderDefinitions(config), isTrue);
    });
  });

  group('parseProfileProviderDefinitions', () {
    test('detects proxy and rule providers without accessing core', () {
      final definitions = parseProfileProviderDefinitions('''
proxy-providers:
  airport:
    type: http
rule-providers:
  reject:
    type: http
''');

      expect(definitions.external, isTrue);
      expect(definitions.proxy, isTrue);
    });

    test('does not treat empty provider maps as definitions', () {
      final definitions = parseProfileProviderDefinitions('''
proxy-providers: {}
rule-providers: {}
proxies:
  - name: inline
    type: direct
''');

      expect(definitions.external, isFalse);
      expect(definitions.proxy, isFalse);
    });
  });

  group('runtime config projection identity', () {
    test(
      'provider result is discarded when A changes to B during fetch',
      () async {
        var currentProfileId = 1;
        final fetchStarted = Completer<void>();
        final releaseFetch = Completer<void>();
        final published = <String>[];

        final resultFuture = fetchAndPublishRuntimeProjection(
          targetProfileId: 1,
          currentProfileId: () => currentProfileId,
          fetch: () async {
            fetchStarted.complete();
            await releaseFetch.future;
            return 'providers-A';
          },
          publish: published.add,
        );
        await fetchStarted.future;
        currentProfileId = 2;
        releaseFetch.complete();

        expect(await resultFuture, isFalse);
        expect(published, isEmpty);
      },
    );

    test('A result stays discarded after UI advances through B to C', () async {
      var currentProfileId = 1;
      final fetchStarted = Completer<void>();
      final releaseFetch = Completer<void>();
      final published = <String>[];

      final resultFuture = fetchAndPublishRuntimeProjection(
        targetProfileId: 1,
        currentProfileId: () => currentProfileId,
        fetch: () async {
          fetchStarted.complete();
          await releaseFetch.future;
          return 'providers-A';
        },
        publish: published.add,
      );
      await fetchStarted.future;
      currentProfileId = 2;
      currentProfileId = 3;
      releaseFetch.complete();

      expect(await resultFuture, isFalse);
      expect(published, isEmpty);
    });

    test(
      'provider result publishes when target identity stays current',
      () async {
        final published = <String>[];
        final result = await fetchAndPublishRuntimeProjection(
          targetProfileId: 1,
          currentProfileId: () => 1,
          fetch: () async => 'providers-A',
          publish: published.add,
        );

        expect(result, isTrue);
        expect(published, ['providers-A']);
      },
    );
  });

  group('preheat runtime projection identity', () {
    test(
      'switching A to B during warm-up drops late delay and post-refresh',
      () async {
        var currentProfileId = 1;
        final warmUpStarted = Completer<void>();
        final releaseWarmUp = Completer<void>();
        final published = <Delay>[];
        var scheduledRefreshes = 0;

        final remainsCurrent = warmUpRuntimeDelaysForProfile(
          targetProfileId: 1,
          currentProfileId: () => currentProfileId,
          publish: published.add,
          warmUp: (onDelay) async {
            onDelay(const Delay(url: 'test', name: 'A', value: 0));
            warmUpStarted.complete();
            await releaseWarmUp.future;
            onDelay(const Delay(url: 'test', name: 'A', value: 88));
          },
        );
        await warmUpStarted.future;
        currentProfileId = 2;
        releaseWarmUp.complete();

        if (await remainsCurrent) scheduledRefreshes++;
        expect(
          published.map((delay) => delay.value),
          [0],
          reason: 'the late A result must not enter B delay projection',
        );
        expect(scheduledRefreshes, 0);
      },
    );

    test(
      'A debounce becomes inert when current changes before callback',
      () async {
        final scheduler = Debouncer();
        var currentProfileId = 1;
        var refreshes = 0;

        scheduleRuntimeProjectionRefresh(
          scheduler: scheduler,
          tag: Object(),
          expectedProfileId: 1,
          currentProfileId: () => currentProfileId,
          refresh: () => refreshes++,
          duration: const Duration(milliseconds: 10),
        );
        currentProfileId = 2;
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(refreshes, 0);
      },
    );

    test('A debounce refreshes normally while A remains current', () async {
      final scheduler = Debouncer();
      final refreshed = Completer<void>();

      scheduleRuntimeProjectionRefresh(
        scheduler: scheduler,
        tag: Object(),
        expectedProfileId: 1,
        currentProfileId: () => 1,
        refresh: refreshed.complete,
        duration: const Duration(milliseconds: 10),
      );

      await refreshed.future.timeout(const Duration(seconds: 1));
      expect(refreshed.isCompleted, isTrue);
    });
  });

  group('ProfilesAction', () {
    test(
      'DB delete failure leaves projection and resources untouched',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'profile-delete-failure',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final yaml = File('${tempDir.path}/profile.yaml')
          ..writeAsStringSync('proxies: []');
        final providers = Directory('${tempDir.path}/providers')..createSync();
        var projectionDeleted = false;

        await expectLater(
          runAuthoritativeProfileDelete(
            commitDatabaseDelete: () async {
              throw StateError('database delete failed');
            },
            applyCommittedProjection: () {
              projectionDeleted = true;
            },
            updateDesiredProfile: () {},
            cleanupResources: () async {
              await yaml.delete();
              await providers.delete(recursive: true);
            },
          ),
          throwsStateError,
        );

        expect(projectionDeleted, isFalse);
        expect(await yaml.exists(), isTrue);
        expect(await providers.exists(), isTrue);
      },
    );

    test('cleanup failure never resurrects committed profile', () async {
      final order = <String>[];
      var projectionDeleted = false;

      await expectLater(
        runAuthoritativeProfileDelete(
          commitDatabaseDelete: () async {
            order.add('database');
          },
          applyCommittedProjection: () {
            order.add('projection');
            projectionDeleted = true;
          },
          updateDesiredProfile: () {
            order.add('desired');
          },
          cleanupResources: () async {
            order.add('cleanup');
            throw const ProfileResourceCleanupException(
              'provider cleanup failed',
            );
          },
        ),
        throwsA(isA<ProfileResourceCleanupException>()),
      );

      expect(projectionDeleted, isTrue);
      expect(order, ['database', 'projection', 'desired', 'cleanup']);
    });

    test('deleting current profile selects an existing next profile', () async {
      final next = Profile.normal(label: 'next');
      int? desired = 1;
      var stopCalls = 0;

      await convergeDesiredProfileAfterDelete(
        deletedProfileId: 1,
        currentProfileId: desired,
        remainingProfiles: [next],
        setCurrentProfileId: (value) => desired = value,
        stopLastProfile: () async {
          stopCalls++;
        },
      );

      expect(desired, next.id);
      expect(stopCalls, 0);
    });

    test(
      'deleting final profile clears desired id and requests stop',
      () async {
        int? desired = 1;
        var stopCalls = 0;

        await convergeDesiredProfileAfterDelete(
          deletedProfileId: 1,
          currentProfileId: desired,
          remainingProfiles: const [],
          setCurrentProfileId: (value) => desired = value,
          stopLastProfile: () async {
            stopCalls++;
          },
        );

        expect(desired, isNull);
        expect(stopCalls, 1);
      },
    );

    test('auto loop does not republish a stale captured profile', () async {
      final a = Profile.normal(label: 'A', url: 'https://a.example');
      final bOld = Profile.normal(label: 'B old', url: 'https://b.example');
      final bNew = bOld.copyWith(
        label: 'B newest',
        autoUpdate: false,
        autoUpdateDuration: const Duration(hours: 12),
      );
      final container = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(() => _TestProfiles([a, bOld])),
        ],
      );
      addTearDown(container.dispose);
      final aStarted = Completer<void>();
      final releaseA = Completer<void>();
      Profile? capturedB;

      final loop = runAutoProfileRefreshLoop(
        capturedProfiles: List<Profile>.from(container.read(profilesProvider)),
        refresh: (profile) async {
          if (profile.id == a.id) {
            aStarted.complete();
            await releaseA.future;
          } else {
            capturedB = profile;
          }
        },
        onError: (_) {},
      );
      await aStarted.future;
      container.read(profilesProvider.notifier).put(bNew);
      releaseA.complete();
      await loop;

      expect(capturedB, bOld);
      expect(container.read(profilesProvider).getProfile(bOld.id), bNew);
    });

    test('auto loop supersedes a captured response after URL edit', () async {
      final a = Profile.normal(label: 'A', url: 'https://a.example');
      final bOld = Profile.normal(
        label: 'B old',
        url: 'https://old.example/profile',
      );
      final bNew = bOld.copyWith(
        label: 'B newest',
        url: 'https://new.example/profile',
      );
      final container = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(() => _TestProfiles([a, bOld])),
        ],
      );
      addTearDown(container.dispose);
      final aStarted = Completer<void>();
      final releaseA = Completer<void>();
      var oldResponseWasCurrent = true;

      final loop = runAutoProfileRefreshLoop(
        capturedProfiles: List<Profile>.from(container.read(profilesProvider)),
        refresh: (profile) async {
          if (profile.id == a.id) {
            aStarted.complete();
            await releaseA.future;
            return;
          }
          oldResponseWasCurrent = isProfileSourceIdentityCurrent(
            container.read(profilesProvider).getProfile(profile.id),
            profileId: profile.id,
            sourceUrl: profile.url,
          );
        },
        onError: (_) {},
      );
      await aStarted.future;
      container.read(profilesProvider.notifier).put(bNew);
      releaseA.complete();
      await loop;

      expect(oldResponseWasCurrent, isFalse);
      expect(container.read(profilesProvider).getProfile(bOld.id), bNew);
    });

    test('refresh-only failure never publishes captured metadata', () async {
      final captured = Profile.normal(label: 'old label', url: 'bad-url');
      final latest = captured.copyWith(
        label: 'newest label',
        autoUpdate: false,
        autoUpdateDuration: const Duration(hours: 8),
      );
      final container = ProviderContainer(
        overrides: [
          currentProfileIdProvider.overrideWithBuild((_, _) => null),
          profilesProvider.overrideWith(() => _TestProfiles([latest])),
        ],
      );
      addTearDown(container.dispose);

      await expectLater(
        container
            .read(profilesActionProvider.notifier)
            .updateProfile(captured, publishInput: false),
        throwsA(anything),
      );

      expect(container.read(profilesProvider).getProfile(captured.id), latest);
    });

    test('keeps edited profile data when remote update fails', () async {
      final original = Profile.normal(label: 'old label', url: 'bad-url');
      final edited = original.copyWith(
        label: 'new label',
        url: 'still-bad-url',
      );
      final container = ProviderContainer(
        overrides: [
          currentProfileIdProvider.overrideWithBuild((_, _) => null),
          profilesProvider.overrideWith(() => _TestProfiles([original])),
        ],
      );
      addTearDown(container.dispose);

      expect(
        container.read(profilesProvider).getProfile(original.id),
        original,
      );

      await expectLater(
        container
            .read(profilesActionProvider.notifier)
            .updateProfile(edited, publishInput: true),
        throwsA(anything),
      );

      final profile = container.read(profilesProvider).getProfile(original.id);
      expect(profile?.label, edited.label);
      expect(profile?.url, edited.url);
    });
  });
}

class _TestProfiles extends Profiles {
  final List<Profile> initial;

  _TestProfiles(this.initial);

  @override
  List<Profile> build() => initial;

  @override
  void put(Profile profile) {
    final next = List<Profile>.from(state);
    final index = next.indexWhere((item) => item.id == profile.id);
    if (index == -1) {
      next.add(profile);
    } else {
      next[index] = profile;
    }
    state = next;
  }
}
