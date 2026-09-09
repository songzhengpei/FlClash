import 'dart:async';

/// Invalidates obsolete work immediately; commits remain ordered even on error.
final class LifecycleIntent {
  int generation = 0;
  Future<void> _tail = Future<void>.value();
  int begin() => ++generation;
  bool isCurrent(int token) => token == generation;

  Future<void> commit(int token, Future<void> Function() action) {
    final result = _tail.then((_) async {
      if (isCurrent(token)) await action();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
