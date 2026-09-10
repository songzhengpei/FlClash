import 'package:fl_clash/services/settings/settings_contract.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'app.dart';
import 'config.dart';
import 'database.dart';

part 'generated/state.g.dart';

@riverpod
GroupsState currentGroupsState(Ref ref) {
  final ownerProfileId = ref.watch(groupsOwnerProfileIdProvider);
  final currentProfileId = ref.watch(currentProfileIdProvider);
  if (ownerProfileId != currentProfileId) {
    return const GroupsState(value: []);
  }

  final mode = ref.watch(
    patchClashConfigProvider.select((state) => state.mode),
  );
  final groups = ref.watch(groupsProvider.select(stripRuntimeNowFromGroups));
  return GroupsState(
    value: switch (mode) {
      Mode.direct => [],
      Mode.global => groups.toList(),
      Mode.rule =>
        groups
            .where((item) => item.hidden == false)
            .where((element) => element.name != GroupName.GLOBAL.name)
            .toList(),
    },
  );
}

@riverpod
NavigationItemsState navigationItemsState(Ref ref) {
  final hasProfiles = ref.watch(
    profilesProvider.select((state) => state.isNotEmpty),
  );
  final hasProxies = ref.watch(
    currentGroupsStateProvider.select((state) => state.value.isNotEmpty),
  );
  final isInit = ref.watch(initProvider);
  return NavigationItemsState(
    value: navigation.getItems(hasProxies: !isInit ? hasProfiles : hasProxies),
  );
}

@riverpod
NavigationItemsState currentNavigationItemsState(Ref ref) {
  final viewWidth = ref.watch(viewWidthProvider);
  final navigationItemsState = ref.watch(navigationItemsStateProvider);
  final navigationItemMode = switch (viewWidth <= maxMobileWidth) {
    true => NavigationItemMode.mobile,
    false => NavigationItemMode.desktop,
  };
  return NavigationItemsState(
    value: navigationItemsState.value
        .where((element) => element.modes.contains(navigationItemMode))
        .toList(),
  );
}

@riverpod
UpdateParams updateParams(Ref ref) {
  final routeMode = ref.watch(
    networkSettingProvider.select((state) => state.routeMode),
  );
  return ref.watch(
    patchClashConfigProvider.select(
      (state) => UpdateParams(
        tun: state.tun.getRealTun(routeMode),
        allowLan: state.allowLan,
        findProcessMode: state.findProcessMode,
        mode: state.mode,
        logLevel: state.logLevel,
        ipv6: state.ipv6,
        tcpConcurrent: state.tcpConcurrent,
        externalController: state.externalController,
        unifiedDelay: state.unifiedDelay,
        mixedPort: state.mixedPort,
      ),
    ),
  );
}

@riverpod
VpnState vpnState(Ref ref) {
  final vpnProps = ref.watch(vpnSettingProvider);
  final stack = ref.watch(
    patchClashConfigProvider.select((state) => state.tun.stack),
  );
  return VpnState(stack: stack, vpnProps: vpnProps);
}

@riverpod
NavigationState navigationState(Ref ref) {
  final pageLabel = ref.watch(currentPageLabelProvider);
  final navigationItems = ref.watch(currentNavigationItemsStateProvider).value;
  final viewMode = ref.watch(viewModeProvider);
  final locale = ref.watch(appSettingProvider).locale;
  final index = navigationItems.lastIndexWhere(
    (element) => element.label == pageLabel,
  );
  final currentIndex = index == -1 ? 0 : index;
  return NavigationState(
    pageLabel: pageLabel,
    navigationItems: navigationItems,
    viewMode: viewMode,
    locale: locale,
    currentIndex: currentIndex,
  );
}

@riverpod
double contentWidth(Ref ref) {
  final viewWidth = ref.watch(viewWidthProvider);
  final sideWidth = ref.watch(sideWidthProvider);
  return viewWidth - sideWidth;
}

@riverpod
DashboardState dashboardState(Ref ref) {
  final dashboardWidgets = ref.watch(
    appSettingProvider.select((state) => state.dashboardWidgets),
  );
  final contentWidth = ref.watch(contentWidthProvider);
  return DashboardState(
    dashboardWidgets: dashboardWidgets,
    contentWidth: contentWidth,
  );
}

