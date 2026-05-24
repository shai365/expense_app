import 'package:flutter/foundation.dart';

class ApiConfig {
  // -- Backend ---------------------------------------------------------
  // Default targets the Android emulator's host loopback (10.0.2.2).
  // Override per environment:
  //   Android emulator: http://10.0.2.2:8080 (default)
  //   iOS sim / desktop / web: --dart-define=BACKEND_BASE_URL=http://localhost:8080
  //   Physical device on LAN:  --dart-define=BACKEND_BASE_URL=http://<host-LAN-ip>:8080
  //   Cloud Run:               --dart-define=BACKEND_BASE_URL=https://<service>.run.app
  static const String backendBaseUrl = String.fromEnvironment(
    'BACKEND_BASE_URL',
    defaultValue: 'http://10.0.2.2:8080',
  );

  // Mock toggle: only honored in debug builds. Opt in with:
  //   flutter run --dart-define=USE_MOCK_BACKEND=true
  static const bool _mockEnv =
      bool.fromEnvironment('USE_MOCK_BACKEND', defaultValue: false);
  static bool get useMockBackend => kDebugMode && _mockEnv;
}
