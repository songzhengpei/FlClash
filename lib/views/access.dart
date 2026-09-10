import 'package:fl_clash/services/settings/settings_contract.dart';
import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/surge/surge.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AccessView extends ConsumerStatefulWidget {
  const AccessView({super.key});

  @override
  ConsumerState<AccessView> createState() => _AccessViewState();
}

class _AccessViewState extends ConsumerState<AccessView> {
  final GlobalKey<CommonScaffoldState> _scaffoldKey = GlobalKey();
  late ScrollController _controller;
  List<String>? _pinedList;
  bool _isInit = false;
  AccessControlMode? _lastMode;

  final _completer = Completer();

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
    _completer.complete(ref.read(systemActionProvider.notifier).getPackages());
    final accessControl = ref
        .read(vpnSettingProvider.select((state) => state.accessControlProps))
        .copyWith();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(accessControlStateProvider.notifier).value = accessControl;
      _isInit = true;
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _buildSelectedAllButton({
    required bool isSelectedAll,
    required List<String> allValueList,
  }) {
    void onPressed() {
      ref.read(accessControlStateProvider.notifier).update((state) {
        final newSet = Set<String>.from(state.currentList);
        final isSelectedAll = newSet.containsAll(allValueList);
        if (isSelectedAll) {
          newSet.removeAll(allValueList);
        } else {
          newSet.addAll(allValueList);
        }
        return state.copyWithNewList(newSet.toList());
      });
    }

    final appLocalizations = context.appLocalizations;
    return FadeRotationScaleBox(
      alignment: Alignment.centerRight,
      child: isSelectedAll
          ? FloatingActionButton.extended(
              key: const ValueKey(true),
              onPressed: onPressed,
              label: Text(appLocalizations.cancelSelectAll),
              icon: const Icon(SurgeIcons.deselect),
            )
          : FloatingActionButton.extended(
              key: const ValueKey(false),
              tooltip: appLocalizations.selectAll,
              onPressed: onPressed,
              label: Text(appLocalizations.selectAll),
              icon: const Icon(SurgeIcons.selectAll),
            ),
    );
  }

  Future<void> _intelligentSelected() async {
    final packageNames = ref.read(
      packagesProvider.select((state) => state.map((item) => item.packageName)),
    );
    if (packageNames.isEmpty) {
      return;
    }
    final selectedPackageNames =
        (await globalState.loadingRun<List<String>>(() async {
          return await app?.getChinaPackageNames() ?? [];
        }, tag: LoadingTag.access))?.toSet() ??
        {};
    final acceptList = packageNames
        .where((item) => !selectedPackageNames.contains(item))
        .toList();
    final rejectList = packageNames
        .where((item) => selectedPackageNames.contains(item))
        .toList();
    ref
        .read(accessControlStateProvider.notifier)
        .update(
          (state) =>
              state.copyWith(acceptList: acceptList, rejectList: rejectList),
        );
  }

  Future<void> _handleToSetting() async {
    await showSheet<int>(
      context: context,
      props: const SheetProps(isScrollControlled: true),
      builder: (context) {
        final appLocalizations = context.appLocalizations;
        return AdaptiveSheetScaffold(
          body: const AccessControlPanel(),
          title: appLocalizations.accessControlSettings,
          appBarActions: const [],
        );
      },
    );
  }

  void _handleSelected(String packageName) {
    ref.read(accessControlStateProvider.notifier).update((state) {
      final newSet = Set<String>.from(state.currentList)
        ..addOrRemove(packageName);
      return state.copyWithNewList(newSet.toList());
    });
  }

  void _handleToggle() {
    ref.read(accessControlStateProvider.notifier).update((state) {
      return state.copyWith(enable: !state.enable);
    });
  }

  void _handleSearch() {
    _scaffoldKey.currentState?.handleToSearch();
  }

