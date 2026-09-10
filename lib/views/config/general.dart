import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/surge/surge.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_clash/widgets/settings_apply_status.dart';

class LogLevelItem extends ConsumerWidget {
  const LogLevelItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final appLocalizations = context.appLocalizations;
    final logLevel = ref.watch(
      patchClashConfigProvider.select((state) => state.logLevel),
    );
    return ListItem<LogLevel>.options(
      leading: const Icon(SurgeIcons.info),
      title: Text(appLocalizations.logLevel),
      subtitle: Text(logLevel.name),
      delegate: OptionsDelegate<LogLevel>(
        title: appLocalizations.logLevel,
        options: LogLevel.values,
        onChanged: (LogLevel? value) {
          if (value == null) {
            return;
          }
          ref
              .read(patchClashConfigProvider.notifier)
              .update((state) => state.copyWith(logLevel: value));
        },
        textBuilder: (logLevel) => logLevel.name,
        value: logLevel,
      ),
    );
  }
}

class UaItem extends ConsumerWidget {
  const UaItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final appLocalizations = context.appLocalizations;
    final globalUa = ref.watch(
      patchClashConfigProvider.select((state) => state.globalUa),
    );
    return ListItem<String?>.options(
      leading: const Icon(SurgeIcons.computer),
      title: const Text('UA'),
      subtitle: Text(globalUa ?? appLocalizations.defaultText),
      delegate: OptionsDelegate<String?>(
        title: 'UA',
        options: [null, 'clash-verge/v2.4.2', 'ClashforWindows/0.19.23'],
        value: globalUa,
        onChanged: (value) {
          ref
              .read(patchClashConfigProvider.notifier)
              .update((state) => state.copyWith(globalUa: value));
        },
        textBuilder: (ua) => ua ?? appLocalizations.defaultText,
      ),
    );
  }
}

class KeepAliveIntervalItem extends ConsumerWidget {
  const KeepAliveIntervalItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final appLocalizations = context.appLocalizations;
    final keepAliveInterval = ref.watch(
      patchClashConfigProvider.select((state) => state.keepAliveInterval),
    );
    return ListItem.input(
      leading: const Icon(SurgeIcons.timer),
      title: Text(appLocalizations.keepAliveIntervalDesc),
      subtitle: Text('$keepAliveInterval ${appLocalizations.seconds}'),
      delegate: InputDelegate(
        title: appLocalizations.keepAliveIntervalDesc,
        suffixText: appLocalizations.seconds,
        resetValue: '$defaultKeepAliveInterval',
        value: '$keepAliveInterval',
        validator: (String? value) {
          if (value == null || value.isEmpty) {
            return appLocalizations.emptyTip(appLocalizations.interval);
          }
          final intValue = int.tryParse(value);
          if (intValue == null) {
            return appLocalizations.numberTip(appLocalizations.interval);
          }
          return null;
        },
        onChanged: (String? value) {
          if (value == null) {
            return;
          }
          final intValue = int.parse(value);
          ref
              .read(patchClashConfigProvider.notifier)
              .update((state) => state.copyWith(keepAliveInterval: intValue));
        },
      ),
    );
  }
}

class TestUrlItem extends ConsumerWidget {
  const TestUrlItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final appLocalizations = context.appLocalizations;
    final testUrl = ref.watch(
      appSettingProvider.select((state) => state.testUrl),
    );
    return ListItem.input(
      leading: const Icon(SurgeIcons.timeline),
      title: Text(appLocalizations.testUrl),
      subtitle: Text(testUrl),
      delegate: InputDelegate(
        resetValue: defaultTestUrl,
        title: appLocalizations.testUrl,
        value: testUrl,
        validator: (String? value) {
          if (value == null || value.isEmpty) {
            return appLocalizations.emptyTip(appLocalizations.testUrl);
          }
          if (!value.isUrl) {
            return appLocalizations.urlTip(appLocalizations.testUrl);
          }
          return null;
        },
        onChanged: (String? value) {
          if (value == null) {
            return;
          }
          ref
              .read(appSettingProvider.notifier)
              .update((state) => state.copyWith(testUrl: value));
        },
      ),
    );
  }
}