@riverpod
ProxiesActionsState proxiesActionsState(Ref ref) {
  final pageLabel = ref.watch(currentPageLabelProvider);
  final hasProviders = ref.watch(
    providersProvider.select((state) => state.isNotEmpty),
  );
  final type = ref.watch(
    proxiesStyleSettingProvider.select((state) => state.type),
  );
  return ProxiesActionsState(
    pageLabel: pageLabel,
    hasProviders: hasProviders,
    type: type,
  );
}

@riverpod
ProfilesState profilesState(Ref ref) {
  final currentProfileId = ref.watch(currentProfileIdProvider);
  final profiles = ref.watch(profilesProvider);
  final columns = ref.watch(
    contentWidthProvider.select((state) => utils.getProfilesColumns(state)),
  );
  return ProfilesState(
    profiles: profiles,
    currentProfileId: currentProfileId,
    columns: columns,
  );
}

@riverpod
GroupsState filterGroupsState(Ref ref, String query) {
  final currentGroups = ref.watch(currentGroupsStateProvider);
  if (query.isEmpty) {
    return currentGroups;
  }
  final groups = filterGroupsByProxyName(currentGroups.value, query);
  return currentGroups.copyWith(value: groups);
}

@riverpod
ProxiesListState proxiesListState(Ref ref) {
  final query = ref.watch(queryProvider(QueryTag.proxies));
  final currentGroups = ref.watch(filterGroupsStateProvider(query));
  final currentUnfoldSet = ref.watch(unfoldSetProvider);
  final cardType = ref.watch(
    proxiesStyleSettingProvider.select((state) => state.cardType),
  );

  final columns = ref.watch(proxiesColumnsProvider);
  return ProxiesListState(
    groups: currentGroups.value,
    currentUnfoldSet: currentUnfoldSet,
    proxyCardType: cardType,
    columns: columns,
  );
}

@riverpod
ProxiesTabState proxiesTabState(Ref ref) {
  final query = ref.watch(queryProvider(QueryTag.proxies));
  final currentGroups = ref.watch(filterGroupsStateProvider(query));
  final currentGroupName = ref.watch(
    currentProfileProvider.select((state) => state?.currentGroupName),
  );
  final cardType = ref.watch(
    proxiesStyleSettingProvider.select((state) => state.cardType),
  );
  final columns = ref.watch(proxiesColumnsProvider);
  return ProxiesTabState(
    groups: currentGroups.value,
    currentGroupName: currentGroupName,
    proxyCardType: cardType,
    columns: columns,
  );
}

@riverpod
bool isStart(Ref ref) {
  return ref.watch(runTimeProvider.select((state) => state != null));
}

@riverpod
VM2<List<String>, String?> proxiesTabControllerState(Ref ref) {
  return ref.watch(
    proxiesTabStateProvider.select(
      (state) => VM2(
        state.groups.map((group) => group.name).toList(),
        state.currentGroupName,
      ),
    ),
  );
}

@riverpod
ProxyGroupSelectorState proxyGroupSelectorState(
  Ref ref,
  String groupName,
  String query,
) {
  final proxiesStyle = ref.watch(proxiesStyleSettingProvider);
  final group = ref.watch(
    currentGroupsStateProvider.select(
      (state) => state.value.getGroup(groupName),
    ),
  );
  final sortNum = ref.watch(sortNumProvider);
  final columns = ref.watch(proxiesColumnsProvider);
  final proxies = group == null
      ? <Proxy>[]
      : query.isEmpty
      ? group.all
      : filterProxiesByName(group.all, query);
  return ProxyGroupSelectorState(
    testUrl: group?.testUrl,
    proxiesSortType: proxiesStyle.sortType,
    proxyCardType: proxiesStyle.cardType,
    sortNum: sortNum,
    groupType: group?.type ?? GroupType.Selector,
    proxies: proxies,
    columns: columns,
  );
}

