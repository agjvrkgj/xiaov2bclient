import 'dart:convert';

import 'package:yaml/yaml.dart';

import 'mihomo_constants.dart';

enum MihomoRuntimeMode {
  androidVpn,
  desktopSystemProxy,
  unsupported,
}

class MihomoPreparedConfig {
  final String data;
  final List<String> proxyNames;

  const MihomoPreparedConfig({
    required this.data,
    required this.proxyNames,
  });
}

class MihomoConfigException implements Exception {
  final String message;

  const MihomoConfigException(this.message);

  @override
  String toString() => message;
}

class MihomoConfigBuilder {
  const MihomoConfigBuilder();

  MihomoPreparedConfig build({
    required String subscriptionYaml,
    required String secret,
    required MihomoRuntimeMode runtimeMode,
    String mode = 'rule',
    String? selectedProxy,
  }) {
    if (runtimeMode == MihomoRuntimeMode.unsupported) {
      throw const MihomoConfigException('当前平台暂不支持 Mihomo 内核');
    }
    if (subscriptionYaml.trim().isEmpty) {
      throw const MihomoConfigException('订阅内容为空');
    }

    final dynamic parsed;
    try {
      parsed = loadYaml(subscriptionYaml);
    } catch (error) {
      throw MihomoConfigException('Mihomo 订阅解析失败：$error');
    }

    final plain = _toPlainValue(parsed);
    if (plain is! Map<String, dynamic>) {
      throw const MihomoConfigException('订阅不是有效的 Clash/Mihomo 配置');
    }

    final config = plain;
    final proxies = _asList(config['proxies']);
    final providers = _asStringMap(config['proxy-providers']);
    if (proxies.isEmpty && providers.isEmpty) {
      throw const MihomoConfigException('订阅中没有可用节点或代理提供器');
    }

    final proxyNames = proxies
        .whereType<Map>()
        .map((proxy) => proxy['name']?.toString() ?? '')
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList(growable: false);

    config
      ..['mixed-port'] = MihomoConstants.mixedPort
      ..['external-controller'] =
          '${MihomoConstants.controllerHost}:${MihomoConstants.controllerPort}'
      ..['secret'] = secret
      ..['allow-lan'] = false
      ..['bind-address'] = MihomoConstants.controllerHost
      ..['mode'] = mode == 'global' ? 'global' : 'rule'
      ..['log-level'] = 'warning'
      ..['ipv6'] = false
      ..['unified-delay'] = true
      ..['tcp-concurrent'] = true;

    config.remove('external-controller-tls');
    config.remove('external-controller-unix');
    config.remove('external-controller-pipe');
    config.remove('external-ui');
    config.remove('external-ui-url');

    final profile = _asStringMap(config['profile']);
    profile['store-selected'] = true;
    profile['store-fake-ip'] = true;
    config['profile'] = profile;

    final dns = _asStringMap(config['dns']);
    dns['enable'] = true;
    dns['ipv6'] = false;
    dns.putIfAbsent('enhanced-mode', () => 'fake-ip');
    if (runtimeMode == MihomoRuntimeMode.androidVpn) {
      // VpnService uses 198.18.0.1/30; keep Mihomo's derived TUN prefix in
      // lockstep even when a subscription supplies a custom fake-IP range.
      dns['fake-ip-range'] = '198.18.0.1/16';
    } else {
      dns.putIfAbsent('fake-ip-range', () => '198.18.0.1/16');
    }
    if (_asList(dns['default-nameserver']).isEmpty) {
      dns['default-nameserver'] = <String>['223.5.5.5', '1.1.1.1'];
    }
    if (_asList(dns['nameserver']).isEmpty) {
      dns['nameserver'] = <String>[
        'https://dns.alidns.com/dns-query',
        'https://1.1.1.1/dns-query',
      ];
    }
    config['dns'] = dns;

    final tun = _asStringMap(config['tun']);
    if (runtimeMode == MihomoRuntimeMode.androidVpn) {
      tun
        ..['enable'] = true
        ..['stack'] = 'mixed'
        ..['auto-route'] = false
        ..['auto-redirect'] = false
        ..['auto-detect-interface'] = false
        ..['dns-hijack'] = <String>['any:53']
        ..['mtu'] = 9000;
    } else {
      // Desktop uses Mihomo's mixed port plus a reversible system-proxy
      // configuration. This works without requiring administrator privileges.
      tun['enable'] = false;
    }
    config['tun'] = tun;

    if (selectedProxy != null && selectedProxy.isNotEmpty) {
      _preferProxy(config, selectedProxy);
    }

    return MihomoPreparedConfig(
      data: jsonEncode(config),
      proxyNames: proxyNames,
    );
  }

  void _preferProxy(Map<String, dynamic> config, String selectedProxy) {
    final groups = _asList(config['proxy-groups']);
    for (final group in groups.whereType<Map>()) {
      final members = _asList(group['proxies']);
      final index = members.indexWhere(
        (member) => member.toString() == selectedProxy,
      );
      if (index <= 0) continue;
      final selected = members.removeAt(index);
      members.insert(0, selected);
      group['proxies'] = members;
    }
  }

  dynamic _toPlainValue(dynamic value) {
    if (value is YamlMap || value is Map) {
      return <String, dynamic>{
        for (final entry in (value as Map).entries)
          entry.key.toString(): _toPlainValue(entry.value),
      };
    }
    if (value is YamlList || value is List) {
      return <dynamic>[
        for (final item in value as Iterable) _toPlainValue(item),
      ];
    }
    return value;
  }

  List<dynamic> _asList(dynamic value) {
    if (value is List) return List<dynamic>.from(value);
    return <dynamic>[];
  }

  Map<String, dynamic> _asStringMap(dynamic value) {
    if (value is Map) {
      return <String, dynamic>{
        for (final entry in value.entries)
          entry.key.toString(): _toPlainValue(entry.value),
      };
    }
    return <String, dynamic>{};
  }
}
