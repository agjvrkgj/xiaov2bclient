import '../mihomo_config.dart';

class MihomoBackendStatus {
  final bool running;
  final String? error;

  const MihomoBackendStatus({
    required this.running,
    this.error,
  });
}

abstract class MihomoBackend {
  MihomoRuntimeMode get runtimeMode;

  bool get isSupported => runtimeMode != MihomoRuntimeMode.unsupported;

  Future<void> initialize();

  Future<MihomoBackendStatus> status();

  Future<void> start({
    required String config,
    required String secret,
  });

  Future<void> stop();
}

class UnsupportedMihomoBackend implements MihomoBackend {
  @override
  MihomoRuntimeMode get runtimeMode => MihomoRuntimeMode.unsupported;

  @override
  bool get isSupported => false;

  @override
  Future<void> initialize() async {}

  @override
  Future<MihomoBackendStatus> status() async {
    return const MihomoBackendStatus(running: false);
  }

  @override
  Future<void> start({required String config, required String secret}) {
    throw UnsupportedError('当前平台暂不支持 Mihomo 内核');
  }

  @override
  Future<void> stop() async {}
}
