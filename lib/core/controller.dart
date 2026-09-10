import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:path/path.dart';

class TrafficSnapshot {
  const TrafficSnapshot({
    this.traffic = const Traffic(),
    this.totalTraffic = const Traffic(),
  });

  final Traffic traffic;
  final Traffic totalTraffic;

  factory TrafficSnapshot.fromJson(Map<String, dynamic> json) {
    return TrafficSnapshot(
      traffic: Traffic(
        up: json['up'] as num? ?? 0,
        down: json['down'] as num? ?? 0,
      ),
      totalTraffic: Traffic(
        up: json['totalUp'] as num? ?? 0,
        down: json['totalDown'] as num? ?? 0,
      ),
    );
  }
}

class CoreController {
  static CoreController? _instance;
  late CoreHandlerInterface _interface;

  CoreController._internal() {
    _interface = coreLib!;
  }

  @visibleForTesting
  CoreController.test(this._interface);

  @visibleForTesting
  static void resetInstance() {
    _instance = null;
  }

  factory CoreController() {
    _instance ??= CoreController._internal();
    return _instance!;
  }

  bool get isCompleted => _interface.completer.isCompleted;

  Future<String> preload() {
    return _interface.preload();
  }

  static Future<void> initGeo() async {
    final homePath = await appPath.homeDirPath;
    final homeDir = Directory(homePath);
    final isExists = await homeDir.exists();
    if (!isExists) {
      await homeDir.create(recursive: true);
    }
    const geoFileNameList = [MMDB, GEOIP, GEOSITE, ASN];
    try {
      for (final geoFileName in geoFileNameList) {
        final geoFile = File(join(homePath, geoFileName));
        final isExists = await geoFile.exists();
        if (isExists) {
          continue;
        }
        final data = await rootBundle.load('assets/data/$geoFileName');
        final List<int> bytes = data.buffer.asUint8List();
        await geoFile.writeAsBytes(bytes, flush: true);
      }
    } catch (e) {
      commonPrint.log(
        'Failed to initialize geo data: $e',
        logLevel: LogLevel.error,
      );
      rethrow;
    }
  }

  Future<bool> init(int version) async {
    await initGeo();
    final homeDirPath = await appPath.homeDirPath;
    return _interface.init(InitParams(homeDir: homeDirPath, version: version));
  }

  Future<void> shutdown(bool isUser) async {
    await _interface.shutdown(isUser);
  }

  FutureOr<bool> get isInit => _interface.isInit;

  Future<String> validateConfig(String path) async {
    final res = await _interface.validateConfig(path);
    return res;
  }

  Future<String> validateConfigWithData(String data) async {
    final path = '${await appPath.tempFilePath}.${DateTime.now().microsecondsSinceEpoch}';
    final file = File(path);
    try {
      await file.safeWriteAsString(data);
      return await _interface.validateConfig(path);
    } finally {
      await file.safeDelete();
    }
  }

  Future<String> updateConfig(UpdateParams updateParams) async {
    return _interface.updateConfig(updateParams);
  }

  /// Establish TUN / startListener only after native setupConfig **confirmed** empty success.
  /// Transport unconfirmed is nonempty and must not preload.
  @visibleForTesting
  static bool shouldPreloadVpnAfterSetup(String message) => message.isEmpty;

  Future<String> setupConfig({
    required SetupParams params,
    required SetupState setupState,
    FutureOr<void> Function()? preloadInvoke,
  }) async {
    final message = await _interface.setupConfig(params);
    if (shouldPreloadVpnAfterSetup(message)) {
      await preloadInvoke?.call();
    }
    return message;
  }

  Future<List<Group>> getProxiesGroups({
    required ProxiesSortType sortType,
    required DelayMap delayMap,
    required Map<String, String> selectedMap,
    required String defaultTestUrl,
  }) async {
    final proxiesData = await _interface.getProxies();
    return toGroupsTask(
      ComputeGroupsState(
        proxiesData: proxiesData,
        sortType: sortType,
        delayMap: delayMap,
        selectedMap: selectedMap,
        defaultTestUrl: defaultTestUrl,
      ),
    );
  }

  Future<List<Group>> materializeProfileSnapshotGroups({
    required String profilePath,
    required Map<String, String> selectedMap,
    required ProxiesSortType sortType,
    required DelayMap delayMap,
    required String defaultTestUrl,
  }) async {
    final proxiesData = await _interface.materializeProfileSnapshot(
      profilePath: profilePath,
      selectedMap: selectedMap,
      defaultTestUrl: defaultTestUrl,
    );
    return toGroupsTask(
      ComputeGroupsState(
        proxiesData: proxiesData,
        sortType: sortType,
        delayMap: delayMap,
        selectedMap: selectedMap,
        defaultTestUrl: defaultTestUrl,
      ),
    );
  }

  Future<List<Map<String, dynamic>>> normalizeProviderContent(List<int> bytes) {
    return _interface.normalizeProviderContent(bytes);
  }

  Future<ProxiesData> getProxiesData() {
    return _interface.getProxies();
  }

  Future<List<Proxy>> getRuntimeLeafProxies() async {
    return getLeafProxiesFromProxiesData(await getProxiesData());
  }

  FutureOr<String> changeProxy(ChangeProxyParams changeProxyParams) async {
    return await _interface.changeProxy(changeProxyParams);
  }

  FutureOr<String> unfixProxy(UnfixProxyParams unfixProxyParams) async {
    return await _interface.unfixProxy(unfixProxyParams);
  }