  Future<void> _handleBack() async {
    final appLocalizations = context.appLocalizations;
    final res = await globalState.showMessage(
      title: appLocalizations.tip,
      message: TextSpan(text: appLocalizations.saveChanges),
    );
    if (res == true) {
      _handleSave();
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  AccessControlProps _getRealAccessControlProps(
    AccessControlProps accessControl,
  ) {
    return preserveAccessSelection(accessControl);
  }

  void _handleSave() {
    final accessControl = ref.read(accessControlStateProvider);
    final realAccessControl = _getRealAccessControlProps(accessControl);
    ref
        .read(vpnSettingProvider.notifier)
        .update(
          (state) => state.copyWith(accessControlProps: realAccessControl),
        );
    ref.read(accessControlStateProvider.notifier).value = realAccessControl;
  }

  Future<void> _exportToClipboard() async {
    await globalState.safeRun(() {
      final currentList = ref.read(
        accessControlStateProvider.select((state) => state.currentList),
      );
      Clipboard.setData(ClipboardData(text: currentList.join('\n')));
    });
  }

  Future<void> _importFormClipboard() async {
    await globalState.safeRun(() async {
      final data = await Clipboard.getData('text/plain');
      final text = data?.text;
      if (text == null) return;
      final list = text.split('\n');
      ref
          .read(accessControlStateProvider.notifier)
          .update((state) => state.copyWithNewList(list.toSet().toList()));
    });
  }

  SlAppBarAction _buildAction({
    required bool enable,
    required bool hasChanges,
  }) {
    final appLocalizations = context.appLocalizations;
    if (hasChanges) {
      return SlAppBarIconAction(
        icon: SurgeIcons.confirm,
        tooltip: appLocalizations.save,
        onPressed: _handleSave,
      );
    }
    return SlAppBarOverflowAction(
      tooltip: appLocalizations.more,
      popup: CommonPopupMenu(
        items: [
          PopupMenuItemData(
            icon: SurgeIcons.swap,
            label: enable ? appLocalizations.turnOff : appLocalizations.turnOn,
            onPressed: _handleToggle,
          ),
          PopupMenuItemData(
            icon: SurgeIcons.search,
            label: appLocalizations.search,
            onPressed: _handleSearch,
          ),
          PopupMenuItemData(
            icon: SurgeIcons.tune,
            label: appLocalizations.settings,
            onPressed: _handleToSetting,
          ),
          PopupMenuItemData(
            icon: SurgeIcons.emergency,
            label: appLocalizations.action,
            subItems: [
              PopupMenuItemData(
                icon: SurgeIcons.autoAwesome,
                label: appLocalizations.intelligentSelected,
                onPressed: _intelligentSelected,
              ),
              PopupMenuItemData(
                icon: SurgeIcons.copy,
                label: appLocalizations.clipboardExport,
                onPressed: _exportToClipboard,
              ),
              PopupMenuItemData(
                icon: SurgeIcons.paste,
                label: appLocalizations.clipboardImport,
                onPressed: _importFormClipboard,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildContent({
    required List<Package> packages,
    required List<String> valueList,
  }) {
    return FutureBuilder(
      future: _completer.future,
      builder: (context, snapshot) {
        final appLocalizations = context.appLocalizations;
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        return packages.isEmpty
            ? NullStatus(label: appLocalizations.noData)
            : CommonScrollBar(
                controller: _controller,
                child: ListView.separated(
                  controller: _controller,
                  padding: EdgeInsets.fromLTRB(
                    16,
                    12,
                    16,
                    32 + MediaQuery.paddingOf(context).bottom,
                  ),
                  itemCount: packages.length,
                  separatorBuilder: (_, _) {
                    final surge = SurgeTheme.of(context);
                    return ColoredBox(
                      color: surge.card,
                      child: Divider(height: 0, color: surge.separator),
                    );
                  },
                  itemBuilder: (_, index) {
                    final surge = SurgeTheme.of(context);
                    final package = packages[index];
                    final isFirst = index == 0;
                    final isLast = index == packages.length - 1;
                    return ClipRRect(
                      borderRadius: BorderRadius.vertical(
                        top: isFirst ? const Radius.circular(18) : Radius.zero,
                        bottom: isLast
                            ? const Radius.circular(18)
                            : Radius.zero,
                      ),
                      child: ColoredBox(
                        color: surge.card,
                        child: PackageListItem(
                          key: Key(package.packageName),
                          package: package,
                          value: valueList.contains(package.packageName),
                          onChanged: (value) {
                            _handleSelected(package.packageName);
                          },
                        ),
                      ),
                    );
                  },
                ),
              );
      },
    );
  }

  Widget _buildBannerBar(
    AccessControlMode mode,
    int count, {
    required bool hasChanges,
  }) {
    final appLocalizations = context.appLocalizations;
    final surge = SurgeTheme.of(context);
    final describe = mode == AccessControlMode.acceptSelected
        ? appLocalizations.accessControlAllowDesc
        : appLocalizations.accessControlNotAllowDesc;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: SurgeActionCard(
        variant: SurgeActionCardVariant.filled,
        borderRadius: surge.radii.list,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                describe,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.typography.controlLabel.copyWith(
                  color: surge.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: 12),
            _SelectedPill(label: '${appLocalizations.selected} $count'),
          ],
        ),
      ),
    );
  }

  void _onSearch(String value) {
    ref.read(queryProvider(QueryTag.access).notifier).value = value;
    _pinedList = null;
  }

  @override
  Widget build(BuildContext context) {
    final isLoading = ref.watch(loadingProvider(LoadingTag.access));
    final query = ref.watch(queryProvider(QueryTag.access));
    final packages = ref.watch(packagesProvider);
    final accessControl = ref.watch(accessControlStateProvider);
    if (_isInit) {
      if (_lastMode != accessControl.mode) {
        _lastMode = accessControl.mode;
        _pinedList = accessControl.currentList;
      } else {
        _pinedList ??= accessControl.currentList;
      }
    }
    final viewPackages = packages
        .getViewList(
          pinedList: _pinedList ?? [],
          sortType: accessControl.sort,
          isFilterNonInternetApp: accessControl.isFilterNonInternetApp,
          isFilterSystemApp: accessControl.isFilterSystemApp,
        )
        .where(
          (package) =>
              package.label.toLowerCase().contains(query) ||
              package.packageName.contains(query),
        )
        .toList();
    final mode = accessControl.mode;
    final currentList = accessControl.currentList;
    final viewPackageNameList = viewPackages.map((e) => e.packageName).toList();
    final valueList = currentList.intersection(viewPackageNameList);
    final savedAccessControl = ref.watch(
      vpnSettingProvider.select((state) => state.accessControlProps),
    );
    final hasChanges =
        _getRealAccessControlProps(savedAccessControl) !=
        _getRealAccessControlProps(accessControl);
    return CommonPopScope(
      onPop: (_) async {
        if (!hasChanges) {
          return true;
        }
        await _handleBack();
        return false;
      },
      child: CommonScaffold(
        key: _scaffoldKey,
        isLoading: isLoading,
        backgroundColor: SurgeTheme.of(context).background,
        searchState: AppBarSearchState(
          onSearch: _onSearch,
          autoAddSearch: false,
        ),
        title: context.appLocalizations.accessControl,
        appBarActions: [
          _buildAction(
            enable: accessControl.enable,
            hasChanges: hasChanges,
          ),
        ],
        body: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildBannerBar(mode, valueList.length, hasChanges: hasChanges),
            if (hiddenAccessSelectionCount(accessControl, viewPackageNameList) > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Text(
                  Localizations.localeOf(context).languageCode == 'zh'
                    ? '已保留 ${hiddenAccessSelectionCount(accessControl, viewPackageNameList)} 个未显示的已选应用'
                    : '${hiddenAccessSelectionCount(accessControl, viewPackageNameList)} hidden selections retained',
                ),
              ),
            const SizedBox(height: 6),
            Expanded(
              child: DisabledMask(
                status: !accessControl.enable,
                child: _buildContent(
                  packages: viewPackages,
                  valueList: valueList,
                ),
              ),
            ),
          ],
        ),
        floatingActionButton: _buildSelectedAllButton(
          isSelectedAll: valueList.length == viewPackageNameList.length,
          allValueList: viewPackageNameList,
        ),
      ),
    );
  }
}

class _SelectedPill extends StatelessWidget {
  final String label;

  const _SelectedPill({required this.label});

  @override
  Widget build(BuildContext context) {
    final surge = SurgeTheme.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surfaceColor = Color.alphaBlend(
      surge.primary.withValues(alpha: isDark ? 0.22 : 0.12),
      surge.card,
    );
    final borderColor = surge.primary.withValues(alpha: isDark ? 0.34 : 0.22);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(surge.radii.button),
        border: Border.all(color: borderColor, width: surge.spacing.hairline),
      ),
      child: Text(
        label,
        maxLines: 1,
        style: context.typography.badgeLabel.copyWith(color: surge.primary),
      ),
    );
  }
}

class PackageListItem extends StatelessWidget {
  final Package package;
  final bool value;
  final void Function(bool?) onChanged;

  const PackageListItem({
    super.key,
    required this.package,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListItem.checkbox(
      leading: SizedBox(
        width: 48,
        height: 48,
        child: FutureBuilder<ImageProvider?>(
          future: app?.getPackageIcon(package.packageName),
          builder: (_, snapshot) {
            if (!snapshot.hasData && snapshot.data == null) {
              return Container();
            } else {
              return Image(
                image: snapshot.data!,
                gaplessPlayback: true,
                width: 48,
                height: 48,
              );
            }
          },
        ),
      ),
      title: Text(
        package.label,
        maxLines: 1,
      ),
      subtitle: Text(
        package.packageName,
        maxLines: 1,
      ),
      delegate: CheckboxDelegate(value: value, onChanged: onChanged),
    );
  }
}

class AccessControlPanel extends ConsumerStatefulWidget {
  const AccessControlPanel({super.key});

  @override
  ConsumerState createState() => _AccessControlPanelState();
}

class _AccessControlPanelState extends ConsumerState<AccessControlPanel> {
  IconData _getIconWithAccessControlMode(AccessControlMode mode) {
    return switch (mode) {
      AccessControlMode.acceptSelected => SurgeIcons.selector,
      AccessControlMode.rejectSelected => SurgeIcons.block,
    };
  }

  String _getTextWithAccessControlMode(AccessControlMode mode) {
    final appLocalizations = context.appLocalizations;
    return switch (mode) {
      AccessControlMode.acceptSelected => appLocalizations.whitelistMode,
      AccessControlMode.rejectSelected => appLocalizations.blacklistMode,
    };
  }

  String _getTextWithAccessSortType(AccessSortType type) {
    final appLocalizations = context.appLocalizations;
    return switch (type) {
      AccessSortType.none => appLocalizations.defaultText,
      AccessSortType.name => appLocalizations.name,
      AccessSortType.time => appLocalizations.time,
    };
  }

  IconData _getIconWithProxiesSortType(AccessSortType type) {
    return switch (type) {
      AccessSortType.none => SurgeIcons.sort,
      AccessSortType.name => SurgeIcons.sortAlphabetically,
      AccessSortType.time => SurgeIcons.timeline,
    };
  }

  List<Widget> _buildModeSetting() {
    final appLocalizations = context.appLocalizations;
    return [
      Consumer(
        builder: (_, ref, _) {
          final accessControlMode = ref.watch(
            accessControlStateProvider.select((state) => state.mode),
          );
          return SurgeSettingSection(
            title: appLocalizations.mode,
            children: [
              for (
                var index = 0;
                index < AccessControlMode.values.length;
                index++
              )
                SurgeSettingOption(
                  leading: Icon(
                    _getIconWithAccessControlMode(
                      AccessControlMode.values[index],
                    ),
                  ),
                  title: _getTextWithAccessControlMode(
                    AccessControlMode.values[index],
                  ),
                  selected:
                      accessControlMode == AccessControlMode.values[index],
                  showDivider: false,
                  dense: true,
                  onTap: () {
                    ref
                        .read(accessControlStateProvider.notifier)
                        .update(
                          (state) => state.copyWith(
                            mode: AccessControlMode.values[index],
                          ),
                        );
                  },
                ),
            ],
          );
        },
      ),
    ];
  }

  List<Widget> _buildSortSetting() {
    final appLocalizations = context.appLocalizations;
    return [
      Consumer(
        builder: (_, ref, _) {
          final accessSortType = ref.watch(
            accessControlStateProvider.select((state) => state.sort),
          );
          return SurgeSettingSection(
            title: appLocalizations.sort,
            children: [
              for (var index = 0; index < AccessSortType.values.length; index++)
                SurgeSettingOption(
                  leading: Icon(
                    _getIconWithProxiesSortType(AccessSortType.values[index]),
                  ),
                  title: _getTextWithAccessSortType(
                    AccessSortType.values[index],
                  ),
                  selected: accessSortType == AccessSortType.values[index],
                  showDivider: false,
                  dense: true,
                  onTap: () {
                    ref
                        .read(accessControlStateProvider.notifier)
                        .update(
                          (state) => state.copyWith(
                            sort: AccessSortType.values[index],
                          ),
                        );
                  },
                ),
            ],
          );
        },
      ),
    ];
  }

  List<Widget> _buildSourceSetting() {
    final appLocalizations = context.appLocalizations;
    return [
      Consumer(
        builder: (_, ref, _) {
          final vm2 = ref.watch(
            accessControlStateProvider.select(
              (state) =>
                  VM2(state.isFilterSystemApp, state.isFilterNonInternetApp),
            ),
          );
          return SurgeSettingSection(
            title: appLocalizations.source,
            children: [
              SurgeSettingOption(
                leading: const Icon(SurgeIcons.apps),
                title: appLocalizations.systemApp,
                selected: vm2.a == false,
                showDivider: false,
                dense: true,
                onTap: () {
                  ref
                      .read(accessControlStateProvider.notifier)
                      .update(
                        (state) => state.copyWith(isFilterSystemApp: !vm2.a),
                      );
                },
              ),
              SurgeSettingOption(
                leading: const Icon(SurgeIcons.wifiDisabled),
                title: appLocalizations.noNetworkApp,
                selected: vm2.b == false,
                showDivider: false,
                dense: true,
                onTap: () {
                  ref
                      .read(accessControlStateProvider.notifier)
                      .update(
                        (state) =>
                            state.copyWith(isFilterNonInternetApp: !vm2.b),
                      );
                },
              ),
            ],
          );
        },
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ..._buildModeSetting(),
            ..._buildSortSetting(),
            ..._buildSourceSetting(),
          ],
        ),
      ),
    );
  }
}
