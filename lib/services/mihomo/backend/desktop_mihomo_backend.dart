import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../mihomo_config.dart';
import '../mihomo_constants.dart';
import 'mihomo_backend.dart';
import 'system_proxy_service.dart';

class DesktopMihomoBackend implements MihomoBackend {
  Directory? _runtimeDirectory;
  SystemProxyService? _systemProxy;
  Process? _process;
  int? _pid;
  bool _stopping = false;
  bool _savedProxyEnabled = false;
  String? _lastError;
  String? _lastLog;

  @override
  MihomoRuntimeMode get runtimeMode => MihomoRuntimeMode.desktopSystemProxy;

  @override
  bool get isSupported =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  Directory get _runtimeDir {
    final directory = _runtimeDirectory;
    if (directory == null) throw StateError('Mihomo 桌面后端尚未初始化');
    return directory;
  }

  SystemProxyService get _proxyService {
    final service = _systemProxy;
    if (service == null) throw StateError('系统代理服务尚未初始化');
    return service;
  }

  File get _runtimeStateFile =>
      File(path.join(_runtimeDir.path, 'runtime.json'));

  @override
  Future<void> initialize() async {
    if (_runtimeDirectory != null) return;
    final supportDirectory = await getApplicationSupportDirectory();
    _runtimeDirectory = Directory(
      path.join(supportDirectory.path, 'mihomo'),
    );
    await _runtimeDir.create(recursive: true);
    _systemProxy = SystemProxyService(_runtimeDir);

    _pid = await _readSavedPid();
    if (_pid != null && await _isOwnedMihomoPid(_pid!)) {
      if (_savedProxyEnabled && await _proxyService.hasSnapshot) return;
      await _terminatePid(_pid!, force: true);
    }

    _pid = null;
    await _proxyService.restore();
    if (await _runtimeStateFile.exists()) {
      await _runtimeStateFile.delete();
    }
  }

  @override
  Future<MihomoBackendStatus> status() async {
    await initialize();
    final processPid = _process?.pid ?? _pid;
    if (processPid == null) {
      return MihomoBackendStatus(running: false, error: _lastError);
    }
    final running = _process != null
        ? await _isPidRunning(processPid)
        : await _isOwnedMihomoPid(processPid);
    if (!running) {
      _pid = null;
      _process = null;
      await _proxyService.restore();
      if (await _runtimeStateFile.exists()) {
        await _runtimeStateFile.delete();
      }
    }
    return MihomoBackendStatus(running: running, error: _lastError);
  }

