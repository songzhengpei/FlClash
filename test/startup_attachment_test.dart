import 'dart:async';
import 'package:fl_clash/state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'early user action joins startup and waits for session restoration',
    () async {
      final ready = Completer<void>();
      var initializations = 0;
      final state = GlobalState.test(() {
        initializations++;
        return ready.future;
      });
      final startup = state.attach();
      var actionRan = false;
      final earlyAction = state.attach().then((_) => actionRan = true);
      await Future<void>.delayed(Duration.zero);
      expect(initializations, 1);
      expect(actionRan, isFalse);
      expect(state.isAttach, isFalse);
      ready.complete();
      await Future.wait([startup, earlyAction]);
      expect(actionRan, isTrue);
      expect(state.isAttach, isTrue);
      await state.attach();
      expect(initializations, 1);
    },
  );

  test('failed startup does not release a pending action as ready', () async {
    final ready = Completer<void>();
    var attempts = 0;
    final state = GlobalState.test(
      () => ++attempts == 1 ? ready.future : Future<void>.value(),
    );
    final startup = expectLater(state.attach(), throwsStateError);
    final action = expectLater(state.attach(), throwsStateError);
    ready.completeError(StateError('startup failed'));
    await Future.wait([startup, action]);
    expect(state.isAttach, isFalse);
    await state.attach();
    expect(state.isAttach, isTrue);
    expect(attempts, 2);
  });
}
