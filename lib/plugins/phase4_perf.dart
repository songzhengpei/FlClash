import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/providers/settings_apply.dart';
import 'package:fl_clash/services/settings/settings_contract.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/proxies/common.dart';
import 'package:flutter/services.dart';

typedef Phase4Reselect = void Function();
typedef Phase4ScrollBy = void Function(double dy);
typedef Phase4KeepExperiment = void Function();

/// ADB → MainActivity extras (profile/debug) → this channel.
/// No-op unless [NavigationTrace.enabled].
class Phase4PerfCommands {
  Phase4PerfCommands._();

  static const _channel = MethodChannel('$methodChannelPrefix/phase4_perf');
  static bool _attached = false;
  static Phase4Reselect? onReselect;
  static Phase4ScrollBy? onScrollBy;
  static Phase4KeepExperiment? onKeepExperiment;

  /// Profile/perf experiment only. `null` = product `NavigationItem.keep`.
  static bool? dashboardKeepOverride;
  static ({bool enabled, int intervalMinutes})? _savedHealthConfig;
  static Config? _savedSettings;

  static void attach() {
    if (!NavigationTrace.enabled || _attached) {
      return;
    }
    _attached = true;
    _channel.setMethodCallHandler(_handle);
    NavigationTrace.mark('nav_listener_ready');
  }

  static Future<dynamic> _handle(MethodCall call) async {
    final args = _stringMap(call.arguments);
    switch (call.method) {
      case 'ping':
        return _ping();
      case 'navigate':
        return _navigate(args['page']);
      case 'reselect':
        onReselect?.call();
        return 'ok';
      case 'scroll_by':
        final dy = double.tryParse(args['dy'] ?? '') ?? 800;
        onScrollBy?.call(dy);
        return 'ok';
      case 'dump_counts':
        NavigationTrace.dumpCounts(
          dashboardKeepOverride: dashboardKeepOverride,
        );
        return {
          'mounts': NavigationTrace.mountCounts(),
          'builds': NavigationTrace.buildCounts(),
          'dashboard_keep_override': dashboardKeepOverride,
        };
      case 'keep_dashboard':
        return _keepDashboard(args['keep'] ?? args['value']);
      case 'proxy_session':
        return _proxySession(args['value'] ?? args['state']);
      case 'delay_test':
        return _delayTest(args['max']);
      case 'delay_one':
        return _delayOne(args['name']);
      case 'select_race':
        return _selectRace(args['pattern']);
      case 'select_named':
        return _selectNamed(args['group'], args['proxy']);
      case 'select_cross':
        return _selectCross();
      case 'select_fixed':
        return _selectFixed(args['action']);
      case 'unfold':
        return _unfold(args['group'], args['expand'] ?? args['value']);
      case 'counts':
        return _counts(args['op'] ?? args['value'], args['event']);
      case 'refresh_groups':
        return _refreshGroups();
      case 'sort_bump':
        return _sortBump();
      case 'ipc_run':
        return _ipcRun(args['run_id'] ?? args['value']);
      case 'ipc_window':
        return _ipcWindow(
          args['value'] ?? args['state'],
          args['page'],
          args['auto_end_ms'],
        );
      case 'ipc_dump':
        return _ipcDump(args['reason'] ?? args['event']);
      case 'vpn_dump':
        return _vpnDump();
      case 'settings_probe':
        return _settingsProbe(args);
      case 'vpn_action':
        return _vpnAction(args['action'] ?? args['value']);
      case 'smart_auto_stop_config':
        return _smartAutoStopConfig(
          args['enabled'] ?? args['value'],
          args['network'],
        );
      case 'health_test_config':
        return _healthTestConfig(args['action'] ?? args['value']);
      case 'smart_action':
        return _smartAction(args['action'] ?? args['value']);
      default:
        return null;
    }
  }

