import 'dart:io';

import 'android_mihomo_backend.dart';
import 'desktop_mihomo_backend.dart';
import 'mihomo_backend.dart';

MihomoBackend createMihomoBackend() {
  if (Platform.isAndroid) return AndroidMihomoBackend();
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    return DesktopMihomoBackend();
  }
  return UnsupportedMihomoBackend();
}