class PortItem extends ConsumerWidget {
  const PortItem({super.key});

  Future<void> handleShowPortDialog() async {
    await globalState.showCommonDialog(child: const _PortDialog());
    // inputDelegate.onChanged(value);
  }

  @override
  Widget build(BuildContext context, ref) {
    final appLocalizations = context.appLocalizations;
    final mixedPort = ref.watch(
      patchClashConfigProvider.select((state) => state.mixedPort),
    );
    return ListItem(
      leading: const Icon(SurgeIcons.selector),
      title: Text(appLocalizations.port),
      subtitle: Text('$mixedPort'),
      onTap: () {
        handleShowPortDialog();
      },
      // delegate: InputDelegate(
      //   title: appLocalizations.port,
      //   value: "$mixedPort",
      //   validator: (String? value) {
      //     if (value == null || value.isEmpty) {
      //       return appLocalizations.emptyTip(appLocalizations.proxyPort);
      //     }
      //     final mixedPort = int.tryParse(value);
      //     if (mixedPort == null) {
      //       return appLocalizations.numberTip(appLocalizations.proxyPort);
      //     }
      //     if (mixedPort < 1024 || mixedPort > 49151) {
      //       return appLocalizations.proxyPortTip;
      //     }
      //     return null;
      //   },
      //   onChanged: (String? value) {
      //     if (value == null) {
      //       return;
      //     }
      //     final mixedPort = int.parse(value);
      //     ref.read(patchClashConfigProvider.notifier).update(
      //           (state) => state.copyWith(
      //             mixedPort: mixedPort,
      //           ),
      //         );
      //   },
      //   resetValue: "$defaultMixedPort",
      // ),
    );
  }
}

class HostsItem extends ConsumerWidget {
  const HostsItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final appLocalizations = context.appLocalizations;
    final hosts = ref.watch(
      patchClashConfigProvider.select((state) => state.hosts),
    );
    return ListItem.open(
      leading: const Icon(SurgeIcons.list),
      title: const Text('Hosts'),
      subtitle: Text(appLocalizations.hostsDesc),
      delegate: OpenDelegate(
        blur: false,
        widget: MapInputPage(
          title: 'Hosts',
          map: hosts,
          keyHint: appLocalizations.key,
          valueHint: appLocalizations.value,
          showFieldLabels: false,
          titleBuilder: (item) => Text(item.key),
          subtitleBuilder: (item) => Text(item.value),
        ),
        onChanged: (value) {
          ref
              .read(patchClashConfigProvider.notifier)
              .update((state) => state.copyWith(hosts: value));
        },
      ),
    );
  }
}

class Ipv6Item extends ConsumerWidget {
  const Ipv6Item({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final ipv6 = ref.watch(
      patchClashConfigProvider.select((state) => state.ipv6),
    );
    return ListItem.switchItem(
      leading: const Icon(SurgeIcons.water),
      title: const Text('IPv6'),
      subtitle: Text(settingsText(context, '控制内核 IPv6 能力及 DNS 上限；VPN 接管请在网络页设置', 'Core IPv6 capability and DNS limit; configure VPN capture on the Network page')),
      delegate: SwitchDelegate(
        value: ipv6,
        onChanged: (bool value) async {
          ref
              .read(patchClashConfigProvider.notifier)
              .update((state) => state.copyWith(ipv6: value));
        },
      ),
    );
  }
}

class AppendSystemDNSItem extends ConsumerWidget {
  const AppendSystemDNSItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final appLocalizations = context.appLocalizations;
    final appendSystemDNS = ref.watch(
      networkSettingProvider.select((state) => state.appendSystemDns),
    );
    return ListItem.switchItem(
      leading: const Icon(SurgeIcons.dns),
      title: Text(appLocalizations.appendSystemDns),
      subtitle: Text(settingsText(context, '向最终 DNS 追加系统解析器；关闭不会删除订阅或自动补全已有的系统 DNS', 'Adds the system resolver; disabling does not remove one supplied by the profile or automatic fallback')),
      delegate: SwitchDelegate(
        value: appendSystemDNS,
        onChanged: (bool value) async {
          ref
              .read(networkSettingProvider.notifier)
              .update((state) => state.copyWith(appendSystemDns: value));
        },
      ),
    );
  }
}

