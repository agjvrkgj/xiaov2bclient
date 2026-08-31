import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api_service.dart';
import 'backend/backend_factory.dart';
import 'backend/mihomo_backend.dart';
import 'mihomo_config.dart';
import 'mihomo_controller.dart';

enum MihomoConnectionState {
  disconnected,
  connecting,
  connected,
  disconnecting,
  error,
}

class MihomoOperationException implements Exception {
  final String message;

  const MihomoOperationException(this.message);

  @override
  String toString() => message;
}

class MihomoService extends ChangeNotifier {
  static final MihomoService _instance = MihomoService._internal();

  factory MihomoService() => _instance;

  MihomoService._internal()
      : _backend = createMihomoBackend(),
        _controller = MihomoController();

  static const String _secretKey = 'mihomo_controller_secret';
  static const String _startedAtKey = 'mihomo_started_at';
  static const String _modeKey = 'mihomo_outbound_mode';
  static const String _selectedProxyKey = 'mihomo_selected_proxy';

  final MihomoBackend _backend;
  final MihomoController _controller;
  final MihomoConfigBuilder _configBuilder = const MihomoConfigBuilder();

  Future<void>? _initializeFuture;
  MihomoConnectionState _state = MihomoConnectionState.disconnected;
  DateTime? _connectedAt;
  String? _lastError;
  String? _coreVersion;
  String _mode = 'rule';
  String? _selectedProxy;
  String _secret = '';
  Future<void> _operationTail = Future<void>.value();
  bool _shutdownRequested = false;

  MihomoConnectionState get state => _state;
  bool get isConnected => _state == MihomoConnectionState.connected;
  bool get isBusy =>
      _state == MihomoConnectionState.connecting ||
      _state == MihomoConnectionState.disconnecting;
  bool get isSupported => _backend.isSupported;
  DateTime? get connectedAt => _connectedAt;
  String? get lastError => _lastError;
  String? get coreVersion => _coreVersion;
  String get mode => _mode;
  String? get selectedProxy => _selectedProxy;

  Future<void> initialize() {
    return _initializeFuture ??= _doInitialize();
  }

  Future<void> _doInitialize() async {
    final prefs = await SharedPreferences.getInstance();
    _mode = prefs.getString(_modeKey) == 'global' ? 'global' : 'rule';
    _selectedProxy = prefs.getString(_selectedProxyKey);
    _secret = prefs.getString(_secretKey) ?? _generateSecret();
    await prefs.setString(_secretKey, _secret);
    _controller.configure(_secret);

    if (!_backend.isSupported) {
      _state = MihomoConnectionState.disconnected;
      notifyListeners();
      return;
    }

    await _backend.initialize();
    final status = await _backend.status();
    _lastError = status.error;
    if (status.running) {
      try {
        await _controller.waitUntilReady(timeout: const Duration(seconds: 5));
        _coreVersion = await _controller.getVersion();
        final startedAt = prefs.getInt(_startedAtKey);
        _connectedAt = startedAt == null
            ? DateTime.now()
            : DateTime.fromMillisecondsSinceEpoch(startedAt);
        _state = MihomoConnectionState.connected;
      } catch (_) {
        await _backend.stop();
        await prefs.remove(_startedAtKey);
        _state = MihomoConnectionState.disconnected;
      }
    } else {
      await prefs.remove(_startedAtKey);
      _state = MihomoConnectionState.disconnected;
    }
    notifyListeners();
  }

  Future<void> connect({String? selectedProxy}) {
    return _enqueue(() => _connect(selectedProxy: selectedProxy));
  }

