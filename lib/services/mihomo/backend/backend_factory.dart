import 'backend_factory_stub.dart'
    if (dart.library.io) 'backend_factory_io.dart' as implementation;
import 'mihomo_backend.dart';

MihomoBackend createMihomoBackend() => implementation.createMihomoBackend();
