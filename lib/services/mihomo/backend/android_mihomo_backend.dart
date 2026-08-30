import 'package:flutter/services.dart';

import '../mihomo_config.dart';
import 'mihomo_backend.dart';

class AndroidMihomoBackend implements MihomoBackend {
  static const MethodChannel _channel = MethodChannel('xiaov2b/mihomo');

  @override
  MihomoRuntimeMode get runtimeMode => MihomoRuntimeMode.androidVpn;

  @override
  bool get isSupported => true;

  @override
  Future<void> initialize() async {}

  @override
  Future<MihomoBackendStatus> status() async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('status');
      return MihomoBackendStatus(
        running: result?['running'] == true,
        error: result?['error']?.toString(),
      );
    } on PlatformException catch (error) {
      return MihomoBackendStatus(
        running: false,
        error: error.message ?? error.code,
      );
    }
  }

  @override
  Future<void> start({
    required String config,
    required String secret,
  }) async {
    final started = await _channel.invokeMethod<bool>(
      'start',
      <String, dynamic>{'config': config},
    );
    if (started != true) {
      throw StateError('Android VPN 启动失败');
    }

    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      final current = await status();
      if (current.running) return;
      if (current.error != null && current.error!.isNotEmpty) {
        throw StateError(current.error!);
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw StateError('Android VPN 内核启动超时');
  }

  @override
  Future<void> stop() async {
    await _channel.invokeMethod<void>('stop');
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      if (!(await status()).running) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('Android VPN 内核停止超时');
  }
}
