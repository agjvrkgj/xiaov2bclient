import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

class SystemProxyService {
  final Directory runtimeDirectory;

  SystemProxyService(this.runtimeDirectory);

  File get _snapshotFile =>
      File(path.join(runtimeDirectory.path, 'system_proxy_snapshot.json'));

  Future<bool> get hasSnapshot => _snapshotFile.exists();

  Future<void> enable({required String host, required int port}) async {
    await runtimeDirectory.create(recursive: true);
    if (await _snapshotFile.exists()) {
      await restore();
    }

    final Map<String, dynamic> snapshot;
    if (Platform.isWindows) {
      snapshot = await _captureWindows();
    } else if (Platform.isMacOS) {
      snapshot = await _captureMacOS();
    } else if (Platform.isLinux) {
      snapshot = await _captureLinux();
    } else {
      throw UnsupportedError('当前桌面系统不支持自动设置系统代理');
    }

    await _snapshotFile.writeAsString(jsonEncode(snapshot), flush: true);
    try {
      if (Platform.isWindows) {
        await _enableWindows(host, port);
      } else if (Platform.isMacOS) {
        await _enableMacOS(snapshot, host, port);
      } else {
        await _enableLinux(host, port);
      }
    } catch (_) {
      await restore();
      rethrow;
    }
  }

  Future<void> restore() async {
    if (!await _snapshotFile.exists()) return;
    final raw = await _snapshotFile.readAsString();
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw StateError('系统代理备份损坏，无法安全恢复');
    }
    final snapshot = Map<String, dynamic>.from(decoded);

