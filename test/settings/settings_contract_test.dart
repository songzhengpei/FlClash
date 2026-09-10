import 'package:flutter_test/flutter_test.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/services/settings/settings_contract.dart';

void main() {
  const initial = Config(currentProfileId: 1, themeProps: defaultThemeProps);
  test('route modes reach Android options, including both IP families', () {
    final custom = initial.copyWith.patchClashConfig.tun(
      routeAddress: ['10.0.0.0/8', '2001:db8::/32'],
    );
    expect(settingsVpnOptions(custom).routeAddress, [
      '10.0.0.0/8',
      '2001:db8::/32',
    ]);
    expect(settingsVpnOptions(initial).routeAddress, isEmpty);
    expect(
      settingsVpnOptions(
        initial.copyWith.networkProps(routeMode: RouteMode.bypassPrivate),
      ).routeAddress,
      defaultBypassPrivateRouteAddress,
    );
  });
  test('CIDR validation rejects hostnames and invalid prefixes', () {
    for (final value in [
      'example.com/24',
      '10.1.1.1/33',
      '::/129',
      '1.2.3.4',
      '::/-1',
      '',
    ]) {
      expect(validateRouteCidr(value), isNotNull, reason: value);
    }
    for (final value in [
      '0.0.0.0/0',
      '192.168.1.0/24',
      '::/0',
      '2001:db8::/32',
    ]) {
      expect(validateRouteCidr(value), isNull, reason: value);
    }
  });
  test('display preferences and legacy DNS hijacking do not restart VPN', () {
    final display = initial.copyWith.vpnProps.accessControlProps(
      isFilterSystemApp: false,
      isFilterNonInternetApp: false,
    );
    expect(settingsApplyKind(initial, display), SettingsApplyKind.none);
    expect(
      settingsApplyKind(
        initial,
        initial.copyWith.vpnProps(dnsHijacking: true, smartAutoStop: true),
      ),
      SettingsApplyKind.none,
    );
    expect(
      settingsApplyKind(
        initial,
        initial.copyWith.patchClashConfig.tun(stack: TunStack.system),
      ),
      SettingsApplyKind.vpn,
    );
  });
  test('IPv6 rebuilds DNS, allow-lan remains hot, DNS reloads', () {
    expect(
      settingsApplyKind(initial, initial.copyWith.patchClashConfig(ipv6: true)),
      SettingsApplyKind.reload,
    );
    expect(
      settingsApplyKind(
        initial,
        initial.copyWith.patchClashConfig(allowLan: true),
      ),
      SettingsApplyKind.hot,
    );
    expect(
      settingsApplyKind(
        initial,
        initial.copyWith.patchClashConfig.dns(preferH3: true),
      ),
      SettingsApplyKind.reload,
    );
  });
  test('DNS source follows materializer truth table', () {
    expect(
      dnsSettingsSource(sourceEnabled: true, overrideDns: false),
      DnsSettingsSource.subscription,
    );
    expect(
      dnsSettingsSource(sourceEnabled: true, overrideDns: true),
      DnsSettingsSource.override,
    );
    for (final override in [true, false]) {
      expect(
        dnsSettingsSource(sourceEnabled: false, overrideDns: override),
        DnsSettingsSource.automatic,
      );
    }
  });
  test(
    'failed leaf rollback preserves a newer DNS edit and display filters',
    () {
      final attempted = initial.copyWith.patchClashConfig.dns(
        preferH3: true,
        ipv6: true,
      );
      final now = attempted.copyWith.patchClashConfig.dns(
        nameserver: ['9.9.9.9'],
      );
      final restored = rollbackSettings(
        initial,
        attempted,
        now.copyWith.vpnProps.accessControlProps(isFilterSystemApp: false),
      );
      expect(restored.patchClashConfig.dns.preferH3, false);
      expect(restored.patchClashConfig.dns.ipv6, false);
      expect(restored.patchClashConfig.dns.nameserver, ['9.9.9.9']);
      expect(restored.vpnProps.accessControlProps.isFilterSystemApp, false);
    },
  );
  test('rollback handles removed map keys and nullable UA', () {
    final before = initial.copyWith.patchClashConfig(
      hosts: {'a': '1.1.1.1'},
      globalUa: 'old',
    );
    final attempted = before.copyWith.patchClashConfig(
      hosts: {},
      globalUa: null,
    );
    final restored = rollbackSettings(before, attempted, attempted);
    expect(restored.patchClashConfig.hosts, {'a': '1.1.1.1'});
    expect(restored.patchClashConfig.globalUa, 'old');
  });
  test('hidden packages survive save in allow and reject modes', () {
    for (final mode in AccessControlMode.values) {
      final access = const AccessControlProps()
          .copyWith(mode: mode)
          .copyWithNewList(['system.app', 'visible.app']);
      final saved = preserveAccessSelection(
        access.copyWith(isFilterSystemApp: true),
      );
      expect(saved.currentList, containsAll(['system.app', 'visible.app']));
      expect(hiddenAccessSelectionCount(saved, ['visible.app']), 1);
    }
  });
  test('both rule parameters survive serialization', () {
    final rule = Rule(
      ruleAction: RuleAction.IP_CIDR,
      content: '10.0.0.0/8',
      ruleTarget: 'DIRECT',
      src: true,
      noResolve: true,
    );
    final parsed = Rule.parse(rule.rawValue);
    expect(parsed.src, true);
    expect(parsed.noResolve, true);
  });
}