@riverpod
PackageListSelectorState packageListSelectorState(Ref ref) {
  final packages = ref.watch(packagesProvider);
  final accessControlProps = ref.watch(
    vpnSettingProvider.select((state) => state.accessControlProps),
  );
  return PackageListSelectorState(
    packages: packages,
    accessControlProps: accessControlProps,
  );
}

@riverpod
MoreToolsSelectorState moreToolsSelectorState(Ref ref) {
  final viewMode = ref.watch(viewModeProvider);
  final navigationItems = ref
      .watch(
        navigationItemsStateProvider.select((state) {
          return VM(
            state.value.where((element) {
              final isMore = element.modes.contains(NavigationItemMode.more);
              final isDesktop = element.modes.contains(
                NavigationItemMode.desktop,
              );
              if (isMore && !isDesktop) return true;
              if (viewMode != ViewMode.mobile || !isMore) {
                return false;
              }
              return true;
            }).toList(),
          );
        }),
      )
      .a;

  return MoreToolsSelectorState(navigationItems: navigationItems);
}

@riverpod
String realTestUrl(Ref ref, [String? testUrl]) {
  final currentTestUrl = ref.watch(appSettingProvider).testUrl;
  return testUrl.takeFirstValid([currentTestUrl]);
}

@riverpod
int? delay(Ref ref, {required String proxyName, String? testUrl}) {
  final currentTestUrl = ref.watch(realTestUrlProvider(testUrl));
  final proxyState = ref.watch(realSelectedProxyStateProvider(proxyName));
  final effectiveTestUrl = proxyState.testUrl.takeFirstValid([currentTestUrl]);
  final effectiveProxyName = proxyState.proxyName;
  return ref.watch(
    delayDataSourceProvider.select(
      (state) => state[effectiveTestUrl]?[effectiveProxyName],
    ),
  );
}

@riverpod
Map<String, String> selectedMap(Ref ref) {
  final selectedMap = ref.watch(
    currentProfileProvider.select((state) => state?.selectedMap ?? {}),
  );
  return selectedMap;
}

@riverpod
Map<String, String> computedSelectedMap(Ref ref) {
  return ref.watch(
    currentProfileProvider.select((state) => state?.computedSelectedMap ?? {}),
  );
}

@riverpod
Set<String> unfoldSet(Ref ref) {
  final unfoldSet = ref.watch(
    currentProfileProvider.select((state) => state?.unfoldSet ?? {}),
  );
  return unfoldSet;
}

@riverpod
HotKeyAction getHotKeyAction(Ref ref, HotAction hotAction) {
  return ref.watch(
    hotKeyActionsProvider.select((state) {
      final index = state.indexWhere((item) => item.action == hotAction);
      return index != -1 ? state[index] : HotKeyAction(action: hotAction);
    }),
  );
}

@riverpod
Profile? currentProfile(Ref ref) {
  final profileId = ref.watch(currentProfileIdProvider);
  return ref.watch(
    profilesProvider.select((state) => state.getProfile(profileId)),
  );
}

@riverpod
int proxiesColumns(Ref ref) {
  final contentWidth = ref.watch(contentWidthProvider);
  final proxiesLayout = ref.watch(
    proxiesStyleSettingProvider.select((state) => state.layout),
  );
  return utils.getProxiesColumns(contentWidth, proxiesLayout);
}

@riverpod
SelectedProxyState realSelectedProxyState(Ref ref, String proxyName) {
  final groups = ref.watch(groupsProvider);
  final selectedMap = ref.watch(selectedMapProvider);
  final computedSelectedMap = ref.watch(computedSelectedMapProvider);
  return computeRealSelectedProxyState(
    proxyName,
    groups: groups,
    selectedMap: selectedMap,
    computedSelectedMap: computedSelectedMap,
  );
}

@riverpod
String? proxyName(Ref ref, String groupName) {
  final proxyName = ref.watch(
    selectedMapProvider.select((state) => state[groupName]),
  );
  return proxyName;
}

@riverpod
String? selectedProxyName(Ref ref, String groupName) {
  final proxyName = ref.watch(proxyNameProvider(groupName));
  final group = ref.watch(
    groupsProvider.select((state) => state.getGroup(groupName)),
  );
  if (group == null) return null;
  final cachedNow = ref.watch(
    computedSelectedMapProvider.select((state) => state[groupName]),
  );
  return selectedNameForGroup(
    group,
    selectedMapValue: proxyName,
    cachedComputedNow: cachedNow,
  );
}

