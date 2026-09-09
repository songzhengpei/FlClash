import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/core.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';

import 'package:fl_clash/core/command_outcome.dart';
import 'package:fl_clash/core/interface.dart';

Future<bool> stopListenerAndNativeService({
  required Future<bool> Function() stopCoreListenerOnly,
  required Future<bool> Function() stopNativeService,
}) async {
  // Native lifecycle state is authoritative. Listener cleanup is best-effort
  // and must never prevent the physical service stop from being attempted.
  try {
    await stopCoreListenerOnly();
  } catch (_) {}
  return stopNativeService();
}

Future<String> runCorePreloadHandshake({
  required Future<String?> Function() initTransport,
  required Future<String?> Function() syncState,
  required void Function() markConnected,
}) async {
  final initResult = await initTransport();
  if (initResult == null) {
    return CoreCommandOutcome.unconfirmed;
  }
  if (initResult.isNotEmpty) {
    return initResult;
  }
  final syncResult = await syncState();
  if (syncResult == null) {
    return CoreCommandOutcome.unconfirmed;
  }
  if (syncResult.isNotEmpty) {
    return syncResult;
  }
  markConnected();
  return '';
}

class CoreLib extends CoreHandlerInterface {
  static CoreLib? _instance;

  Completer<bool> _connectedCompleter = Completer();

  CoreLib._internal();

  @override
  Future<String> preload() async {
    if (_connectedCompleter.isCompleted) {
      return '';
    }
    return runCorePreloadHandshake(
      initTransport: () async => service?.init().withTimeout(
        timeout: const Duration(seconds: 8),
        tag: 'service init',
        onTimeout: () => 'service init timeout',
      ),
      syncState: () async =>
          service?.syncState(globalState.container.read(sharedStateProvider)),
      markConnected: () => _connectedCompleter.safeCompleter(true),
    );
  }

  factory CoreLib() {
    _instance ??= CoreLib._internal();
    return _instance!;
  }

  @override
  FutureOr<bool> destroy() async {
    return true;
  }

  @override
  Future<bool> shutdown(_) async {
    if (!_connectedCompleter.isCompleted) {
      return false;
    }
    _connectedCompleter = Completer();
    final svc = service;
    if (svc == null) {
      return false;
    }
    return svc.shutdown();
  }

  @override
  Future<bool> startListener() async {
    return await service?.start() ?? false;
  }

  @override
  Future<bool> stopListener() async {
    return await service?.stop() ?? false;
  }

  @override
  Future<T?> invoke<T>({
    required ActionMethod method,
    dynamic data,
    Duration? timeout,
  }) async {
    final id = '${method.name}#${utils.id}';
    return CoreIpcTrace.run<T>(
      id: id,
      method: method.name,
      body: () async {
        final result = await service
            ?.invokeAction(Action(id: id, method: method, data: data))
            .withTimeout(timeout: timeout, onTimeout: () => null);
        if (result == null) {
          CoreIpcTrace.classify(id, 'transport_null_or_timeout');
          return null;
        }
        if (result.code == ResultType.error) {
          CoreIpcTrace.classify(id, 'core_error');
        } else {
          CoreIpcTrace.classify(id, 'success');
        }
        try {
          return await parasResult<T>(result);
        } catch (_) {
          CoreIpcTrace.classify(id, 'parse_error');
          rethrow;
        }
      },
    );
  }

  @override
  Completer get completer => _connectedCompleter;
}

CoreLib? get coreLib => system.isAndroid ? CoreLib() : null;
