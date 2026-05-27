import 'package:flutter/foundation.dart';

class ApiConfig {
  // -- Backend ---------------------------------------------------------
  // Default targets the live Render production backend so `flutter run`
  // on a physical device works out of the box. Override per environment:
  //   Android emulator → host:   --dart-define=BACKEND_BASE_URL=http://10.0.2.2:8080
  //   iOS sim / desktop / web:   --dart-define=BACKEND_BASE_URL=http://localhost:8080
  //   Physical device on LAN:    --dart-define=BACKEND_BASE_URL=http://<host-LAN-ip>:8080
  //   Render (default):          https://smart-expense-agent.onrender.com
  static const String backendBaseUrl = String.fromEnvironment(
    'BACKEND_BASE_URL',
    defaultValue: 'https://smart-expense-agent.onrender.com',
  );

  // Mock toggle: only honored in debug builds. Opt in with:
  //   flutter run --dart-define=USE_MOCK_BACKEND=true
  static const bool _mockEnv =
      bool.fromEnvironment('USE_MOCK_BACKEND', defaultValue: false);
  static bool get useMockBackend => kDebugMode && _mockEnv;
}