  @override
  Future<void> start({
    required String config,
    required String secret,
  }) async {
    await initialize();
    if ((await status()).running) {
      throw StateError('Mihomo 内核已经在运行');
    }

    _lastError = null;
    _lastLog = null;
    final executable = await _ensureCoreExecutable();
    final configFile = File(path.join(_runtimeDir.path, 'config.json'));
    await configFile.writeAsString(config, flush: true);
    if (!Platform.isWindows) {
      await Process.run('chmod', <String>['600', configFile.path]);
    }

    final validation = await Process.run(
      executable.path,
      <String>['-t', '-d', _runtimeDir.path, '-f', configFile.path],
      workingDirectory: _runtimeDir.path,
      runInShell: false,
    );
    if (validation.exitCode != 0) {
      final error = validation.stderr.toString().trim();
      throw StateError(error.isEmpty ? 'Mihomo 配置校验失败' : error);
    }

    _stopping = false;
    final process = await Process.start(
      executable.path,
      <String>['-d', _runtimeDir.path, '-f', configFile.path],
      workingDirectory: _runtimeDir.path,
      runInShell: false,
      mode: ProcessStartMode.normal,
    );
    _process = process;
    _pid = process.pid;
    await _runtimeStateFile.writeAsString(
      jsonEncode(<String, dynamic>{
        'pid': process.pid,
        'executable': executable.path,
        'version': MihomoConstants.version,
        'startedAt': DateTime.now().toUtc().toIso8601String(),
        'proxyEnabled': false,
      }),
      flush: true,
    );

    process.stdout.transform(utf8.decoder).listen(_captureLog);
    process.stderr.transform(utf8.decoder).listen(_captureLog);
    unawaited(_watchProcess(process));

    try {
      await _waitForControllerPort();
      await _proxyService.enable(
        host: MihomoConstants.controllerHost,
        port: MihomoConstants.mixedPort,
      );
      await _markSystemProxyEnabled();
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  void _captureLog(String data) {
    final line = data.trim();
    if (line.isEmpty) return;
    _lastLog = line.length > 500 ? line.substring(line.length - 500) : line;
  }

  Future<void> _watchProcess(Process process) async {
    final exitCode = await process.exitCode;
    if (_process != process) return;
    _process = null;
    _pid = null;
    if (!_stopping) {
      final logSuffix = _lastLog == null ? '' : '：$_lastLog';
      _lastError = 'Mihomo 内核已异常退出（$exitCode）$logSuffix';
      try {
        await _proxyService.restore();
      } catch (_) {
        // The snapshot remains on disk and will be restored on the next start.
      }
    }
    if (await _runtimeStateFile.exists()) {
      await _runtimeStateFile.delete();
    }
  }

  Future<void> _waitForControllerPort() async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      final current = await status();
      if (!current.running) {
        throw StateError(_lastError ?? _lastLog ?? 'Mihomo 内核启动失败');
      }
      try {
        final socket = await Socket.connect(
          MihomoConstants.controllerHost,
          MihomoConstants.controllerPort,
          timeout: const Duration(milliseconds: 500),
        );
        await socket.close();
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    throw StateError(_lastError ?? _lastLog ?? 'Mihomo 控制端口启动超时');
  }

  @override
  Future<void> stop() async {
    await initialize();
    _stopping = true;
    Object? restoreError;
    try {
      await _proxyService.restore();
    } catch (error) {
      restoreError = error;
    }

    final process = _process;
    final processPid = process?.pid ?? _pid;
    if (process != null) {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        await _terminatePid(process.pid, force: true);
      }
    } else if (processPid != null && await _isOwnedMihomoPid(processPid)) {
      await _terminatePid(processPid, force: true);
    }
    _process = null;
    _pid = null;
    if (await _runtimeStateFile.exists()) {
      await _runtimeStateFile.delete();
    }
    _stopping = false;
    if (restoreError != null) throw restoreError;
  }

  Future<File> _ensureCoreExecutable() async {
    final executableName = Platform.isWindows ? 'mihomo.exe' : 'mihomo';
    final executable = File(path.join(_runtimeDir.path, executableName));
    final versionFile = File(path.join(_runtimeDir.path, 'core.version'));
    final installedVersion = await versionFile.exists()
        ? (await versionFile.readAsString()).trim()
        : '';
    if (await executable.exists() &&
        installedVersion == MihomoConstants.version) {
      return executable;
    }

    final platformDirectory = Platform.isWindows
        ? 'windows'
        : Platform.isMacOS
            ? 'macos'
            : 'linux';
    final assetPath = 'assets/core/$platformDirectory/$executableName';
    final ByteData data;
    try {
      data = await rootBundle.load(assetPath);
    } on FlutterError {
      throw StateError(
        '安装包未包含 Mihomo ${MihomoConstants.version}。请先运行 '
        'python tool/fetch_mihomo.py 后重新构建。',
      );
    }
    await executable.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
    if (!Platform.isWindows) {
      final chmod = await Process.run('chmod', <String>['700', executable.path]);
      if (chmod.exitCode != 0) {
        throw StateError('无法为 Mihomo 内核添加执行权限');
      }
    }
    await versionFile.writeAsString(MihomoConstants.version, flush: true);
    return executable;
  }

  Future<int?> _readSavedPid() async {
    if (!await _runtimeStateFile.exists()) return null;
    try {
      final decoded = jsonDecode(await _runtimeStateFile.readAsString());
      if (decoded is Map) {
        _savedProxyEnabled = decoded['proxyEnabled'] == true;
        return int.tryParse(decoded['pid']?.toString() ?? '');
      }
    } catch (_) {
      // A malformed runtime marker is treated as stale.
    }
    return null;
  }

  Future<void> _markSystemProxyEnabled() async {
    if (!await _runtimeStateFile.exists()) return;
    final decoded = jsonDecode(await _runtimeStateFile.readAsString());
    if (decoded is! Map) return;
    final state = Map<String, dynamic>.from(decoded);
    state['proxyEnabled'] = true;
    await _runtimeStateFile.writeAsString(jsonEncode(state), flush: true);
    _savedProxyEnabled = true;
  }

  Future<bool> _isPidRunning(int pid) async {
    if (pid <= 0) return false;
    if (Platform.isWindows) {
      final result = await Process.run(
        'tasklist',
        <String>['/FI', 'PID eq $pid', '/NH'],
      );
      return result.exitCode == 0 &&
          RegExp('\\b$pid\\b').hasMatch(result.stdout.toString());
    }
    final result = await Process.run('kill', <String>['-0', pid.toString()]);
    return result.exitCode == 0;
  }

  Future<bool> _isOwnedMihomoPid(int pid) async {
    if (!await _isPidRunning(pid)) return false;
    final executableName = Platform.isWindows ? 'mihomo.exe' : 'mihomo';
    final expected = path.normalize(
      path.join(_runtimeDir.path, executableName),
    );

    if (Platform.isWindows) {
      final result = await Process.run(
        'powershell',
        <String>[
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "(Get-CimInstance Win32_Process -Filter 'ProcessId = $pid').ExecutablePath",
        ],
      );
      if (result.exitCode != 0) return false;
      return path.normalize(result.stdout.toString().trim()).toLowerCase() ==
          expected.toLowerCase();
    }

    final result = await Process.run(
      'ps',
      <String>['-p', pid.toString(), '-o', 'command='],
    );
    if (result.exitCode != 0) return false;
    return result.stdout.toString().trim().startsWith(expected);
  }

  Future<void> _terminatePid(int pid, {required bool force}) async {
    final ProcessResult result;
    if (Platform.isWindows) {
      result = await Process.run(
        'taskkill',
        <String>['/PID', pid.toString(), '/T', if (force) '/F'],
      );
    } else {
      result = await Process.run(
        'kill',
        <String>[force ? '-KILL' : '-TERM', '$pid'],
      );
    }
    if (result.exitCode != 0 && await _isPidRunning(pid)) {
      final message = result.stderr.toString().trim();
      throw StateError(message.isEmpty ? '无法停止 Mihomo 进程 $pid' : message);
    }
  }
}
