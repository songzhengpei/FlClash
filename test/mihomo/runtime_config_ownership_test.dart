import 'dart:io';
import 'package:fl_clash/services/settings/settings_contract.dart';

import 'package:fl_clash/common/task.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/services/mihomo_config/runtime_config_patch.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

dynamic _plainYaml(dynamic value) {
  if (value is YamlMap) {
    return <String, dynamic>{
      for (final entry in value.entries)
        entry.key.toString(): _plainYaml(entry.value),
    };
  }
  if (value is YamlList) return value.map(_plainYaml).toList();
  return value;
}

Map<String, dynamic> _fixture(String name) {
  final source = File(
    p.join('test', 'fixtures', 'mihomo', name),
  ).readAsStringSync();
  return Map<String, dynamic>.from(_plainYaml(loadYaml(source)) as Map);
}

Future<Map<String, dynamic>> _materialize(
  Map<String, dynamic> rawConfig, {
  PatchClashConfig patch = const PatchClashConfig(),
  bool overrideDns = false,
  bool appendSystemDns = false,
  String? writeTo,
}) async {
  final output = await makeRealProfileTask(
    MakeRealProfileState(
      profilesPath: p.join('runtime', 'profiles'),
      profileId: 42,
      rawConfig: rawConfig,
      realPatchConfig: patch,
      overrideDns: overrideDns,
      appendSystemDns: appendSystemDns,
      proxyGroups: const [],
      rules: const [],
      addedRules: const [],
      defaultUA: 'Slclash-test-UA',
    ),
  );
  if (writeTo != null) {
    final file = File(writeTo);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(output.a);
  }
  final parsed = _plainYaml(loadYaml(output.a));
  expect(parsed, isA<Map>());
  return Map<String, dynamic>.from(parsed as Map);
}

