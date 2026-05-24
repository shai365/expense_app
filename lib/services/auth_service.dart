import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/session.dart';

class AuthService {
  static const String _sessionKey = 'session_v1';
  static const String _deviceIdKey = 'device_id_v1';

  Future<Session?> getSession() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_sessionKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = json.decode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final session = Session.fromJson(decoded);
      if (session.isExpired) {
        await prefs.remove(_sessionKey);
        return null;
      }
      return session;
    } catch (_) {
      // Corrupt blob — drop it so the user can re-login cleanly.
      await prefs.remove(_sessionKey);
      return null;
    }
  }

  Future<void> saveSession(Session session) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sessionKey, json.encode(session.toJson()));
  }

  Future<void> signOut() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sessionKey);
    // Keep _deviceIdKey: the device identity is stable across logins.
  }

  /// Stable per-install identifier. Generated once and persisted so the
  /// backend can correlate sessions to a device for audit / rate-limit.
  Future<String> getOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_deviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final fresh = _randomDeviceId();
    await prefs.setString(_deviceIdKey, fresh);
    return fresh;
  }

  static String _randomDeviceId() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    final hex = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return 'dev-$hex';
  }
}