  Future<List<TrackerInfo>> getConnections() async {
    final res = await _interface.getConnections();
    final connectionsData = json.decode(res) as Map;
    final connectionsRaw = connectionsData['connections'] as List? ?? [];
    return connectionsRaw.map((e) => TrackerInfo.fromJson(e)).toList();
  }

  Future<void> closeConnection(String id) async {
    await _interface.closeConnection(id);
  }

  Future<bool> closeConnections() async {
    return await _interface.closeConnections();
  }

  Future<void> resetConnections() async {
    await _interface.resetConnections();
  }

  Future<List<ExternalProvider>> getExternalProviders() async {
    final externalProvidersRawString = await _interface.getExternalProviders();
    if (externalProvidersRawString.isEmpty) {
      return [];
    }
    final externalProviders =
        (await externalProvidersRawString.commonToJSON<List<dynamic>>())
            .map((item) => ExternalProvider.fromJson(item))
            .toList();
    return externalProviders;
  }

  Future<ExternalProvider?> getExternalProvider(
    String externalProviderName,
  ) async {
    final externalProvidersRawString = await _interface.getExternalProvider(
      externalProviderName,
    );
    if (externalProvidersRawString.isEmpty) {
      return null;
    }
    return ExternalProvider.fromJson(json.decode(externalProvidersRawString));
  }

  Future<String> updateGeoData(UpdateGeoDataParams params) {
    return _interface.updateGeoData(params);
  }

  Future<String> sideLoadExternalProvider({
    required String providerName,
    required String data,
  }) {
    return _interface.sideLoadExternalProvider(
      providerName: providerName,
      data: data,
    );
  }

  Future<String> updateExternalProvider({required String providerName}) async {
    return _interface.updateExternalProvider(providerName);
  }

  Future<bool> startListener() async {
    return _interface.startListener();
  }

  Future<bool> stopListener() async {
    return _interface.stopListener();
  }

  Future<bool> stopCoreListenerOnly() async {
    return _interface.stopCoreListenerOnly();
  }

  Future<Delay> getDelay(String url, String proxyName) async {
    final data = await _interface.asyncTestDelay(url, proxyName);
    return Delay.fromJson(json.decode(data));
  }

  Future<String> mediaCheck(
    String proxyName, {
    int? profileId,
    bool healthOnly = false,
    String mode = 'full',
  }) async {
    final profilePath = profileId == null
        ? null
        : await appPath.getProfilePath(profileId.toString());
    return _interface.mediaCheck(
      proxyName,
      profilePath: profilePath,
      healthOnly: healthOnly,
      mode: mode,
    );
  }

  // Single canonicalization contract for the config APIs: RawConfig marshals
  // rules under the json tag "rule" and every entry point must produce the
  // same Dart map. An empty result means Core did not return a config at all
  // (e.g. the invoke timed out and was faked as success); treat that as a
  // failure so snapshot preservation falls back instead of overlaying.
  Map<String, dynamic> _normalizeConfigResult(dynamic data) {
    if (data is! Map || data.isEmpty) {
      throw StateError('Mihomo normalization returned no config');
    }
    final map = Map<String, dynamic>.from(data);
    map['rules'] = map['rule'];
    map.remove('rule');
    return map;
  }

  Future<Map<String, dynamic>> getConfig(int id) async {
    final profilePath = await appPath.getProfilePath(id.toString());
    return getConfigAtPath(profilePath);
  }

  /// Normalizes the config at [path]. Used by the single-snapshot path to
  /// hand Core the exact snapshot bytes via a short file path instead of
  /// sending the whole profile over the Android Binder.
  Future<Map<String, dynamic>> getConfigAtPath(String path) async {
    final res = await _interface.getConfig(path);
    if (res.isSuccess) {
      return _normalizeConfigResult(res.data);
    } else {
      throw res.message;
    }
  }

  Future<Traffic> getTraffic(bool onlyStatisticsProxy) async {
    final trafficString = await _interface.getTraffic(onlyStatisticsProxy);
    if (trafficString.isEmpty) {
      return const Traffic();
    }
    return Traffic.fromJson(json.decode(trafficString));
  }

  Future<IpInfo?> getCountryCode(String ip) async {
    final countryCode = await _interface.getCountryCode(ip);
    if (countryCode.isEmpty) {
      return null;
    }
    return IpInfo(ip: ip, countryCode: countryCode);
  }

  Future<Traffic> getTotalTraffic(bool onlyStatisticsProxy) async {
    final totalTrafficString = await _interface.getTotalTraffic(
      onlyStatisticsProxy,
    );
    if (totalTrafficString.isEmpty) {
      return const Traffic();
    }
    return Traffic.fromJson(json.decode(totalTrafficString));
  }

  Future<TrafficSnapshot> getTrafficSnapshot(bool onlyStatisticsProxy) async {
    final trafficSnapshotString = await _interface.getTrafficSnapshot(
      onlyStatisticsProxy,
    );
    if (trafficSnapshotString.isEmpty) {
      return const TrafficSnapshot();
    }
    return TrafficSnapshot.fromJson(json.decode(trafficSnapshotString));
  }

  Future<int> getMemory() async {
    final value = await _interface.getMemory();
    if (value.isEmpty) {
      return 0;
    }
    return int.parse(value);
  }

  void resetTraffic() {
    _interface.resetTraffic();
  }

  void startLog() {
    _interface.startLog();
  }

  void stopLog() {
    _interface.stopLog();
  }

  Future<void> requestGc() async {
    await _interface.forceGc();
  }

  Future<void> destroy() async {
    await _interface.destroy();
  }

  Future<void> crash() async {
    await _interface.crash();
  }

  Future<String> deleteFile(String path) async {
    return _interface.deleteFile(path);
  }
}

final coreController = CoreController();
