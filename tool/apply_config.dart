import 'dart:io';
import 'package:yaml/yaml.dart';

void main() async {
  print('📦 开始应用打包配置...');

  final configFile = File('build_config.yaml');
  if (!configFile.existsSync()) {
    print('❌ 错误: 找不到 build_config.yaml 文件');
    exit(1);
  }

  final content = await configFile.readAsString();
  final config = loadYaml(content);

  final appName = config['app_name'] as String?;
  final processName = config['process_name'] as String?;
  final logoConfig = config['logo'] as Map?;

  if (appName != null) {
    await _updateAppName(appName);
  }

  if (processName != null) {
    await _updateProcessName(processName);
  }

  if (logoConfig != null) {
    await _generateIcons(logoConfig);
    await _updateWindowsIcon(logoConfig['image_path']);
  }

  print('✅ 配置应用完成！请运行 flutter clean 后再编译。');
}

Future<void> _updateAppName(String newName) async {
  print('📝 更新应用名称为: $newName');

  // 1. Android: AndroidManifest.xml
  await _updateFile(
    'android/app/src/main/AndroidManifest.xml',
    RegExp(r'android:label="[^"]*"'),
    'android:label="$newName"',
    'AndroidManifest.xml (Label)',
  );

  // 2. iOS/macOS: Info.plist
  for (final path in ['ios/Runner/Info.plist', 'macos/Runner/Info.plist']) {
    await _updateFile(
      path,
      RegExp(r'(<key>CFBundleDisplayName</key>\s*<string>)[^<]*(</string>)'),
      (Match match) => '${match.group(1)}$newName${match.group(2)}',
      '$path (CFBundleDisplayName)',
      isRegexReplace: true,
    );
    await _updateFile(
      path,
      RegExp(r'(<key>CFBundleName</key>\s*<string>)[^<]*(</string>)'),
      (Match match) => '${match.group(1)}$newName${match.group(2)}',
      '$path (CFBundleName)',
      isRegexReplace: true,
    );
  }

  // 3. macOS: AppInfo.xcconfig
  await _updateFile(
    'macos/Runner/Configs/AppInfo.xcconfig',
    RegExp(r'PRODUCT_NAME = .*'),
    'PRODUCT_NAME = $newName',
    'AppInfo.xcconfig (PRODUCT_NAME)',
  );

  // 4. Windows: Runner.rc (ProductName, FileDescription, InternalName)
  await _updateFile(
    'windows/runner/Runner.rc',
    RegExp(r'VALUE "ProductName", "[^"]*"'),
    'VALUE "ProductName", "$newName"',
    'Runner.rc (ProductName)',
  );
  await _updateFile(
    'windows/runner/Runner.rc',
    RegExp(r'VALUE "FileDescription", "[^"]*"'),
    'VALUE "FileDescription", "$newName"',
    'Runner.rc (FileDescription)',
  );
  
  // 5. Windows: main.cpp (Window Title)
  await _updateFile(
    'windows/runner/main.cpp',
    RegExp(r'window.Create\([^\)]*\)'),
    (Match match) {
       // Replace the title string inside window.Create(L"...", ...)
       // This is a bit tricky with regex, assuming standard Flutter template:
       // window.Create(L"window_title", origin, size)
       // We'll look for the first L"..."
       final old = match.group(0)!;
       return old.replaceFirst(RegExp(r'L"[^"]*"'), 'L"$newName"');
    },
    'main.cpp (Window Title)',
    isRegexReplace: true,
  );
}

Future<void> _updateProcessName(String newName) async {
  print('⚙️ 更新进程名称为: $newName');
  
  // Windows: CMakeLists.txt
  await _updateFile(
    'windows/CMakeLists.txt',
    RegExp(r'set\(BINARY_NAME "[^"]*"\)'),
    'set(BINARY_NAME "$newName")',
    'windows/CMakeLists.txt (BINARY_NAME)',
  );
  
  // Windows: Runner.rc (OriginalFilename, InternalName)
  await _updateFile(
    'windows/runner/Runner.rc',
    RegExp(r'VALUE "InternalName", "[^"]*"'),
    'VALUE "InternalName", "$newName"',
    'Runner.rc (InternalName)',
  );
   await _updateFile(
    'windows/runner/Runner.rc',
    RegExp(r'VALUE "OriginalFilename", "[^"]*"'),
    'VALUE "OriginalFilename", "$newName.exe"',
    'Runner.rc (OriginalFilename)',
  );
}

