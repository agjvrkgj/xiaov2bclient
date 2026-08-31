import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_ui_demo/services/mihomo/mihomo_config.dart';

void main() {
  const builder = MihomoConfigBuilder();
  const subscription = '''
proxies:
  - name: Hong Kong
    type: ss
    server: 203.0.113.1
    port: 443
    cipher: aes-128-gcm
    password: test
proxy-groups:
  - name: PROXY
    type: select
    proxies: [DIRECT, Hong Kong]
rules:
  - MATCH,PROXY
''';

  test('builds an Android TUN config with local-only controller', () {
    final prepared = builder.build(
      subscriptionYaml: subscription,
      secret: 'test-secret',
      runtimeMode: MihomoRuntimeMode.androidVpn,
      selectedProxy: 'Hong Kong',
    );
    final config = jsonDecode(prepared.data) as Map<String, dynamic>;
    final tun = config['tun'] as Map<String, dynamic>;
    final dns = config['dns'] as Map<String, dynamic>;
    final groups = config['proxy-groups'] as List<dynamic>;
    final proxyGroup = groups.first as Map<String, dynamic>;

    expect(config['external-controller'], '127.0.0.1:19090');
    expect(config['allow-lan'], isFalse);
    expect(config['secret'], 'test-secret');
    expect(tun['enable'], isTrue);
    expect(tun['auto-route'], isFalse);
    expect(tun['stack'], 'mixed');
    expect(dns['fake-ip-range'], '198.18.0.1/16');
    expect(proxyGroup['proxies'], <dynamic>['Hong Kong', 'DIRECT']);
    expect(prepared.proxyNames, <String>['Hong Kong']);
  });

  test('desktop config uses mixed port and disables TUN', () {
    final prepared = builder.build(
      subscriptionYaml: subscription,
      secret: 'test-secret',
      runtimeMode: MihomoRuntimeMode.desktopSystemProxy,
      mode: 'global',
    );
    final config = jsonDecode(prepared.data) as Map<String, dynamic>;
    final tun = config['tun'] as Map<String, dynamic>;

    expect(config['mixed-port'], 17890);
    expect(config['mode'], 'global');
    expect(tun['enable'], isFalse);
  });

  test('rejects subscriptions without nodes or providers', () {
    expect(
      () => builder.build(
        subscriptionYaml: 'rules: []',
        secret: 'secret',
        runtimeMode: MihomoRuntimeMode.androidVpn,
      ),
      throwsA(isA<MihomoConfigException>()),
    );
  });
}
