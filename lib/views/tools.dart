import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/about.dart';
import 'package:fl_clash/views/application_setting.dart';
import 'package:fl_clash/views/backup_and_restore.dart';
import 'package:fl_clash/views/config/config.dart';
import 'package:fl_clash/views/config/dns.dart';
import 'package:fl_clash/views/config/network.dart';
import 'package:fl_clash/views/hotkey.dart';
import 'package:fl_clash/widgets/surge/surge.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'config/advanced.dart';
import 'developer.dart';
import 'theme.dart';
import 'package:fl_clash/providers/settings_apply.dart';
import 'package:fl_clash/services/settings/settings_contract.dart';
import 'package:fl_clash/widgets/settings_apply_status.dart';

class ToolsView extends ConsumerStatefulWidget {
  const ToolsView({super.key});

  @override
  ConsumerState<ToolsView> createState() => _ToolViewState();
}

class _ToolViewState extends ConsumerState<ToolsView> {
  Widget _buildNavigationMenuItem(NavigationItem navigationItem) {
    return _SurgeOpenTile(
      leading: navigationItem.icon,
      title: Intl.message(navigationItem.label.name),
      subtitle: navigationItem.description != null
          ? Intl.message(navigationItem.description!)
          : null,
      child: navigationItem.builder(context),
    );
  }

  List<Widget> _buildNavigationMenu(List<NavigationItem> navigationItems) {
    return [
      for (var index = 0; index < navigationItems.length; index++)
        _SurgeTilePosition(
          isLast: index == navigationItems.length - 1,
          child: _buildNavigationMenuItem(navigationItems[index]),
        ),
    ];
  }

  Widget _getSettingList(bool enableDeveloperMode) {
    final items = [
      const _LocaleItem(),
      const _ThemeItem(),
      const _NetworkItem(),
      const _DnsItem(),
      const _BackupItem(),
      if (system.isDesktop) const _HotkeyItem(),
      const _ConfigItem(),
      const _AdvancedConfigItem(),
      const _SettingItem(),
      if (enableDeveloperMode) const _DeveloperItem(),
      const _InfoItem(),
    ];
    return SurgeSection(
      title: context.appLocalizations.settings,
      children: [
        for (var index = 0; index < items.length; index++)
          _SurgeTilePosition(
            isLast: index == items.length - 1,
            child: items[index],
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final vm2 = ref.watch(
      appSettingProvider.select(
        (state) => VM2(state.locale, state.developerMode),
      ),
    );
    final items = [
      Consumer(
        builder: (_, ref, _) {
          final state = ref.watch(moreToolsSelectorStateProvider);
          if (state.navigationItems.isEmpty) {
            return Container();
          }
          return SurgeSection(
            title: context.appLocalizations.more,
            children: _buildNavigationMenu(state.navigationItems),
          );
        },
      ),
      _getSettingList(vm2.b),
    ];
    final surge = SurgeTheme.of(context);
    return CommonScaffold(
      backgroundColor: surge.background,
      title: context.appLocalizations.tools,
      appBarActions: const [],
      titleVariant: SlAppBarTitleVariant.root,
      body: ListView.builder(
        key: toolsStoreKey,
        itemCount: items.length,
        itemBuilder: (_, index) => items[index],
        padding: EdgeInsets.only(
          top: 12,
          bottom: SurgeBottomNavLayout.mainPageBottomPadding(context),
        ),
      ),
    );
  }
}

class _SurgeTilePosition extends StatelessWidget {
  const _SurgeTilePosition({required this.child, required this.isLast});

  final Widget child;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return _SurgeTileDividerProvider(showDivider: !isLast, child: child);
  }
}

class _SurgeTileDividerProvider extends InheritedWidget {
  const _SurgeTileDividerProvider({
    required this.showDivider,
    required super.child,
  });

  final bool showDivider;

  static bool of(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<_SurgeTileDividerProvider>()
            ?.showDivider ??
        true;
  }

  @override
  bool updateShouldNotify(_SurgeTileDividerProvider oldWidget) {
    return showDivider != oldWidget.showDivider;
  }
}

class _SurgeOpenTile extends StatelessWidget {
  const _SurgeOpenTile({
    required this.leading,
    required this.title,
    required this.child,
    this.subtitle,
  });

  final Widget leading;
  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SurgeListTile(
      leading: leading,
      title: title,
      subtitle: subtitle,
      showChevron: true,
      showDivider: _SurgeTileDividerProvider.of(context),
      titleTextStyle: context.typography.toolTileTitle,
      subtitleTextStyle: context.typography.toolTileSubtitle,
      onTap: () {
        showExtend(
          context,
          builder: (_) {
            return child;
          },
        );
      },
    );
  }
}

class _SurgeActionTile extends StatelessWidget {
  const _SurgeActionTile({
    required this.leading,
    required this.title,
    required this.onTap,
    this.subtitle,
  });

  final Widget leading;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SurgeListTile(
      leading: leading,
      title: title,
      subtitle: subtitle,
      showDivider: _SurgeTileDividerProvider.of(context),
      titleTextStyle: context.typography.toolTileTitle,
      subtitleTextStyle: context.typography.toolTileSubtitle,
      onTap: onTap,
    );
  }
}

class _LocaleItem extends ConsumerWidget {
  const _LocaleItem();