    if (Platform.isWindows) {
      await _restoreWindows(snapshot);
    } else if (Platform.isMacOS) {
      await _restoreMacOS(snapshot);
    } else if (Platform.isLinux) {
      await _restoreLinux(snapshot);
    }
    await _snapshotFile.delete();
  }

  Future<Map<String, dynamic>> _captureWindows() async {
    const key =
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
    final values = <String, dynamic>{};
    for (final name in const <String>[
      'ProxyEnable',
      'ProxyServer',
      'ProxyOverride',
      'AutoConfigURL',
    ]) {
      values[name] = await _queryWindowsValue(key, name);
    }
    return <String, dynamic>{'platform': 'windows', 'values': values};
  }

  Future<Map<String, dynamic>> _queryWindowsValue(
    String key,
    String name,
  ) async {
    final result = await Process.run('reg', <String>['query', key, '/v', name]);
    if (result.exitCode != 0) return <String, dynamic>{'exists': false};
    for (final line in result.stdout.toString().split(RegExp(r'[\r\n]+'))) {
      final parts = line.trim().split(RegExp(r'\s{2,}'));
      if (parts.length >= 3 && parts.first == name) {
        return <String, dynamic>{
          'exists': true,
          'type': parts[1],
          'value': parts.sublist(2).join('  '),
        };
      }
    }
    return <String, dynamic>{'exists': false};
  }

  Future<void> _enableWindows(String host, int port) async {
    const key =
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
    await _setWindowsValue(key, 'ProxyEnable', 'REG_DWORD', '1');
    await _setWindowsValue(key, 'ProxyServer', 'REG_SZ', '$host:$port');
    await _setWindowsValue(
      key,
      'ProxyOverride',
      'REG_SZ',
      '<local>;localhost;127.*;[::1]',
    );
    await _deleteWindowsValue(key, 'AutoConfigURL');
    await _notifyWindowsProxyChanged();
  }

  Future<void> _restoreWindows(Map<String, dynamic> snapshot) async {
    const key =
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
    final values = snapshot['values'];
    if (values is! Map) throw StateError('Windows 系统代理备份无效');
    for (final entry in values.entries) {
      final value = entry.value;
      if (value is Map && value['exists'] == true) {
        await _setWindowsValue(
          key,
          entry.key.toString(),
          value['type']?.toString() ?? 'REG_SZ',
          value['value']?.toString() ?? '',
        );
      } else {
        await _deleteWindowsValue(key, entry.key.toString());
      }
    }
    await _notifyWindowsProxyChanged();
  }

  Future<void> _setWindowsValue(
    String key,
    String name,
    String type,
    String value,
  ) async {
    await _runChecked(
      'reg',
      <String>[
        'add',
        key,
        '/v',
        name,
        '/t',
        type,
        '/d',
        value,
        '/f',
      ],
    );
  }

  Future<void> _deleteWindowsValue(String key, String name) async {
    await Process.run('reg', <String>['delete', key, '/v', name, '/f']);
  }

  Future<void> _notifyWindowsProxyChanged() async {
    const script = r'''
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WinInetSettings {
  [DllImport("wininet.dll", SetLastError = true)]
  public static extern bool InternetSetOption(IntPtr hInternet, int option, IntPtr buffer, int length);
}
"@
[WinInetSettings]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
[WinInetSettings]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
''';
    await _runChecked(
      'powershell',
      <String>['-NoProfile', '-NonInteractive', '-Command', script],
    );
  }

  Future<Map<String, dynamic>> _captureMacOS() async {
    final result = await _runChecked(
      'networksetup',
      const <String>['-listallnetworkservices'],
    );
    final services = result.stdout
        .toString()
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .where(
          (line) =>
              line.isNotEmpty &&
              !line.startsWith('An asterisk') &&
              !line.startsWith('*'),
        )
        .toList(growable: false);
    if (services.isEmpty) {
      throw StateError('没有找到可配置的 macOS 网络服务');
    }

    final captured = <String, dynamic>{};
    for (final service in services) {
      final web = await _getMacProxy('-getwebproxy', service);
      final secure = await _getMacProxy('-getsecurewebproxy', service);
      final socks = await _getMacProxy('-getsocksfirewallproxy', service);
      for (final proxy in <Map<String, dynamic>>[web, secure, socks]) {
        final authenticated = proxy['Authenticated Proxy Enabled']?.toString();
        if (proxy['Enabled'] == 'Yes' &&
            authenticated != null &&
            authenticated != '0' &&
            authenticated.toLowerCase() != 'no') {
          throw StateError('检测到已启用的认证代理，为避免丢失凭据已停止接管系统代理');
        }
      }
      captured[service] = <String, dynamic>{
        'web': web,
        'secure': secure,
        'socks': socks,
      };
    }
    return <String, dynamic>{'platform': 'macos', 'services': captured};
  }

  Future<Map<String, dynamic>> _getMacProxy(
    String command,
    String service,
  ) async {
    final result = await _runChecked('networksetup', <String>[command, service]);
    final values = <String, dynamic>{};
    for (final line in result.stdout.toString().split(RegExp(r'[\r\n]+'))) {
      final separator = line.indexOf(':');
      if (separator <= 0) continue;
      values[line.substring(0, separator).trim()] =
          line.substring(separator + 1).trim();
    }
    return values;
  }

  Future<void> _enableMacOS(
    Map<String, dynamic> snapshot,
    String host,
    int port,
  ) async {
    final services = snapshot['services'];
    if (services is! Map) throw StateError('macOS 系统代理备份无效');
    for (final service in services.keys.map((key) => key.toString())) {
      await _setMacProxy('web', service, host, port, true);
      await _setMacProxy('secure', service, host, port, true);
      await _setMacProxy('socks', service, host, port, true);
    }
  }

  Future<void> _restoreMacOS(Map<String, dynamic> snapshot) async {
    final services = snapshot['services'];
    if (services is! Map) throw StateError('macOS 系统代理备份无效');
    for (final entry in services.entries) {
      if (entry.value is! Map) continue;
      final value = entry.value as Map;
      for (final kind in const <String>['web', 'secure', 'socks']) {
        final proxy = value[kind];
        if (proxy is! Map) continue;
        final server = proxy['Server']?.toString() ?? '';
        final port = int.tryParse(proxy['Port']?.toString() ?? '') ?? 0;
        final enabled = proxy['Enabled']?.toString() == 'Yes';
        await _setMacProxy(kind, entry.key.toString(), server, port, enabled);
      }
    }
  }

  Future<void> _setMacProxy(
    String kind,
    String service,
    String host,
    int port,
    bool enabled,
  ) async {
    final commands = <String, List<String>>{
      'web': <String>['-setwebproxy', '-setwebproxystate'],
      'secure': <String>['-setsecurewebproxy', '-setsecurewebproxystate'],
      'socks': <String>[
        '-setsocksfirewallproxy',
        '-setsocksfirewallproxystate',
      ],
    };
    final command = commands[kind]!;
    if (host.isNotEmpty && port > 0) {
      await _runChecked(
        'networksetup',
        <String>[command[0], service, host, port.toString()],
      );
    }
    await _runChecked(
      'networksetup',
      <String>[command[1], service, enabled ? 'on' : 'off'],
    );
  }

  static const Map<String, List<String>> _linuxKeys =
      <String, List<String>>{
    'mode': <String>['org.gnome.system.proxy', 'mode'],
    'http-host': <String>['org.gnome.system.proxy.http', 'host'],
    'http-port': <String>['org.gnome.system.proxy.http', 'port'],
    'https-host': <String>['org.gnome.system.proxy.https', 'host'],
    'https-port': <String>['org.gnome.system.proxy.https', 'port'],
    'socks-host': <String>['org.gnome.system.proxy.socks', 'host'],
    'socks-port': <String>['org.gnome.system.proxy.socks', 'port'],
    'ignore-hosts': <String>['org.gnome.system.proxy', 'ignore-hosts'],
  };

  Future<Map<String, dynamic>> _captureLinux() async {
    final available = await Process.run('which', const <String>['gsettings']);
    if (available.exitCode != 0) {
      throw UnsupportedError('当前 Linux 桌面没有 gsettings，无法安全设置系统代理');
    }
    final values = <String, dynamic>{};
    for (final entry in _linuxKeys.entries) {
      final result = await _runChecked(
        'gsettings',
        <String>['get', entry.value[0], entry.value[1]],
      );
      values[entry.key] = result.stdout.toString().trim();
    }
    return <String, dynamic>{'platform': 'linux', 'values': values};
  }

  Future<void> _enableLinux(String host, int port) async {
    await _setLinux('org.gnome.system.proxy.http', 'host', "'$host'");
    await _setLinux('org.gnome.system.proxy.http', 'port', port.toString());
    await _setLinux('org.gnome.system.proxy.https', 'host', "'$host'");
    await _setLinux('org.gnome.system.proxy.https', 'port', port.toString());
    await _setLinux('org.gnome.system.proxy.socks', 'host', "'$host'");
    await _setLinux('org.gnome.system.proxy.socks', 'port', port.toString());
    await _setLinux(
      'org.gnome.system.proxy',
      'ignore-hosts',
      "['localhost', '127.0.0.0/8', '::1']",
    );
    await _setLinux('org.gnome.system.proxy', 'mode', "'manual'");
  }

  Future<void> _restoreLinux(Map<String, dynamic> snapshot) async {
    final values = snapshot['values'];
    if (values is! Map) throw StateError('Linux 系统代理备份无效');
    for (final entry in _linuxKeys.entries) {
      final value = values[entry.key]?.toString();
      if (value == null || value.isEmpty) continue;
      await _setLinux(entry.value[0], entry.value[1], value);
    }
  }

  Future<void> _setLinux(String schema, String key, String value) async {
    await _runChecked('gsettings', <String>['set', schema, key, value]);
  }

  Future<ProcessResult> _runChecked(
    String executable,
    List<String> arguments,
  ) async {
    final result = await Process.run(executable, arguments, runInShell: false);
    if (result.exitCode != 0) {
      final error = result.stderr.toString().trim();
      throw StateError(
        error.isEmpty ? '$executable 执行失败（${result.exitCode}）' : error,
      );
    }
    return result;
  }
}
