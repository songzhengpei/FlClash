import 'dart:async';
import 'package:fl_clash/services/lifecycle_intent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('stop invalidates startup blocked in preparation', () async {
    final owner = LifecycleIntent();
    final ready = Completer<void>();
    final entered = Completer<void>();
    final events = <String>[];
    final start = owner.begin();
    final starting = owner.commit(start, () async {
      entered.complete();
      await ready.future;
      if (owner.isCurrent(start)) events.add('start');
    });
    await entered.future;
    final stop = owner.begin();
    final stopping = owner.commit(stop, () async => events.add('stop'));
    ready.complete();
    await Future.wait([starting, stopping]);
    expect(events, ['stop']);
  });

  test('new start supersedes queued old stop, without overlapping commits', () async {
    final owner = LifecycleIntent();
    final release = Completer<void>();
    final entered = Completer<void>();
    final events = <String>[];
    final first = owner.commit(owner.begin(), () async {
      entered.complete();
      await release.future;
      events.add('old work done');
    });
    await entered.future;
    final stop = owner.commit(owner.begin(), () async => events.add('old stop'));
    final start = owner.commit(owner.begin(), () async => events.add('new start'));
    release.complete();
    await Future.wait([first, stop, start]);
    expect(events, ['old work done', 'new start']);
  });

  test('failed lifecycle commit does not poison later retry', () async {
    final owner = LifecycleIntent();
    await expectLater(owner.commit(owner.begin(), () async {
      throw StateError('permission rejected');
    }), throwsStateError);
    var restarted = false;
    await owner.commit(owner.begin(), () async => restarted = true);
    expect(restarted, isTrue);
  });
}