Future<void> _updateWindowsIcon(String? imagePath) async {
  if (imagePath == null) return;
  print('🖼️ 更新 Windows 图标...');
  
  // Check if magick is available (ImageMagick) or just warn user
  // Since we can't easily convert png to ico in pure dart without dependencies or external tools,
  // we will just copy if the source is .ico, otherwise warn.
  
  if (imagePath.endsWith('.ico')) {
     try {
       final source = File(imagePath);
       if (await source.exists()) {
         await source.copy('windows/runner/resources/app_icon.ico');
         print('  - ✅ Windows 图标已更新 (直接复制 .ico)');
       }
     } catch (e) {
       print('  - ❌ Windows 图标更新失败: $e');
     }
  } else {
    print('  - ⚠️ Windows 图标需要 .ico 格式。请将您的 logo 转为 .ico 并命名为 app_icon.ico 放入 windows/runner/resources/ 覆盖原文件，或者在 build_config.yaml 中指定一个 .ico 文件路径。');
    // Attempt to use a pub package if we were to expand this, but for now keep it simple.
  }
}

Future<void> _generateIcons(Map config) async {
  print('🎨 正在配置移动端图标...');
  
  final imagePath = config['image_path'];
  if (imagePath == null) {
    print('  - ⚠️ 未指定 image_path，跳过图标生成');
    return;
  }

  if (!await File(imagePath).exists()) {
    print('  - ⚠️ 图标文件不存在: $imagePath，跳过图标生成');
    return;
  }

  final buffer = StringBuffer();
  buffer.writeln('flutter_launcher_icons:');
  buffer.writeln('  android: ${config['android'] ?? true}');
  buffer.writeln('  ios: ${config['ios'] ?? true}');
  buffer.writeln('  image_path: "$imagePath"');
  buffer.writeln('  min_sdk_android: 21');
  buffer.writeln('  remove_alpha_ios: true');
  
  final iconConfigFile = File('flutter_launcher_icons.yaml');
  await iconConfigFile.writeAsString(buffer.toString());
  
  final result = await Process.run(
    'flutter',
    ['pub', 'run', 'flutter_launcher_icons'],
    // Windows does not resolve flutter.bat through Process.run unless the
    // command is launched via the system shell.
    runInShell: Platform.isWindows,
  );
  
  if (result.exitCode == 0) {
    print('  - ✅ 移动端图标生成成功');
  } else {
    print('  - ❌ 移动端图标生成失败:');
    print(result.stdout);
    print(result.stderr);
  }
}

// Helper to update file content
Future<void> _updateFile(
  String path,
  RegExp regex,
  Object replacement, // String or String Function(Match)
  String description, {
  bool isRegexReplace = false,
}) async {
  final file = File(path);
  if (!file.existsSync()) {
    print('  - ⚠️ 未找到文件: $path');
    return;
  }

  try {
    var content = await file.readAsString();
    if (regex.hasMatch(content)) {
      if (isRegexReplace && replacement is String Function(Match)) {
        content = content.replaceAllMapped(regex, replacement);
      } else if (replacement is String) {
        content = content.replaceAll(regex, replacement);
      } else {
        throw ArgumentError.value(
          replacement,
          'replacement',
          'must be a String or String Function(Match)',
        );
      }
      await file.writeAsString(content);
      print('  - ✅ $description 更新成功');
    } else {
      print('  - ⚠️ $description 中未找到匹配项');
    }
  } catch (e) {
    print('  - ❌ $description 更新出错: $e');
  }
}
