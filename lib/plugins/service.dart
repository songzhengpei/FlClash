import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract mixin class ServiceListener {
  void onServiceEvent(CoreEvent event) {}

  void onServiceCrash(String message) {}
}

class Service {
  static Service? _instance;
  late MethodChannel methodChannel;
  ReceivePort? receiver;

  final ObserverList<ServiceListener> _listeners =
      ObserverList<ServiceListener>();

  factory Service() {
    _instance ??= Service._internal();
    return _instance!;
  }

  Service._internal() {
    methodChannel = const MethodChannel('$methodChannelPrefix/service');
    methodChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'event':
          final data = call.arguments as String? ?? '';
          final result = ActionResult.fromJson(json.decode(data));
          for (final listener in _listeners) {
            listener.onServiceEvent(CoreEvent.fromJson(result.data));
          }
          break;
        case 'crash':
          final message = call.arguments as String? ?? '';
          for (final listener in _listeners) {
            listener.onServiceCrash(message);
          }
          break;
        default:
          throw MissingPluginException();
      }
    });
  }

  Future<ActionResult?> invokeAction(Action action) async {
    final data = await methodChannel.invokeMethod<String>(
      'invokeAction',
      json.encode(action),
    );
    if (data == null) {
      return null;
    }
    final dataJson = await data.commonToJSON<dynamic>();
    return ActionResult.fromJson(dataJson);
  }

  Future<bool> start() async {
    return await methodChannel.invokeMethod<bool>('start') ?? false;
  }

  Future<bool> clearTaskRemovalStop() async {
    return await methodChannel.invokeMethod<bool>('clearTaskRemovalStop') ?? false;
  }

  Future<bool> stop() async {
    return await methodChannel.invokeMethod<bool>('stop') ?? false;
  }

  Future<String> reconfigureSettings(VpnOptions options, int sessionId) async {
    return await methodChannel.invokeMethod<String>('reconfigureSettings', {
      'options': json.encode(options),
      'sessionId': sessionId,
    }) ?? 'VPN settings application was not acknowledged';
  }

  Future<String?> init() async {
    return methodChannel.invokeMethod<String>('init');
  }

  Future<String?> syncState(SharedState state) async {
    return methodChannel.invokeMethod<String>('syncState', json.encode(state));
  }

  Future<bool> shutdown() async {
    return await methodChannel.invokeMethod<bool>('shutdown') ?? false;
  }

  Future<DateTime?> getRunTime() async {
    final ms = await methodChannel.invokeMethod<int>('getRunTime') ?? 0;
    if (ms == 0) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<Map<String, dynamic>> getSessionSnapshot() async {
    final raw = await methodChannel.invokeMethod<dynamic>('getSessionSnapshot');
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    return const {};
  }

  Future<List<String>> getLocalIpAddresses() async {
    final result = await methodChannel.invokeMethod<List>(
      'getLocalIpAddresses',
    );
    return result?.cast<String>() ?? [];
  }

  Future<bool> smartStop() async {
    return await methodChannel.invokeMethod<bool>('smartStop') ?? false;
  }

  Future<bool> smartResume() async {
    return await methodChannel.invokeMethod<bool>('smartResume') ?? false;
  }

  Future<void> setSmartStopped(bool value) async {
    await methodChannel.invokeMethod<bool>('setSmartStopped', value);
  }

  Future<bool> isSmartStopped() async {
    return await methodChannel.invokeMethod<bool>('isSmartStopped') ?? false;
  }

  Future<bool> updateSmartPauseConfig({
    required bool enabled,
    required List<String> trustedNetworks,
    required bool closeConnections,
  }) async {
    return await methodChannel.invokeMethod<bool>('updateSmartPauseConfig', {
          'enabled': enabled,
          'trustedNetworks': trustedNetworks,
          'closeConnections': closeConnections,
        }) ??
        false;
  }

  Future<bool> reevaluateSmartPause() async {
    return await methodChannel.invokeMethod<bool>('reevaluateSmartPause') ??
        false;
  }

  bool get hasListeners {
    return _listeners.isNotEmpty;
  }

  void addListener(ServiceListener listener) {
    _listeners.add(listener);
  }

  void removeListener(ServiceListener listener) {
    _listeners.remove(listener);
  }
}

Service? get service => system.isAndroid ? Service() : null;
