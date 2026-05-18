import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class ApiConfig {
  static const String _dartDefineGeminiApiKey =
      String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');

  static String get geminiApiKey {
    if (_dartDefineGeminiApiKey.isNotEmpty) return _dartDefineGeminiApiKey;
    return dotenv.env['GEMINI_API_KEY']?.trim() ?? '';
  }

  static bool get hasGeminiKey => geminiApiKey.isNotEmpty;

  // Mock toggle: only honored in debug builds. Opt in with:
  //   flutter run --dart-define=USE_MOCK_GEMINI=true
  static const bool _mockEnv =
      bool.fromEnvironment('USE_MOCK_GEMINI', defaultValue: false);
  static bool get useMockGemini => kDebugMode && _mockEnv;
}