  String _getLocaleString(BuildContext context, Locale? locale) {
    if (locale == null) return context.appLocalizations.defaultText;
    return switch (locale.toString()) {
      'zh_CN' => context.appLocalizations.zh_CN,
      _ => context.appLocalizations.en,
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(
      appSettingProvider.select((state) => state.locale),
    );
    final subTitle = locale ?? context.appLocalizations.defaultText;
    final currentLocale = utils.getLocaleForString(locale);
    return _SurgeActionTile(
      leading: const Icon(SurgeIcons.language),
      title: context.appLocalizations.language,
      subtitle: Intl.message(subTitle),
      onTap: () async {
        final locale = await globalState.showCommonDialog<Locale?>(
          child: OptionsDialog<Locale?>(
            title: context.appLocalizations.language,
            options: [null, ...AppLocalizations.delegate.supportedLocales],
            textBuilder: (locale) => _getLocaleString(context, locale),
            value: currentLocale,
          ),
        );
        ref
            .read(appSettingProvider.notifier)
            .update((state) => state.copyWith(locale: locale?.toString()));
      },
    );
  }
}

class _ThemeItem extends StatelessWidget {
  const _ThemeItem();

  @override
  Widget build(BuildContext context) {
    return _SurgeOpenTile(
      leading: const Icon(SurgeIcons.style),
      title: context.appLocalizations.theme,
      subtitle: context.appLocalizations.themeDesc,
      child: const ThemeView(),
    );
  }
}

class _BackupItem extends StatelessWidget {
  const _BackupItem();

  @override
  Widget build(BuildContext context) {
    return _SurgeOpenTile(
      leading: const Icon(SurgeIcons.cloudSync),
      title: context.appLocalizations.backupAndRestore,
      subtitle: context.appLocalizations.backupAndRestoreDesc,
      child: const BackupAndRestore(),
    );
  }
}

class _HotkeyItem extends StatelessWidget {
  const _HotkeyItem();

  @override
  Widget build(BuildContext context) {
    return _SurgeOpenTile(
      leading: const Icon(SurgeIcons.keyboard),
      title: context.appLocalizations.hotkeyManagement,
      subtitle: context.appLocalizations.hotkeyManagementDesc,
      child: const HotKeyView(),
    );
  }
}

class _NetworkItem extends StatelessWidget {
  const _NetworkItem();

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return _SurgeOpenTile(
      leading: const Icon(SurgeIcons.vpnKey),
      title: appLocalizations.network,
      subtitle: appLocalizations.networkDesc,
      child: CommonScaffold(
        title: appLocalizations.network,
        body: const NetworkListView(),
      ),
    );
  }
}

class _DnsItem extends StatelessWidget {
  const _DnsItem();

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return _SurgeOpenTile(
      leading: const Icon(SurgeIcons.dns),
      title: 'DNS',
      subtitle: appLocalizations.dnsDesc,
      child: CommonScaffold(
        title: 'DNS',
        appBarActions: [
          SlAppBarIconAction(
            icon: SurgeIcons.replay,
            tooltip: appLocalizations.reset,
            onPressed: () async {
              final container = ProviderScope.containerOf(context);
              final source = container.read(dnsSettingsSourceProvider).asData?.value;
              if (source == null || source == DnsSettingsSource.subscription) {
                globalState.showNotifier(settingsText(context,
                  '当前未采用 APP DNS，请先确认来源或开启覆写。',
                  'APP DNS is not active; resolve the source or enable override first.'));
                return;
              }
              final res = await globalState.showMessage(
                title: appLocalizations.reset,
                message: TextSpan(text: appLocalizations.resetTip),
              );
              if (res != true) return;
              container
                  .read(patchClashConfigProvider.notifier)
                  .update((state) => state.copyWith(dns: defaultDns));
            },
          ),
        ],
        body: const DnsListView(),
      ),
    );
  }
}

class _ConfigItem extends StatelessWidget {
  const _ConfigItem();

  @override
  Widget build(BuildContext context) {
    return _SurgeOpenTile(
      leading: const Icon(SurgeIcons.edit),
      title: context.appLocalizations.basicConfig,
      subtitle: context.appLocalizations.basicConfigDesc,
      child: const ConfigView(),
    );
  }
}

class _AdvancedConfigItem extends StatelessWidget {
  const _AdvancedConfigItem();

  @override
  Widget build(BuildContext context) {
    return _SurgeOpenTile(
      leading: const Icon(SurgeIcons.build),
      title: context.appLocalizations.advancedConfig,
      subtitle: context.appLocalizations.advancedConfigDesc,
      child: const AdvancedConfigView(),
    );
  }
}

class _SettingItem extends StatelessWidget {
  const _SettingItem();

  @override
  Widget build(BuildContext context) {
    return _SurgeOpenTile(
      leading: const Icon(SurgeIcons.settings),
      title: context.appLocalizations.application,
      subtitle: context.appLocalizations.applicationDesc,
      child: const ApplicationSettingView(),
    );
  }
}

class _InfoItem extends StatelessWidget {
  const _InfoItem();

  @override
  Widget build(BuildContext context) {
    return _SurgeOpenTile(
      leading: const Icon(SurgeIcons.info),
      title: context.appLocalizations.about,
      subtitle: context.appLocalizations.versionAndProjectLinks,
      child: const AboutView(),
    );
  }
}

class _DeveloperItem extends StatelessWidget {
  const _DeveloperItem();

  @override
  Widget build(BuildContext context) {
    return _SurgeOpenTile(
      leading: const Icon(SurgeIcons.developer),
      title: context.appLocalizations.developerMode,
      child: const DeveloperView(),
    );
  }
}