@riverpod
String proxyDesc(Ref ref, Proxy proxy) {
  final groupTypeNamesList = GroupType.values.map((e) => e.name).toList();
  if (!groupTypeNamesList.contains(proxy.type)) {
    return proxy.type;
  } else {
    final groups = ref.watch(groupsProvider);
    final index = groups.indexWhere((element) => element.name == proxy.name);
    if (index == -1) return proxy.type;
    final state = ref.watch(realSelectedProxyStateProvider(proxy.name));
    return "${proxy.type}(${state.proxyName.isNotEmpty ? state.proxyName : '*'})";
  }
}

@riverpod
VM3<bool, int, bool> checkIp(Ref ref) {
  final isInit = ref.watch(initProvider);
  final checkIpNum = ref.watch(checkIpNumProvider);
  final containsDetection = ref.watch(
    dashboardStateProvider.select(
      (state) =>
          state.dashboardWidgets.contains(DashboardWidget.networkDetection),
    ),
  );
  return VM3(isInit, checkIpNum, containsDetection);
}

@riverpod
ColorScheme genColorScheme(
  Ref ref,
  Brightness brightness, {
  Color? color,
  bool ignoreConfig = false,
}) {
  final theme = ref.watch(
    themeSettingProvider.select(
      (state) =>
          VM3(state.primaryColor, state.schemeVariant, state.dynamicColor),
    ),
  );

  Color seedColor;
  DynamicSchemeVariant schemeVariant = theme.b;

  if (color != null) {
    seedColor = color;
    if (color.toARGB32() == legacyGraySeedColor) {
      schemeVariant = DynamicSchemeVariant.monochrome;
    }
  } else if (theme.c) {
    seedColor =
        globalState.corePalette
            ?.toColorScheme(brightness: brightness)
            .primary ??
        globalState.accentColor;
    schemeVariant = normalizeDynamicSchemeVariant(theme.b);
  } else if (ignoreConfig) {
    seedColor =
        globalState.corePalette
            ?.toColorScheme(brightness: brightness)
            .primary ??
        globalState.accentColor;
  } else if (theme.a != null) {
    seedColor = Color(theme.a!);
    if (theme.a == legacyGraySeedColor) {
      schemeVariant = DynamicSchemeVariant.monochrome;
    }
  } else {
    seedColor = brightness == Brightness.dark
        ? const Color(0xFF4DA3FF)
        : const Color(0xFF0A84FF);
    schemeVariant = DynamicSchemeVariant.content;
  }

  return ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: brightness,
    dynamicSchemeVariant: schemeVariant,
  );
}

@riverpod
Brightness currentBrightness(Ref ref) {
  final themeMode = ref.watch(
    themeSettingProvider.select((state) => state.themeMode),
  );
  final systemBrightness = ref.watch(systemBrightnessProvider);
  return switch (themeMode) {
    ThemeMode.system => systemBrightness,
    ThemeMode.light => Brightness.light,
    ThemeMode.dark => Brightness.dark,
  };
}

@riverpod
VM3<bool, int, ProxiesSortType> needUpdateGroups(Ref ref) {
  final isProxies = ref.watch(
    currentPageLabelProvider.select((state) => state == PageLabel.proxies),
  );
  final sortNum = ref.watch(sortNumProvider);
  final sortType = ref.watch(
    proxiesStyleSettingProvider.select((state) => state.sortType),
  );
  return VM3(isProxies, sortNum, sortType);
}