  Future<void> _connect({String? selectedProxy}) async {
    await initialize();
    if (_shutdownRequested) return;
    if (!_backend.isSupported) {
      throw const MihomoOperationException('当前平台暂不支持 Mihomo 内核');
    }
    if (isConnected || isBusy) return;

    _state = MihomoConnectionState.connecting;
    _lastError = null;
    notifyListeners();

    try {
      final subscription = await ApiService().fetchMihomoSubscription();
      final preferredProxy = selectedProxy ?? _selectedProxy;
      final prepared = _configBuilder.build(
        subscriptionYaml: subscription,
        secret: _secret,
        runtimeMode: _backend.runtimeMode,
        mode: _mode,
        selectedProxy: preferredProxy,
      );
      if (_shutdownRequested) return;
      await _backend.start(config: prepared.data, secret: _secret);
      await _controller.waitUntilReady();
      _coreVersion = await _controller.getVersion();

      if (preferredProxy != null && preferredProxy.isNotEmpty) {
        try {
          await _controller.selectProxy(preferredProxy);
          await _saveSelectedProxy(preferredProxy);
        } catch (error) {
          // A provider can rename a node between the API list and generated
          // config. Keep the working connection and surface the selection issue.
          _lastError = _describeError(error);
        }
      }

      _connectedAt = DateTime.now();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        _startedAtKey,
        _connectedAt!.millisecondsSinceEpoch,
      );
      _state = MihomoConnectionState.connected;
      notifyListeners();
    } catch (error) {
      try {
        await _backend.stop();
      } catch (_) {
        // Preserve the original startup failure.
      }
      _connectedAt = null;
      _coreVersion = null;
      _lastError = _describeError(error);
      _state = MihomoConnectionState.error;
      notifyListeners();
      throw MihomoOperationException(_lastError!);
    }
  }

  Future<void> disconnect() {
    return _enqueue(_disconnect);
  }

  Future<void> _disconnect() async {
    await initialize();
    if (_state == MihomoConnectionState.disconnected ||
        _state == MihomoConnectionState.disconnecting) {
      return;
    }
    _state = MihomoConnectionState.disconnecting;
    notifyListeners();
    try {
      await _backend.stop();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_startedAtKey);
      _connectedAt = null;
      _coreVersion = null;
      _lastError = null;
      _state = MihomoConnectionState.disconnected;
      notifyListeners();
    } catch (error) {
      _lastError = _describeError(error);
      _state = MihomoConnectionState.error;
      notifyListeners();
      throw MihomoOperationException(_lastError!);
    }
  }

  Future<void> selectProxy(String proxyName) async {
    if (!isConnected) {
      await _saveSelectedProxy(proxyName);
      return;
    }
    try {
      await _controller.selectProxy(proxyName);
      await _saveSelectedProxy(proxyName);
      _lastError = null;
      notifyListeners();
    } catch (error) {
      _lastError = _describeError(error);
      notifyListeners();
      throw MihomoOperationException(_lastError!);
    }
  }

  Future<void> setMode(String mode) async {
    _mode = mode == 'global' ? 'global' : 'rule';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modeKey, _mode);
    if (isConnected) {
      try {
        await _controller.setMode(_mode);
      } catch (error) {
        _lastError = _describeError(error);
        notifyListeners();
        throw MihomoOperationException(_lastError!);
      }
    }
    notifyListeners();
  }

  Future<void> refreshStatus() async {
    await initialize();
    if (!_backend.isSupported) return;
    final backendStatus = await _backend.status();
    final ready = backendStatus.running && await _controller.isReady();
    if (ready) {
      _state = MihomoConnectionState.connected;
      _coreVersion = await _controller.getVersion();
    } else if (_state == MihomoConnectionState.connected) {
      _state = MihomoConnectionState.error;
      _connectedAt = null;
      _coreVersion = null;
      _lastError = backendStatus.error ?? 'Mihomo 内核已停止';
    }
    notifyListeners();
  }

  Future<void> shutdownOnDesktopExit() async {
    if (_backend.runtimeMode != MihomoRuntimeMode.desktopSystemProxy) return;
    _shutdownRequested = true;
    await disconnect();
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final previous = _operationTail;
    final queueSlot = Completer<void>();
    _operationTail = queueSlot.future;

    return () async {
      try {
        await previous;
      } catch (_) {
        // A failed operation must not poison the lifecycle queue.
      }
      try {
        await operation();
      } finally {
        queueSlot.complete();
      }
    }();
  }

  Future<void> _saveSelectedProxy(String proxyName) async {
    _selectedProxy = proxyName;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_selectedProxyKey, proxyName);
  }

  String _generateSecret() {
    final random = Random.secure();
    return List<int>.generate(32, (_) => random.nextInt(256))
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  String _describeError(Object error) {
    if (error is MihomoOperationException) return error.message;
    if (error is MihomoConfigException) return error.message;
    if (error is StateError) return error.message.toString();
    if (error is UnsupportedError) {
      return error.message?.toString() ?? '当前平台不支持此操作';
    }
    final text = error.toString();
    return text.startsWith('Exception: ')
        ? text.substring('Exception: '.length)
        : text;
  }
}