class AllowLanItem extends ConsumerWidget {
  const AllowLanItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final appLocalizations = context.appLocalizations;
    final allowLan = ref.watch(
      patchClashConfigProvider.select((state) => state.allowLan),
    );
    return ListItem.switchItem(
      leading: const Icon(SurgeIcons.localNetwork),
      title: Text(appLocalizations.allowLan),
      subtitle: Text(appLocalizations.allowLanDesc),
      delegate: SwitchDelegate(
        value: allowLan,
        onChanged: (bool value) async {
          ref
              .read(patchClashConfigProvider.notifier)
              .update((state) => state.copyWith(allowLan: value));
        },
      ),
    );
  }
}

class UnifiedDelayItem extends ConsumerWidget {
  const UnifiedDelayItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final appLocalizations = context.appLocalizations;
    final unifiedDelay = ref.watch(
      patchClashConfigProvider.select((state) => state.unifiedDelay),
    );

    return ListItem.switchItem(
      leading: const Icon(SurgeIcons.compress),
      title: Text(appLocalizations.unifiedDelay),
      subtitle: Text(appLocalizations.unifiedDelayDesc),
      delegate: SwitchDelegate(
        value: unifiedDelay,
        onChanged: (bool value) async {
          ref
              .read(patchClashConfigProvider.notifier)
              .update((state) => state.copyWith(unifiedDelay: value));
        },
      ),
    );
  }
}

class FindProcessItem extends ConsumerWidget {
  const FindProcessItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final appLocalizations = context.appLocalizations;
    final findProcess = ref.watch(
      patchClashConfigProvider.select(
        (state) => state.findProcessMode == FindProcessMode.always,
      ),
    );

    return ListItem.switchItem(
      leading: const Icon(SurgeIcons.polymer),
      title: Text(appLocalizations.findProcessMode),
      subtitle: Text(appLocalizations.findProcessModeDesc),
      delegate: SwitchDelegate(
        value: findProcess,
        onChanged: (bool value) async {
          ref
              .read(patchClashConfigProvider.notifier)
              .update(
                (state) => state.copyWith(
                  findProcessMode: value
                      ? FindProcessMode.always
                      : FindProcessMode.off,
                ),
              );
        },
      ),
    );
  }
}

class TcpConcurrentItem extends ConsumerWidget {
  const TcpConcurrentItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final appLocalizations = context.appLocalizations;
    final tcpConcurrent = ref.watch(
      patchClashConfigProvider.select((state) => state.tcpConcurrent),
    );
    return ListItem.switchItem(
      leading: const Icon(SurgeIcons.doubleArrow),
      title: Text(appLocalizations.tcpConcurrent),
      subtitle: Text(appLocalizations.tcpConcurrentDesc),
      delegate: SwitchDelegate(
        value: tcpConcurrent,
        onChanged: (value) async {
          ref
              .read(patchClashConfigProvider.notifier)
              .update((state) => state.copyWith(tcpConcurrent: value));
        },
      ),
    );
  }
}