void main() {

  test('all eight independent IPv6 combinations reach materializer and VPN', () async {
    for (final capture in [false, true]) {
      for (final core in [false, true]) {
        for (final aaaa in [false, true]) {
          final config = const Config(themeProps: defaultThemeProps)
              .copyWith.vpnProps(ipv6: capture)
              .copyWith.patchClashConfig(ipv6: core)
              .copyWith.patchClashConfig.dns(ipv6: aaaa);
          final output = await _materialize({'dns': {'enable': true}},
              patch: config.patchClashConfig, overrideDns: true);
          expect(settingsVpnOptions(config).ipv6, capture);
          expect(output['ipv6'], core);
          expect((output['dns'] as Map)['ipv6'], core && aaaa);
          expect(config.patchClashConfig.dns.ipv6, aaaa);
        }
      }
    }
  });
  group('GeoX URL ownership contract', () {
    const patch = GeoXUrl(
      mmdb: 'app-mmdb',
      asn: 'app-asn',
      geoip: 'app-geoip',
      geosite: 'app-geosite',
    );

    test('owned GeoX URL fields win while future siblings survive', () {
      final result = applyOwnedGeoXUrlPatch({
        'geox-url': {
          'mmdb': 'source-mmdb',
          'future-dataset': 'keep',
          'future-nested': {
            'enabled': true,
            'mirrors': ['a', 'b'],
          },
        },
      }, patch.toJson());
      final geoXUrl = result['geox-url'] as Map;
      expect(geoXUrl['mmdb'], 'app-mmdb');
      expect(geoXUrl['asn'], 'app-asn');
      expect(geoXUrl['geoip'], 'app-geoip');
      expect(geoXUrl['geosite'], 'app-geosite');
      expect(geoXUrl['future-dataset'], 'keep');
      expect(geoXUrl['future-nested'], {
        'enabled': true,
        'mirrors': ['a', 'b'],
      });
    });

    test('missing geox-url map is created with all owned fields', () {
      final result = applyOwnedGeoXUrlPatch({'mode': 'rule'}, patch.toJson());
      expect(result['geox-url'], patch.toJson());
    });

    test('ownership set matches the GeoXUrl model serialization keys', () {
      expect(slclashOwnedGeoXUrlFields, const GeoXUrl().toJson().keys.toSet());
    });

    test(
      'runtime materialization preserves unowned GeoX URL siblings',
      () async {
        final input = _fixture('dns_ownership.yaml')
          ..['geox-url'] = {
            'mmdb': 'source-mmdb',
            'future-dataset': 'keep',
            'future-nested': {'enabled': true},
          };
        final output = await _materialize(
          input,
          patch: const PatchClashConfig(geoXUrl: patch),
        );
        final geoXUrl = output['geox-url'] as Map;
        expect(geoXUrl['mmdb'], 'app-mmdb');
        expect(geoXUrl['future-dataset'], 'keep');
        expect(geoXUrl['future-nested'], {'enabled': true});
      },
    );
  });

  group('TUN ownership contract', () {
    const patch = PatchClashConfig(
      tun: Tun(
        enable: true,
        device: 'Slclash-device',
        stack: TunStack.system,
        dnsHijack: ['8.8.8.8:53'],
        routeAddress: ['192.0.2.0/24'],
        autoRoute: true,
      ),
    );

    test('owned TUN fields: Slclash wins over source values', () async {
      final input = _fixture('tun_ownership.yaml');
      final output = await _materialize(input, patch: patch);
      expect(output['tun']['enable'], isTrue);
      expect(output['tun']['device'], 'Slclash-device');
      expect(output['tun']['stack'], 'system');
      expect(output['tun']['dns-hijack'], ['8.8.8.8:53']);
      expect(output['tun']['route-address'], ['192.0.2.0/24']);
      expect(output['tun']['auto-route'], isTrue);
    });

    test('kernel-owned TUN fields are preserved', () async {
      final input = _fixture('tun_ownership.yaml');
      final output = await _materialize(input, patch: patch);
      expect(output['tun']['auto-detect-interface'], isTrue);
      expect(output['tun']['mtu'], 9000);
      expect(output['tun']['strict-route'], isTrue);
    });

    test('synthetic future TUN field survives the ownership patch', () async {
      final input = _fixture('tun_ownership.yaml')
        ..['tun']['future-option'] = 'tun-future';
      final output = await _materialize(input, patch: patch);
      expect(output['tun']['future-option'], 'tun-future');
    });

    test(
      'applyOwnedTunPatch applies only owned keys and preserves siblings',
      () {
        final result = applyOwnedTunPatch(
          {
            'tun': {
              'enable': false,
              'mtu': 9000,
              'strict-route': true,
              'future-option': 'kept',
            },
          },
          {
            'enable': true,
            'stack': 'system',
            'mtu': 1400, // not owned: must be ignored
          },
        );
        final tun = result['tun'] as Map;
        expect(tun['enable'], isTrue);
        expect(tun['stack'], 'system');
        expect(tun['mtu'], 9000);
        expect(tun['strict-route'], isTrue);
        expect(tun['future-option'], 'kept');
      },
    );

    test('applyOwnedTunPatch creates the tun map when missing', () {
      final result = applyOwnedTunPatch(
        {'mode': 'rule'},
        {'enable': true, 'stack': 'system'},
      );
      expect(result['tun'], {'enable': true, 'stack': 'system'});
    });

    test(
      'materialized tun_ownership fixture reparses for bundled validity',
      () async {
        // Empty nameserverPolicy keeps the validity fixture free of
        // geosite:cn, which requires a local GeoSite.dat that CI-host
        // config.Parse cannot load.
        const validityPatch = PatchClashConfig(
          dns: Dns(
            nameserverPolicy: {},
            fallbackFilter: FallbackFilter(geoip: false, geosite: []),
          ),
        );
        final output = await _materialize(
          _fixture('tun_ownership.yaml'),
          patch: validityPatch,
          writeTo: p.join(
            'build',
            'mihomo-runtime-fixtures',
            'tun_ownership.yaml',
          ),
        );
        expect(output['tun']['auto-detect-interface'], isTrue);
        expect(output['tun']['mtu'], 9000);
        expect(output['tun']['strict-route'], isTrue);
      },
    );

    test('ownership sets match the Tun model serialization keys', () {
      // Keeps the Slclash-owned contract in sync with the Tun model: adding a
      // UI field without updating slclashOwnedTunFields fails CI immediately.
      expect(slclashOwnedTunFields, const Tun().toJson().keys.toSet());
    });
  });

  group('DNS ownership contract', () {
    const ownedPatch = PatchClashConfig(
      dns: Dns(
        nameserver: ['https://doh.pub/dns-query'],
        nameserverPolicy: {'patched.example': '8.8.8.8'},
        fallbackFilter: FallbackFilter(geoip: true, geosite: ['cn']),
      ),
    );

    test(
      'overrideDns=false with source enabled keeps the profile DNS untouched',
      () async {
        final input = _fixture('dns_ownership.yaml');
        final output = await _materialize(input);
        final dns = output['dns'] as Map;
        expect(dns['enable'], isTrue);
        expect(dns['nameserver'], ['1.1.1.1']);
        expect(dns['cache-algorithm'], 'arc');
        expect(dns['direct-nameserver'], ['223.5.5.5']);
      },
    );

    test('overrideDns=true applies Slclash-owned DNS fields', () async {
      final input = _fixture('dns_ownership.yaml');
      final output = await _materialize(
        input,
        patch: ownedPatch,
        overrideDns: true,
      );
      final dns = output['dns'] as Map;
      expect(dns['enable'], isTrue);
      expect(dns['nameserver'], ['https://doh.pub/dns-query']);
    });

    test('overrideDns=true preserves real kernel-owned DNS fields', () async {
      final input = _fixture('dns_ownership.yaml');
      final output = await _materialize(
        input,
        patch: ownedPatch,
        overrideDns: true,
      );
      final dns = output['dns'] as Map;
      expect(dns['cache-algorithm'], 'arc');
      expect(dns['direct-nameserver'], ['223.5.5.5']);
      expect(dns['direct-nameserver-follow-policy'], isTrue);
    });

    test(
      'synthetic unknown DNS sibling survives the ownership patch',
      () async {
        final input = _fixture('dns_ownership.yaml')
          ..['dns']['future-option'] = 'dns-future';
        final output = await _materialize(
          input,
          patch: ownedPatch,
          overrideDns: true,
        );
        expect((output['dns'] as Map)['future-option'], 'dns-future');
      },
    );

    test('fallback-filter owned subfields are overridden', () async {
      final input = _fixture('dns_ownership.yaml');
      final output = await _materialize(
        input,
        patch: ownedPatch,
        overrideDns: true,
      );
      final filter = output['dns']['fallback-filter'] as Map;
      expect(filter['geoip'], isTrue);
      expect(filter['geosite'], ['cn']);
    });

    test('fallback-filter synthetic unknown sibling is preserved', () async {
      final input = _fixture('dns_ownership.yaml')
        ..['dns']['fallback-filter']['future-field'] = 'filter-future';
      final output = await _materialize(
        input,
        patch: ownedPatch,
        overrideDns: true,
      );
      final filter = output['dns']['fallback-filter'] as Map;
      expect(filter['future-field'], 'filter-future');
      expect(filter['geoip'], isTrue);
    });

    test('nameserver-policy is replaced as an atomic Slclash map', () async {
      final input = _fixture('dns_ownership.yaml')
        ..['dns']['nameserver-policy'] = {'source.example': '1.1.1.1'};
      final output = await _materialize(
        input,
        patch: ownedPatch,
        overrideDns: true,
      );
      final policy = output['dns']['nameserver-policy'] as Map;
      expect(policy, {'patched.example': '8.8.8.8'});
      expect(policy, isNot(contains('source.example')));
    });

    test(
      'source dns.enable=false keeps automatic Slclash DNS behavior',
      () async {
        final input = _fixture('dns_ownership.yaml')..['dns']['enable'] = false;
        final output = await _materialize(input, patch: ownedPatch);
        final dns = output['dns'] as Map;
        expect(dns['enable'], isTrue);
        expect(dns['nameserver'], ['https://doh.pub/dns-query', 'system://']);
        expect(dns['cache-algorithm'], 'arc');
      },
    );

    test('missing source dns keeps automatic Slclash DNS behavior', () async {
      final input = _fixture('dns_ownership.yaml')..remove('dns');
      final output = await _materialize(input, patch: ownedPatch);
      final dns = output['dns'] as Map;
      expect(dns['enable'], isTrue);
      expect(dns['nameserver'], ['https://doh.pub/dns-query', 'system://']);
    });

    test('appendSystemDns adds exactly one system resolver', () async {
      final input = _fixture('dns_ownership.yaml')..remove('dns');
      final output = await _materialize(
        input,
        patch: ownedPatch,
        appendSystemDns: true,
      );
      final nameserver = output['dns']['nameserver'] as List;
      expect(nameserver.where((item) => item == 'system://'), hasLength(1));
    });

    test(
      'core ipv6 off forces dns.ipv6 off without replacing nameservers',
      () async {
        final input = _fixture('dns_ownership.yaml')..['dns']['ipv6'] = true;
        final output = await _materialize(input);
        final dns = output['dns'] as Map;
        expect(dns['ipv6'], isFalse);
        expect(dns['nameserver'], ['1.1.1.1']);
        expect(dns['direct-nameserver'], ['223.5.5.5']);
      },
    );

    test('core ipv6 on leaves profile dns.ipv6 enabled', () async {
      final input = _fixture('dns_ownership.yaml')..['dns']['ipv6'] = true;
      final output = await _materialize(
        input,
        patch: const PatchClashConfig(ipv6: true),
      );
      expect((output['dns'] as Map)['ipv6'], isTrue);
      expect((output['dns'] as Map)['nameserver'], ['1.1.1.1']);
    });

    test('appendSystemDns runs after the ownership patch', () async {
      final input = _fixture('dns_ownership.yaml')..remove('dns');
      final output = await _materialize(
        input,
        patch: ownedPatch,
        appendSystemDns: true,
      );
      // The automatic system:// (from !isEnableDns) already contains
      // system:// once; appendSystemDns must not duplicate it.
      final nameserver = output['dns']['nameserver'] as List;
      expect(nameserver.first, 'https://doh.pub/dns-query');
      expect(nameserver.last, 'system://');
      expect(nameserver.where((item) => item == 'system://'), hasLength(1));
    });

    test('ownership sets match the Dns model serialization keys', () {
      // Keeps the Slclash-owned DNS contract in sync with the Dns model.
      expect(slclashOwnedDnsFields, const Dns().toJson().keys.toSet());
      expect(
        slclashOwnedFallbackFilterFields,
        const FallbackFilter().toJson().keys.toSet(),
      );
    });

    test(
      'materialized dns_ownership fixture reparses for bundled validity',
      () async {
        // Empty nameserverPolicy keeps the validity fixture free of
        // geosite:cn, which requires a local GeoSite.dat that CI-host
        // config.Parse cannot load.
        const validityPatch = PatchClashConfig(
          dns: Dns(
            nameserverPolicy: {},
            fallbackFilter: FallbackFilter(geoip: false, geosite: []),
          ),
        );
        final output = await _materialize(
          _fixture('dns_ownership.yaml'),
          patch: validityPatch,
          overrideDns: true,
          writeTo: p.join(
            'build',
            'mihomo-runtime-fixtures',
            'dns_ownership.yaml',
          ),
        );
        final dns = output['dns'] as Map;
        expect(dns['cache-algorithm'], 'arc');
        expect(dns['direct-nameserver'], ['223.5.5.5']);
      },
    );
  });
}