@riverpod
SharedState sharedState(Ref ref) {
  ref.watch((appSettingProvider).select((state) => state.locale));
  final currentProfileVM2 = ref.watch(
    currentProfileProvider.select(
      (state) => VM2(state?.label ?? '', state?.selectedMap ?? {}),
    ),
  );
  final appSettingVM3 = ref.watch(
    appSettingProvider.select(
      (state) => VM2(state.onlyStatisticsProxy, state.testUrl),
    ),
  );



  final currentProfileName = currentProfileVM2.a;
  final selectedMap = currentProfileVM2.b;
  final onlyStatisticsProxy = appSettingVM3.a;
  final testUrl = appSettingVM3.b;


  return SharedState(
    currentProfileName: currentProfileName,
    onlyStatisticsProxy: onlyStatisticsProxy,
    stopText: currentAppLocalizations.stop,
    stopTip: currentAppLocalizations.stopVpn,
    startTip: currentAppLocalizations.startVpn,
    setupParams: SetupParams(selectedMap: selectedMap, testUrl: testUrl),
    vpnOptions: settingsVpnOptions(ref.watch(configProvider)),
  );
}

@riverpod
double overlayTopOffset(Ref ref) {
  final isMobileView = ref.watch(isMobileViewProvider);
  final version = ref.watch(versionProvider);
  ref.watch(viewSizeProvider);
  double top = kHeaderHeight;
  if ((version <= 10 || !isMobileView) && system.isMacOS || !system.isDesktop) {
    top = 0;
  }
  return kToolbarHeight + top;
}

@riverpod
Profile? profile(Ref ref, int? profileId) {
  return ref.watch(
    profilesProvider.select((state) => state.getProfile(profileId)),
  );
}

@riverpod
OverwriteType overwriteType(Ref ref, int? profileId) {
  return ref.watch(
    profileProvider(
      profileId,
    ).select((state) => state?.overwriteType ?? OverwriteType.standard),
  );
}

@riverpod
Future<ClashConfig> clashConfig(Ref ref, int profileId) async {
  final configMap = await coreController.getConfig(profileId);
  final clashConfig = ClashConfig.fromJson(configMap);
  final Map<String, String> proxyTypeMap = {};
  for (final proxy in clashConfig.proxies) {
    proxyTypeMap[proxy.name] = proxy.type;
  }
  for (final proxyGroup in clashConfig.proxyGroups) {
    proxyTypeMap[proxyGroup.name] = proxyGroup.type.value;
  }
  return clashConfig.copyWith(proxyTypeMap: proxyTypeMap);
}

@riverpod
CustomOverwriteDate customOverwriteDate(Ref ref, int profileId) {
  final vm3 = ref.watch(
    clashConfigProvider(profileId).select((state) {
      return VM3(
        state.value?.proxies ?? [],
        state.value?.subRules ?? [],
        state.value?.proxyProviders ?? [],
      );
    }),
  );
  final proxies = vm3.a;
  final subRules = vm3.b.toSet();
  final proxyProviders = vm3.c.toSet();
  final proxyGroups =
      ref
          .watch(
            proxyGroupsProvider(profileId).select((state) {
              return VM(state.value);
            }),
          )
          .a ??
      [];
  final ruleTargets = {
    ...RuleTarget.baseTargets,
    ...proxies.map((item) => item.name),
    ...proxyGroups.map((item) => item.name),
  };
  return CustomOverwriteDate(
    proxyProviders: proxyProviders,
    proxies: proxies,
    proxyGroups: proxyGroups,
    ruleTargets: ruleTargets,
    subRules: subRules,
  );
}

@riverpod
bool customOverwriteTargetIsValid(Ref ref, int profileId, String? target) {
  final valid = ref.watch(
    customOverwriteDateProvider(
      profileId,
    ).select((state) => state.ruleTargets.contains(target)),
  );
  return valid;
}

@riverpod
bool customOverwriteProxyProviderIsValid(
  Ref ref,
  int profileId,
  String? providerName,
) {
  final valid = ref.watch(
    customOverwriteDateProvider(
      profileId,
    ).select((state) => state.proxyProviders.contains(providerName)),
  );
  return valid;
}

@riverpod
bool customOverwriteUseIsValid(Ref ref, int profileId, List<String> use) {
  final valid = ref.watch(
    customOverwriteDateProvider(
      profileId,
    ).select((state) => state.proxyProviders.containsAll(use)),
  );
  return valid;
}

@riverpod
bool customOverwriteProxiesIsValid(
  Ref ref,
  int profileId,
  List<String> proxies,
) {
  final valid = ref.watch(
    customOverwriteDateProvider(
      profileId,
    ).select((state) => state.ruleTargets.containsAll(proxies)),
  );
  return valid;
}