  static Map<String, Object?> _ping() {
    final pages = <String>[];
    String current = 'unknown';
    try {
      final container = globalState.container;
      current = container.read(currentPageLabelProvider).name;
      pages.addAll(
        container
            .read(currentNavigationItemsStateProvider)
            .value
            .map((item) => item.label.name),
      );
    } catch (_) {
      pages.addAll(const ['dashboard', 'proxies', 'profiles', 'tools']);
    }
    NavigationTrace.mark(
      'nav_pong',
      extras: {
        'current': current,
        'pages': pages.join(','),
        'dashboard_keep_override': dashboardKeepOverride,
      },
    );
    return {'current': current, 'pages': pages};
  }

  static String _proxySession(String? raw) {
    final on = raw == 'start' || raw == 'on' || raw == '1' || raw == 'true';
    if (on) {
      ProxyTrace.beginSession();
      return 'start';
    }
    ProxyTrace.endSession();
    return 'end';
  }

  static String _delayTest(String? maxRaw) {
    ProxyTrace.resetDelayCounters();
    final groups = getCurrentGroups();
    final proxies = <Proxy>[];
    for (final group in groups) {
      proxies.addAll(group.all);
    }
    final max = int.tryParse(maxRaw ?? '') ?? proxies.length;
    final slice = max > 0 && max < proxies.length
        ? proxies.sublist(0, max)
        : proxies;
    StartupTrace.mark(
      'delay_test_dispatch',
      extras: {'count': slice.length, 'max': max},
    );
    unawaited(delayTest(slice));
    return '${slice.length}';
  }

  /// Rapid Selector taps through the product selectedMap + debounce path.
  static String _selectRace(String? pattern) {
    final groups = getCurrentGroups();
    Group? group;
    for (final candidate in groups) {
      if (candidate.type == GroupType.Selector && candidate.all.length >= 3) {
        group = candidate;
        break;
      }
    }
    if (group == null) {
      StartupTrace.mark(
        'proxy_select_race_skip',
        extras: {'reason': 'no_selector'},
      );
      return 'no_selector';
    }
    final a = group.all[0].name;
    final b = group.all[1].name;
    final c = group.all[2].name;
    final seq = pattern == 'aba' ? [a, b, a] : [a, b, c];
    for (final name in seq) {
      applyProxyGroupMemberTap(group: group, tappedName: name);
    }
    StartupTrace.mark(
      'proxy_select_race_issued',
      extras: {
        'group': group.name,
        'pattern': pattern ?? 'abc',
        'seq': seq.join(','),
      },
    );
    return '${group.name}:${seq.join(',')}';
  }

  static String _selectNamed(String? groupName, String? proxyName) {
    final groups = getCurrentGroups();
    Group? group;
    if (groupName != null && groupName.isNotEmpty) {
      group = groups.getGroup(groupName);
    }
    if (group == null) {
      for (final candidate in groups) {
        if (candidate.type.supportsManualSelection &&
            candidate.all.isNotEmpty) {
          group = candidate;
          break;
        }
      }
    }
    if (group == null || group.all.isEmpty) {
      StartupTrace.mark(
        'proxy_select_named_skip',
        extras: {'reason': 'no_group'},
      );
      return 'no_group';
    }
    Proxy proxy = group.all.length > 1 ? group.all[1] : group.all.first;
    if (proxyName != null && proxyName.isNotEmpty) {
      for (final item in group.all) {
        if (item.name == proxyName) {
          proxy = item;
          break;
        }
      }
    }
    final applied = applyProxyGroupMemberTap(
      group: group,
      tappedName: proxy.name,
    );
    StartupTrace.mark(
      'proxy_select_named',
      extras: {'group': group.name, 'proxy': proxy.name, 'applied': applied},
    );
    return applied ? '${group.name}:${proxy.name}' : 'ignored';
  }

  static String _selectCross() {
    final groups = getCurrentGroups()
        .where(
          (group) =>
              group.type.supportsManualSelection && group.all.length >= 2,
        )
        .toList();
    if (groups.length < 2) {
      StartupTrace.mark(
        'proxy_select_cross_skip',
        extras: {'reason': 'need_two_groups'},
      );
      return 'need_two_groups';
    }
    final a = groups[0];
    final b = groups[1];
    applyProxyGroupMemberTap(group: a, tappedName: a.all[1].name);
    applyProxyGroupMemberTap(group: b, tappedName: b.all[1].name);
    StartupTrace.mark(
      'proxy_select_cross_issued',
      extras: {
        'g1': a.name,
        'g2': b.name,
        'p1': a.all[1].name,
        'p2': b.all[1].name,
      },
    );
    return '${a.name},${b.name}';
  }

