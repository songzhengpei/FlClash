import 'dart:async';

import 'package:fl_clash/providers/action.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cold import waits for core readiness before touching source', () async {
    final ready = Completer<bool>();
    var touched = false;
    final result = runProfileSourceWithReadyCore(
      ensureReady: () => ready.future,
      operation: () async {
        touched = true;
        return 'validated source';
      },
    );
    await Future<void>.delayed(Duration.zero);
    expect(touched, false);
    ready.complete(true);
    expect(await result, 'validated source');
    expect(touched, true);
  });

  test('failed initialization prevents import and allows a later retry', () async {
    var ready = false;
    var calls = 0;
    Future<int> attempt() => runProfileSourceWithReadyCore(
      ensureReady: () async => ready,
      operation: () async => ++calls,
    );
    await expectLater(attempt(), throwsStateError);
    expect(calls, 0);
    ready = true;
    expect(await attempt(), 1);
  });

  test('validation errors remain errors after successful initialization', () async {
    await expectLater(
      runProfileSourceWithReadyCore(
        ensureReady: () async => true,
        operation: () async => throw const FormatException('invalid profile'),
      ),
      throwsFormatException,
    );
  });
}