@riverpod
bool customOverwriteGroupIsValid(
  Ref ref,
  int profileId,
  ProxyGroup proxyGroup,
) {
  final proxies = proxyGroup.proxies ?? [];
  final use = proxyGroup.use ?? [];
  final valid = ref.watch(
    customOverwriteDateProvider(profileId).select(
      (state) =>
          state.ruleTargets.containsAll(proxies) &&
          state.proxyProviders.containsAll(use),
    ),
  );
  return valid;
}

@riverpod
Future<SetupState> setupState(Ref ref, int? profileId) async {
  final profile = ref.watch(profileProvider(profileId));
  final scriptId = profile?.scriptId;
  final profileLastUpdateDate = profile?.lastUpdateDate?.millisecondsSinceEpoch;
  final overwriteType = profile?.overwriteType ?? OverwriteType.standard;
  final dns = ref.watch(patchClashConfigProvider.select((state) => state.dns));
  final overrideDns = ref.watch(overrideDnsProvider);
  List<ProxyGroup> proxyGroups = [];
  List<Rule> rules = [];
  List<Rule> addedRules = [];
  Script? script;
  if (profileId != null) {
    if (overwriteType == OverwriteType.standard) {
      addedRules = await database.rulesDao.queryAddedRules(profileId).get();
    } else if (overwriteType == OverwriteType.script) {
      script = scriptId == null
          ? null
          : await database.scriptsDao.get(scriptId).getSingleOrNull();
    } else {
      rules = await database.rulesDao.queryProfileCustomRules(profileId).get();
      proxyGroups = await database.proxyGroupsDao.query(profileId).get();
    }
  }
  return SetupState(
    rules: rules,
    proxyGroups: proxyGroups,
    profileId: profileId,
    profileLastUpdateDate: profileLastUpdateDate,
    overwriteType: overwriteType,
    addedRules: addedRules,
    script: script,
    overrideDns: overrideDns,
    dns: dns,
  );
}

@riverpod
class AccessControlState extends _$AccessControlState
    with AutoDisposeNotifierMixin {
  @override
  AccessControlProps build() => const AccessControlProps();
}

@Riverpod(name: 'proxyGroupProvider')
class ProxyGroupProvider extends _$ProxyGroupProvider
    with AutoDisposeNotifierMixin {
  @override
  ProxyGroup build() {
    throw 'Initialization proxyGroupProvider error';
  }
}

@Riverpod(name: 'ruleProvider')
class RuleProvider extends _$RuleProvider with AutoDisposeNotifierMixin {
  @override
  Rule build() {
    return throw 'Initialization RuleProvider error';
  }
}

@riverpod
bool suspend(Ref ref) {
  return false;
}

@riverpod
class ProxyGroupsSnapshot extends _$ProxyGroupsSnapshot {
  @override
  ProxyGroupsSnapshotState build() => const ProxyGroupsSnapshotState();

  void none() => state = const ProxyGroupsSnapshotState();

  void stale({DateTime? updatedAt}) => state = ProxyGroupsSnapshotState(
    freshness: ProxyGroupsFreshnessState.stale,
    updatedAt: updatedAt,
    hydrated: true,
  );

  void refreshing() => state = ProxyGroupsSnapshotState(
    freshness: ProxyGroupsFreshnessState.refreshing,
    updatedAt: state.updatedAt,
    hydrated: state.hydrated,
  );

  void fresh() => state = ProxyGroupsSnapshotState(
    freshness: ProxyGroupsFreshnessState.fresh,
    updatedAt: DateTime.now(),
    hydrated: true,
  );

  void failed(Object error) => state = ProxyGroupsSnapshotState(
    freshness: ProxyGroupsFreshnessState.failed,
    updatedAt: state.updatedAt,
    error: error,
    hydrated: state.hydrated,
  );
}

@Riverpod(keepAlive: true)
class GroupsOwnerProfileId extends _$GroupsOwnerProfileId {
  @override
  int? build() => null;

  void set(int? profileId) => state = profileId;
}