  static String _selectFixed(String? action) {
    final groups = getCurrentGroups();
    Group? group;
    for (final candidate in groups) {
      if (candidate.type.supportsFixedSelection && candidate.all.isNotEmpty) {
        group = candidate;
        break;
      }
    }
    if (group == null) {
      StartupTrace.mark(
        'proxy_select_fixed_skip',
        extras: {'reason': 'no_urltest'},
      );
      return 'no_urltest';
    }
    final target = action == 'unfix'
        ? (group.fixed != null && group.fixed!.isNotEmpty
              ? group.fixed!
              : group.all.first.name)
        : group.all.first.name;
    final applied = applyProxyGroupMemberTap(group: group, tappedName: target);
    StartupTrace.mark(
      'proxy_select_fixed',
      extras: {
        'group': group.name,
        'proxy': target,
        'action': action ?? 'pin',
        'fixed': group.fixed ?? 'null',
        'applied': applied,
      },
    );
    return applied ? '${group.name}:$target' : 'ignored';
  }

  static String _unfold(String? groupName, String? expandRaw) {
    final groups = getCurrentGroups();
    final name = (groupName != null && groupName.isNotEmpty)
        ? groupName
        : (groups.isNotEmpty ? groups.first.name : '');
    if (name.isEmpty) {
      return 'no_group';
    }
    final expand =
        expandRaw != '0' && expandRaw != 'false' && expandRaw != 'collapse';
    final profile = globalState.container.read(currentProfileProvider);
    final current = Set<String>.from(profile?.unfoldSet ?? <String>{});
    if (expand) {
      current.add(name);
    } else {
      current.remove(name);
    }
    updateCurrentUnfoldSet(current);
    StartupTrace.mark(
      'proxy_unfold',
      extras: {'group': name, 'expand': expand},
    );
    return '$name:${expand ? 'expand' : 'collapse'}';
  }

  static Map<String, Object?> _counts(String? opRaw, String? eventRaw) {
    final op = opRaw ?? 'dump';
    final event = eventRaw ?? '';
    if (op == 'reset') {
      ProxyTrace.resetEventScope(event: event);
      return {'op': 'reset', 'event': event};
    }
    return ProxyTrace.dumpEventScope(event: event);
  }

  static String _delayOne(String? name) {
    final groups = getCurrentGroups();
    Proxy? proxy;
    if (name != null && name.isNotEmpty) {
      for (final group in groups) {
        for (final item in group.all) {
          if (item.name == name) {
            proxy = item;
            break;
          }
        }
      }
    }
    proxy ??= groups.isNotEmpty && groups.first.all.isNotEmpty
        ? groups.first.all.first
        : null;
    if (proxy == null) {
      return 'no_proxy';
    }
    unawaited(proxyDelayTest(proxy));
    return proxy.name;
  }

  static String _refreshGroups() {
    globalState.container
        .read(proxiesActionProvider.notifier)
        .updateGroupsDebounce();
    StartupTrace.mark('proxy_refresh_groups');
    return 'ok';
  }

  static String _sortBump() {
    globalState.container.read(sortNumProvider.notifier).add();
    StartupTrace.mark('proxy_sort_bump');
    return 'ok';
  }

  static String _ipcRun(String? id) {
    final runId = (id == null || id.isEmpty) ? 'ipc' : id;
    CoreIpcTrace.beginRun(id: runId);
    return runId;
  }

  static String _ipcWindow(String? raw, String? page, String? autoEndRaw) {
    final on = raw == 'start' || raw == 'on' || raw == '1' || raw == 'true';
    if (on) {
      CoreIpcTrace.beginWindow(
        page: page ?? '',
        autoEndMs: int.tryParse(autoEndRaw ?? ''),
      );
      return CoreIpcTrace.windowId;
    }
    CoreIpcTrace.endWindow();
    return 'end';
  }

