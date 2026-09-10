import 'dart:io';
import 'dart:convert';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/services/mihomo_config/structural_config_diff.dart';

enum SettingsApplyKind { none, hot, reload, vpn }

enum DnsSettingsSource { subscription, override, automatic }

DnsSettingsSource dnsSettingsSource({
  required bool sourceEnabled,
  required bool overrideDns,
}) => !sourceEnabled
    ? DnsSettingsSource.automatic
    : overrideDns
    ? DnsSettingsSource.override
    : DnsSettingsSource.subscription;

String? validateRouteCidr(String? value) {
  final parts = (value ?? '').trim().split('/');
  if (parts.length != 2) return 'CIDR: 192.168.1.0/24 / 2001:db8::/32';
  final address = InternetAddress.tryParse(parts[0]);
  final prefix = int.tryParse(parts[1]);
  if (address == null ||
      prefix == null ||
      prefix < 0 ||
      prefix > (address.type == InternetAddressType.IPv4 ? 32 : 128)) {
    return 'CIDR: 192.168.1.0/24 / 2001:db8::/32';
  }
  return null;
}

List<String> settingsRouteAddresses(Config config) =>
    config.networkProps.routeMode == RouteMode.bypassPrivate
    ? defaultBypassPrivateRouteAddress
    : config.patchClashConfig.tun.routeAddress;

VpnOptions settingsVpnOptions(Config config) {
  final vpn = config.vpnProps;
  return VpnOptions(
    enable: vpn.enable,
    port: config.patchClashConfig.mixedPort,
    ipv6: vpn.ipv6,
    dnsHijacking: vpn.dnsHijacking, // legacy storage only
    accessControlProps: vpn.accessControlProps,
    allowBypass: vpn.allowBypass,
    systemProxy: vpn.systemProxy,
    bypassDomain: config.networkProps.bypassDomain,
    stack: config.patchClashConfig.tun.stack.name,
    routeAddress: settingsRouteAddresses(config),
  );
}

Map<String, dynamic> vpnInstanceKey(Config config) {
  final options = settingsVpnOptions(config);
  if (!options.enable) return {'enable': false};
  final access = options.accessControlProps;
  return {
    'enable': true,
    'stack': options.stack,
    'ipv6': options.ipv6,
    'allowBypass': options.allowBypass,
    'routes': options.routeAddress,
    'systemProxy': options.systemProxy,
    if (options.systemProxy) ...{
      'port': options.port,
      'bypassDomain': options.bypassDomain,
    },
    'access': access.enable
        ? {
            'enable': true,
            'mode': access.mode.name,
            'packages': (access.currentList.toSet().toList()..sort()),
          }
        : {'enable': false},
  };
}

/// Only these stored settings participate in network application/rollback.
Map<String, dynamic> runtimeSettings(Config config) => {
  'patch': jsonDecode(jsonEncode(config.patchClashConfig)),
  'overrideDns': config.overrideDns,
  'appendSystemDns': config.networkProps.appendSystemDns,
  'routeMode': config.networkProps.routeMode.name,
  'bypassDomain': config.networkProps.bypassDomain,
  'vpn': {
    'enable': config.vpnProps.enable,
    'ipv6': config.vpnProps.ipv6,
    'allowBypass': config.vpnProps.allowBypass,
    'systemProxy': config.vpnProps.systemProxy,
    'accessControlProps': {
      'enable': config.vpnProps.accessControlProps.enable,
      'mode': config.vpnProps.accessControlProps.mode.name,
      'acceptList': config.vpnProps.accessControlProps.acceptList,
      'rejectList': config.vpnProps.accessControlProps.rejectList,
    },
  },
};

const _hotFields = {
  'allow-lan',
  'log-level',
  'mode',
  'find-process-mode',
  'tcp-concurrent',
  'unified-delay',
  'external-controller',
  'mixed-port',
};

SettingsApplyKind settingsApplyKind(Config before, Config after) {
  if (deepConfigEquals(runtimeSettings(before), runtimeSettings(after))) {
    return SettingsApplyKind.none;
  }
  if (!deepConfigEquals(vpnInstanceKey(before), vpnInstanceKey(after))) {
    return SettingsApplyKind.vpn;
  }
  final oldMap = runtimeSettings(before);
  final newMap = runtimeSettings(after);
  // VPN preferences may change while VPN is disabled. Store for next use.
  oldMap.remove('vpn');
  newMap.remove('vpn');
  oldMap.remove('bypassDomain');
  newMap.remove('bypassDomain');
  final oldPatch = Map<String, dynamic>.from(oldMap['patch'] as Map);
  final newPatch = Map<String, dynamic>.from(newMap['patch'] as Map);
  for (final field in _hotFields) {
    oldPatch.remove(field);
    newPatch.remove(field);
  }
  oldMap['patch'] = oldPatch;
  newMap['patch'] = newPatch;
  return deepConfigEquals(oldMap, newMap)
      ? SettingsApplyKind.hot
      : SettingsApplyKind.reload;
}

/// Roll back only failed leaves still equal to that attempt. Newer edits win.
dynamic rollbackSettingsLeaves(dynamic before, dynamic attempted, dynamic now) {
  if (deepConfigEquals(before, attempted)) return now;
  if (before is Map && attempted is Map && now is Map) {
    final result = Map<String, dynamic>.from(now);
    for (final key in {...before.keys, ...attempted.keys}) {
      if (!before.containsKey(key) &&
          now.containsKey(key) &&
          deepConfigEquals(now[key], attempted[key])) {
        result.remove(key);
      } else if (before.containsKey(key)) {
        final value = rollbackSettingsLeaves(
          before[key],
          attempted[key],
          now[key],
        );
        if (value != null || before[key] == null) result[key as String] = value;
      }
    }
    return result;
  }
  return deepConfigEquals(now, attempted) ? before : now;
}

Config rollbackSettings(
  Config before,
  Config attempted,
  Config now, {
  List<StructuralChange> newerChanges = const [],
}) {
  final rolledBack =
      rollbackSettingsLeaves(
            runtimeSettings(before),
            runtimeSettings(attempted),
            runtimeSettings(now),
          )
          as Map;
  final data = applyStructuralChanges(
    Map<String, dynamic>.from(rolledBack),
    newerChanges,
  );
  final access =
      Map<String, dynamic>.from(now.vpnProps.accessControlProps.toJson())
        ..addAll(
          Map<String, dynamic>.from(data['vpn']['accessControlProps'] as Map),
        );
  final vpn = Map<String, dynamic>.from(now.vpnProps.toJson())
    ..addAll(Map<String, dynamic>.from(data['vpn'] as Map))
    ..['accessControlProps'] = access;
  return now.copyWith(
    patchClashConfig: PatchClashConfig.fromJson(
      Map<String, dynamic>.from(data['patch'] as Map),
    ),
    overrideDns: data['overrideDns'] as bool,
    networkProps: now.networkProps.copyWith(
      appendSystemDns: data['appendSystemDns'] as bool,
      routeMode: RouteMode.values.byName(data['routeMode'] as String),
      bypassDomain: List<String>.from(data['bypassDomain'] as List),
    ),
    vpnProps: VpnProps.fromJson(vpn),
  );
}

AccessControlProps preserveAccessSelection(AccessControlProps access) =>
    access.copyWithNewList(access.currentList.toSet().toList()..sort());

int hiddenAccessSelectionCount(
  AccessControlProps access,
  Iterable<String> visible,
) => access.currentList.toSet().difference(visible.toSet()).length;