class GeodataLoaderItem extends ConsumerWidget {
  const GeodataLoaderItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final appLocalizations = context.appLocalizations;
    final isMemconservative = ref.watch(
      patchClashConfigProvider.select(
        (state) => state.geodataLoader == GeodataLoader.memconservative,
      ),
    );
    return ListItem.switchItem(
      leading: const Icon(SurgeIcons.memory),
      title: Text(appLocalizations.geodataLoader),
      subtitle: Text(appLocalizations.geodataLoaderDesc),
      delegate: SwitchDelegate(
        value: isMemconservative,
        onChanged: (bool value) async {
          ref
              .read(patchClashConfigProvider.notifier)
              .update(
                (state) => state.copyWith(
                  geodataLoader: value
                      ? GeodataLoader.memconservative
                      : GeodataLoader.standard,
                ),
              );
        },
      ),
    );
  }
}

class ExternalControllerItem extends ConsumerWidget {
  const ExternalControllerItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final appLocalizations = context.appLocalizations;
    final hasExternalController = ref.watch(
      patchClashConfigProvider.select(
        (state) => state.externalController == ExternalControllerStatus.open,
      ),
    );
    return ListItem.switchItem(
      leading: const Icon(SurgeIcons.api),
      title: Text(appLocalizations.externalController),
      subtitle: Text(appLocalizations.externalControllerDesc),
      delegate: SwitchDelegate(
        value: hasExternalController,
        onChanged: (bool value) async {
          ref
              .read(patchClashConfigProvider.notifier)
              .update(
                (state) => state.copyWith(
                  externalController: value
                      ? ExternalControllerStatus.open
                      : ExternalControllerStatus.close,
                ),
              );
        },
      ),
    );
  }
}

final generalItems = <Widget>[
  const LogLevelItem(),
  const UaItem(),
  if (system.isDesktop) const KeepAliveIntervalItem(),
  const TestUrlItem(),
  const PortItem(),
  const HostsItem(),
  const Ipv6Item(),
  const AllowLanItem(),
  const UnifiedDelayItem(),
  const AppendSystemDNSItem(),
  const FindProcessItem(),
  const TcpConcurrentItem(),
  const GeodataLoaderItem(),
  const ExternalControllerItem(),
].separated(const Divider(height: 0)).toList();

class _PortDialog extends ConsumerStatefulWidget {
  const _PortDialog();

  @override
  ConsumerState<_PortDialog> createState() => _PortDialogState();
}

class _PortDialogState extends ConsumerState<_PortDialog> {
  final _formKey = GlobalKey<FormState>();
  bool _isMore = false;

  late final TextEditingController _mixedPortController;
  late final TextEditingController _portController;
  late final TextEditingController _socksPortController;
  late final TextEditingController _redirPortController;
  late final TextEditingController _tProxyPortController;

  @override
  void initState() {
    super.initState();
    final vm5 = ref.read(
      patchClashConfigProvider.select((state) {
        return VM5(
          state.mixedPort,
          state.port,
          state.socksPort,
          state.redirPort,
          state.tproxyPort,
        );
      }),
    );
    _mixedPortController = TextEditingController(text: vm5.a.toString());
    _portController = TextEditingController(text: vm5.b.toString());
    _socksPortController = TextEditingController(text: vm5.c.toString());
    _redirPortController = TextEditingController(text: vm5.d.toString());
    _tProxyPortController = TextEditingController(text: vm5.e.toString());
  }