  static Map<String, Object?> _ipcDump(String? reason) {
    return CoreIpcTrace.dump(reason: reason ?? 'dump');
  }

  /// Profile/debug harness only; uses the same committed providers as the UI.
  /// Never accepts arbitrary config, profile content, or executable code.
  static Future<Map<String, Object?>> _settingsProbe(Map<String, String> args) async {
    final container = globalState.container;
    container.read(settingsApplyProvider);
    final current = container.read(configProvider);
    final operation = args['op'] ?? 'dump';
    var next = current;
    if (operation == 'set') {
      _savedSettings ??= current;
      final value = args['value'] ?? '';
      final enabled = value == 'true';
      next = switch (args['field']) {
        'allowLan' => current.copyWith.patchClashConfig(allowLan: enabled),
        'mixedPort' => current.copyWith.patchClashConfig(mixedPort: int.parse(value)),
        'coreIpv6' => current.copyWith.patchClashConfig(ipv6: enabled),
        'dnsIpv6' => current.copyWith.patchClashConfig.dns(ipv6: enabled),
        'dnsListen' => current.copyWith.patchClashConfig.dns(listen: value),
        'overrideDns' => current.copyWith(overrideDns: enabled),
        'stack' => current.copyWith.patchClashConfig.tun(stack: TunStack.values.byName(value)),
        'route' => current.copyWith.networkProps(routeMode: RouteMode.config)
            .copyWith.patchClashConfig.tun(routeAddress: value.isEmpty ? [] : value.split(';')),
        'vpnIpv6' => current.copyWith.vpnProps(ipv6: enabled),
        'systemProxy' => current.copyWith.vpnProps(systemProxy: enabled),
        _ => throw ArgumentError('Unsupported settings probe field'),
      };
    } else if (operation == 'restore' && _savedSettings != null) {
      next = _savedSettings!;
      _savedSettings = null;
    } else if (operation == 'retry') {
      container.read(settingsApplyProvider.notifier).retry();
    }
    if (next != current) {
      container.read(patchClashConfigProvider.notifier).value = next.patchClashConfig;
      container.read(vpnSettingProvider.notifier).value = next.vpnProps;
      container.read(networkSettingProvider.notifier).value = next.networkProps;
      container.read(overrideDnsProvider.notifier).value = next.overrideDns;
    }
    final status = container.read(settingsApplyProvider);
    final config = container.read(configProvider);
    final snapshot = <String, Object?>{
      'operation': operation,
      'phase': status.phase.name,
      'error': status.error,
      'allow_lan': config.patchClashConfig.allowLan,
      'mixed_port': config.patchClashConfig.mixedPort,
      'core_ipv6': config.patchClashConfig.ipv6,
      'dns_ipv6': config.patchClashConfig.dns.ipv6,
      'vpn_ipv6': config.vpnProps.ipv6,
      'stack': config.patchClashConfig.tun.stack.name,
      'route_address': settingsVpnOptions(config).routeAddress,
      'native': await service?.getSessionSnapshot(),
    };
    StartupTrace.mark('settings_probe', extras: snapshot);
    return snapshot;
  }

  static Map<String, Object?> _vpnDump() {
    final container = globalState.container;
    final snapshot = <String, Object?>{
      'flutter_is_start': container.read(isStartProvider),
      'flutter_smart_stopped': container.read(isSmartStoppedProvider),
      'flutter_run_time': container.read(runTimeProvider),
      'flutter_suspend': container.read(suspendProvider),
      'core_status': container.read(coreStatusProvider).name,
      'core_ready': coreController.isCompleted,
    };
    StartupTrace.mark('vpn_flutter_state', extras: snapshot);
    return snapshot;
  }

  static Future<Map<String, Object?>> _vpnAction(String? action) async {
    if (action != 'start' && action != 'stop') {
      return {'error': 'unsupported_action', 'action': action};
    }
    StartupTrace.mark(
      'vpn_action_requested',
      extras: {'action': action, 'source': 'phase4_flutter_ui'},
    );
    await globalState.container
        .read(setupActionProvider.notifier)
        .updateStatus(action == 'start');
    final snapshot = _vpnDump();
    StartupTrace.mark(
      'vpn_action_complete',
      extras: {
        'action': action,
        'source': 'phase4_flutter_ui',
        'flutter_is_start': snapshot['flutter_is_start'],
      },
    );
    return snapshot;
  }

