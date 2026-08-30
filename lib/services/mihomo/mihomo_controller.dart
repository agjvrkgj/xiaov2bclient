import 'package:dio/dio.dart';

import 'mihomo_constants.dart';

class MihomoController {
  final Dio _dio;
  String _secret = '';

  MihomoController()
      : _dio = Dio(
          BaseOptions(
            baseUrl: MihomoConstants.controllerBaseUrl,
            connectTimeout: const Duration(seconds: 2),
            receiveTimeout: const Duration(seconds: 3),
            sendTimeout: const Duration(seconds: 3),
            validateStatus: (status) => status != null && status < 500,
          ),
        );

  void configure(String secret) {
    _secret = secret;
  }

  Options get _options => Options(
        headers: <String, String>{
          if (_secret.isNotEmpty) 'Authorization': 'Bearer $_secret',
        },
      );

  Future<bool> isReady() async {
    try {
      final response = await _dio.get<dynamic>('/version', options: _options);
      return response.statusCode == 200 && response.data is Map;
    } catch (_) {
      return false;
    }
  }

  Future<void> waitUntilReady({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await isReady()) return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw StateError('Mihomo 内核启动超时');
  }

  Future<String?> getVersion() async {
    try {
      final response = await _dio.get<dynamic>('/version', options: _options);
      final data = response.data;
      if (response.statusCode == 200 && data is Map) {
        return data['version']?.toString();
      }
    } catch (_) {
      // The caller treats a missing version as an unavailable controller.
    }
    return null;
  }

  Future<Map<String, dynamic>> getProxies() async {
    final response = await _dio.get<dynamic>('/proxies', options: _options);
    if (response.statusCode != 200 || response.data is! Map) {
      throw StateError('无法读取 Mihomo 节点列表');
    }
    final data = Map<String, dynamic>.from(response.data as Map);
    final proxies = data['proxies'];
    if (proxies is! Map) return <String, dynamic>{};
    return <String, dynamic>{
      for (final entry in proxies.entries)
        entry.key.toString(): entry.value,
    };
  }

  Future<void> setMode(String mode) async {
    final response = await _dio.patch<dynamic>(
      '/configs',
      data: <String, String>{'mode': mode == 'global' ? 'global' : 'rule'},
      options: _options,
    );
    if (response.statusCode != 204 && response.statusCode != 200) {
      throw StateError('切换代理模式失败');
    }
  }

  Future<void> selectProxy(String proxyName) async {
    final proxies = await getProxies();
    final targetGroups = <String>[];

    for (final entry in proxies.entries) {
      final value = entry.value;
      if (value is! Map || value['type']?.toString() != 'Selector') {
        continue;
      }
      final members = value['all'];
      if (members is List &&
          members.any((member) => member.toString() == proxyName)) {
        targetGroups.add(entry.key);
      }
    }

    if (targetGroups.isEmpty) {
      throw StateError('订阅配置中找不到节点：$proxyName');
    }

    for (final group in targetGroups) {
      final encodedGroup = Uri.encodeComponent(group);
      final response = await _dio.put<dynamic>(
        '/proxies/$encodedGroup',
        data: <String, String>{'name': proxyName},
        options: _options,
      );
      if (response.statusCode != 204 && response.statusCode != 200) {
        throw StateError('切换节点失败：$group');
      }
    }
  }
}