  Future<void> _handleReset() async {
    final res = await globalState.showMessage(
      message: TextSpan(text: context.appLocalizations.resetTip),
    );
    if (res != true) {
      return;
    }
    ref
        .read(patchClashConfigProvider.notifier)
        .update(
          (state) => state.copyWith(
            mixedPort: 7890,
            port: 0,
            socksPort: 0,
            redirPort: 0,
            tproxyPort: 0,
          ),
        );
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _handleUpdate() {
    if (_formKey.currentState?.validate() == false) return;
    ref
        .read(patchClashConfigProvider.notifier)
        .update(
          (state) => state.copyWith(
            mixedPort: int.parse(_mixedPortController.text),
            port: int.parse(_portController.text),
            socksPort: int.parse(_socksPortController.text),
            redirPort: int.parse(_redirPortController.text),
            tproxyPort: int.parse(_tProxyPortController.text),
          ),
        );
    Navigator.of(context).pop();
  }

  void _handleMore() {
    setState(() {
      _isMore = !_isMore;
    });
  }

  @override
  void dispose() {
    _mixedPortController.dispose();
    _portController.dispose();
    _socksPortController.dispose();
    _redirPortController.dispose();
    _tProxyPortController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final surge = SurgeTheme.of(context);
    return CommonDialog(
      title: appLocalizations.port,
      child: Form(
        autovalidateMode: AutovalidateMode.onUserInteraction,
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 18,
          children: [
            Row(
              children: [
                SizedBox.square(
                  dimension: 28,
                  child: IconButton.filledTonal(
                    onPressed: _handleMore,
                    style: IconButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size.square(28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: IconTheme.merge(
                      data: const IconThemeData(size: 17),
                      child: CommonExpandIcon(expand: _isMore),
                    ),
                  ),
                ),
                const Spacer(),
                SizedBox(
                  height: 28,
                  child: OutlinedButton.icon(
                    onPressed: _handleReset,
                    icon: const Icon(SurgeIcons.replay, size: 15),
                    label: Text(appLocalizations.reset),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: const Size(0, 28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      foregroundColor: surge.textPrimary,
                      side: BorderSide(
                        color: surge.separator.withValues(alpha: 0.9),
                        width: surge.spacing.hairline,
                      ),
                      textStyle: context.typography.controlLabel,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(surge.radii.button),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            AnimatedSize(
              duration: SurgeMotion.container,
              curve: SurgeMotion.stateCurve,
              alignment: Alignment.topCenter,
              child: Column(
                spacing: 16,
                children: [
                  SurgeField(
                    label: appLocalizations.mixedPort,
                    child: TextFormField(
                      keyboardType: TextInputType.number,
                      maxLines: 1,
                      minLines: 1,
                      controller: _mixedPortController,
                      onFieldSubmitted: (_) {
                        _handleUpdate();
                      },
                      decoration: surgeInputDecoration(
                        context,
                        hintText: appLocalizations.mixedPort,
                      ),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return appLocalizations.emptyTip(
                            appLocalizations.mixedPort,
                          );
                        }
                        final port = int.tryParse(value);
                        if (port == null) {
                          return appLocalizations.numberTip(
                            appLocalizations.mixedPort,
                          );
                        }
                        if (port < 1024 || port > 49151) {
                          return appLocalizations.portTip(
                            appLocalizations.mixedPort,
                          );
                        }
                        final ports = [
                          _portController.text,
                          _socksPortController.text,
                          _tProxyPortController.text,
                          _redirPortController.text,
                        ].map((item) => item.trim());
                        if (ports.contains(value.trim())) {
                          return appLocalizations.portConflictTip;
                        }
                        return null;
                      },
                    ),
                  ),
                  if (_isMore) ...[
                    SurgeField(
                      label: appLocalizations.port,
                      child: TextFormField(
                        keyboardType: TextInputType.number,
                        maxLines: 1,
                        minLines: 1,
                        controller: _portController,
                        onFieldSubmitted: (_) {
                          _handleUpdate();
                        },
                        decoration: surgeInputDecoration(
                          context,
                          hintText: appLocalizations.port,
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return appLocalizations.emptyTip(
                              appLocalizations.port,
                            );
                          }
                          final port = int.tryParse(value);
                          if (port == null) {
                            return appLocalizations.numberTip(
                              appLocalizations.port,
                            );
                          }
                          if (port == 0) {
                            return null;
                          }
                          if (port < 1024 || port > 49151) {
                            return appLocalizations.portTip(
                              appLocalizations.port,
                            );
                          }
                          final ports = [
                            _mixedPortController.text,
                            _socksPortController.text,
                            _tProxyPortController.text,
                            _redirPortController.text,
                          ].map((item) => item.trim());
                          if (ports.contains(value.trim())) {
                            return appLocalizations.portConflictTip;
                          }
                          return null;
                        },
                      ),
                    ),
                    SurgeField(
                      label: appLocalizations.socksPort,
                      child: TextFormField(
                        keyboardType: TextInputType.number,
                        maxLines: 1,
                        minLines: 1,
                        controller: _socksPortController,
                        onFieldSubmitted: (_) {
                          _handleUpdate();
                        },
                        decoration: surgeInputDecoration(
                          context,
                          hintText: appLocalizations.socksPort,
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return appLocalizations.emptyTip(
                              appLocalizations.socksPort,
                            );
                          }
                          final port = int.tryParse(value);
                          if (port == null) {
                            return appLocalizations.numberTip(
                              appLocalizations.socksPort,
                            );
                          }
                          if (port == 0) {
                            return null;
                          }
                          if (port < 1024 || port > 49151) {
                            return appLocalizations.portTip(
                              appLocalizations.socksPort,
                            );
                          }
                          final ports = [
                            _portController.text,
                            _mixedPortController.text,
                            _tProxyPortController.text,
                            _redirPortController.text,
                          ].map((item) => item.trim());
                          if (ports.contains(value.trim())) {
                            return appLocalizations.portConflictTip;
                          }
                          return null;
                        },
                      ),
                    ),
                    SurgeField(
                      label: appLocalizations.redirPort,
                      child: TextFormField(
                        keyboardType: TextInputType.number,
                        maxLines: 1,
                        minLines: 1,
                        controller: _redirPortController,
                        onFieldSubmitted: (_) {
                          _handleUpdate();
                        },
                        decoration: surgeInputDecoration(
                          context,
                          hintText: appLocalizations.redirPort,
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return appLocalizations.emptyTip(
                              appLocalizations.redirPort,
                            );
                          }
                          final port = int.tryParse(value);
                          if (port == null) {
                            return appLocalizations.numberTip(
                              appLocalizations.redirPort,
                            );
                          }
                          if (port == 0) {
                            return null;
                          }
                          if (port < 1024 || port > 49151) {
                            return appLocalizations.portTip(
                              appLocalizations.redirPort,
                            );
                          }
                          final ports = [
                            _portController.text,
                            _socksPortController.text,
                            _tProxyPortController.text,
                            _mixedPortController.text,
                          ].map((item) => item.trim());
                          if (ports.contains(value.trim())) {
                            return appLocalizations.portConflictTip;
                          }
                          return null;
                        },
                      ),
                    ),
                    SurgeField(
                      label: appLocalizations.tproxyPort,
                      child: TextFormField(
                        keyboardType: TextInputType.number,
                        maxLines: 1,
                        minLines: 1,
                        controller: _tProxyPortController,
                        onFieldSubmitted: (_) {
                          _handleUpdate();
                        },
                        decoration: surgeInputDecoration(
                          context,
                          hintText: appLocalizations.tproxyPort,
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return appLocalizations.emptyTip(
                              appLocalizations.tproxyPort,
                            );
                          }
                          final port = int.tryParse(value);
                          if (port == null) {
                            return appLocalizations.numberTip(
                              appLocalizations.tproxyPort,
                            );
                          }
                          if (port == 0) {
                            return null;
                          }
                          if (port < 1024 || port > 49151) {
                            return appLocalizations.portTip(
                              appLocalizations.tproxyPort,
                            );
                          }
                          final ports = [
                            _portController.text,
                            _socksPortController.text,
                            _mixedPortController.text,
                            _redirPortController.text,
                          ].map((item) => item.trim());
                          if (ports.contains(value.trim())) {
                            return appLocalizations.portConflictTip;
                          }

                          return null;
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
            SurgeDialogActionRow(
              cancelLabel: appLocalizations.cancel,
              submitLabel: appLocalizations.submit,
              onCancel: () {
                Navigator.of(context).pop();
              },
              onSubmit: _handleUpdate,
            ),
          ],
        ),
      ),
    );
  }
}