  static Map<String, Object?> _smartAutoStopConfig(
    String? enabledRaw,
    String? network,
  ) {
    final enabled = enabledRaw == 'true' || enabledRaw == '1';
    final container = globalState.container;
    final current = container.read(vpnSettingProvider);
    container.read(vpnSettingProvider.notifier).value = current.copyWith(
      smartAutoStop: enabled,
      smartAutoStopNetworks: enabled ? [network ?? '0.0.0.0/0'] : const [],
    );
    return {
      'enabled': enabled,
      'networks': enabled ? (network ?? '0.0.0.0/0') : '',
    };
  }

  static Map<String, Object?> _healthTestConfig(String? action) {
    final container = globalState.container;
    final notifier = container.read(
      healthObservationSchedulerProvider.notifier,
    );
    var state = container.read(healthObservationSchedulerProvider);
    if (action == 'save_enable' || action == 'save_disable') {
      _savedHealthConfig ??= (
        enabled: state.enabled,
        intervalMinutes: state.intervalMinutes,
      );
      if (action == 'save_enable') {
        notifier.setIntervalMinutes(20);
        notifier.setEnabled(true);
        notifier.markDue();
      } else {
        notifier.setEnabled(false);
      }
      state = container.read(healthObservationSchedulerProvider);
    } else if (action == 'enable_due') {
      notifier.setIntervalMinutes(20);
      notifier.setEnabled(true);
      notifier.markDue();
      state = container.read(healthObservationSchedulerProvider);
    } else if (action == 'restore') {
      final saved = _savedHealthConfig;
      if (saved != null) {
        notifier.setIntervalMinutes(saved.intervalMinutes);
        notifier.setEnabled(saved.enabled);
        _savedHealthConfig = null;
        state = container.read(healthObservationSchedulerProvider);
      }
    }
    final snapshot = <String, Object?>{
      'enabled': state.enabled,
      'interval_minutes': state.intervalMinutes,
      'is_observing': state.isObserving,
      'next_eligible_at': state.nextEligibleAt?.toIso8601String() ?? 'null',
      'total_observations': state.totalObservations,
      'successful_observations': state.successfulObservations,
      'skipped_observations': state.skippedObservations,
      'saved': _savedHealthConfig != null,
    };
    StartupTrace.mark('health_observation_config', extras: snapshot);
    return snapshot;
  }

  static Future<Map<String, Object?>> _smartAction(String? action) async {
    final notifier = globalState.container.read(
      smartAutoStopManagerProvider.notifier,
    );
    if (action == 'pause') {
      await notifier.pauseNow();
    } else if (action == 'resume') {
      await notifier.resumeNow();
    } else {
      return {'error': 'unsupported_action', 'action': action};
    }
    return _vpnDump();
  }

  static String _keepDashboard(String? raw) {
    if (raw == 'clear' || raw == 'null') {
      dashboardKeepOverride = null;
    } else {
      dashboardKeepOverride = raw == 'true' || raw == '1';
    }
    NavigationTrace.mark(
      'nav_keep_dashboard',
      extras: {'keep': dashboardKeepOverride},
    );
    onKeepExperiment?.call();
    return '${dashboardKeepOverride ?? 'product'}';
  }

  static String _navigate(String? raw) {
    final page = _parsePage(raw);
    if (page == null) {
      return 'unknown_page';
    }
    globalState.container.read(currentPageLabelProvider.notifier).toPage(page);
    return page.name;
  }

  static PageLabel? _parsePage(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    for (final label in PageLabel.values) {
      if (label.name == raw) {
        return label;
      }
    }
    return null;
  }

  static Map<String, String> _stringMap(Object? arguments) {
    if (arguments is Map) {
      return arguments.map((key, value) => MapEntry('$key', '$value'));
    }
    return const {};
  }
}
