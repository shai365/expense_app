import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/receipt.dart';
import '../models/session.dart';
import 'image_optimizer.dart';
import 'mock_receipts.dart';
import 'receipt_dedup.dart';

class BackendException implements Exception {
  BackendException(this.message, {this.statusCode, this.errorCode});

  final String message;
  final int? statusCode;
  final String? errorCode;

  @override
  String toString() => 'BackendException($errorCode/$statusCode): $message';
}

class BackendService {
  BackendService({
    required this.baseUrl,
    this.useMock = false,
    http.Client? httpClient,
  }) : _client = httpClient ?? http.Client();

  final String baseUrl;
  final bool useMock;
  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 90);

  Uri _uri(String path) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$base$path');
  }

  void close() => _client.close();

  // ------------------------------------------------------------------
  // POST /v1/sessions/exchange
  // ------------------------------------------------------------------
  Future<Session> exchangeSession({
    required String companyCode,
    required String deviceId,
  }) async {
    if (useMock) {
      // Offline demo path: no network call, no real auth. Returns a
      // synthetic session whose token is never actually sent because
      // scan() also short-circuits when useMock is true.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      return Session(
        companyCode: companyCode,
        orgId: '00000000-0000-0000-0000-000000000001',
        userId: '00000000-0000-0000-0000-000000000002',
        token: 'mock-session-token',
        expiresAt: DateTime.now().add(const Duration(days: 7)),
      );
    }

    final http.Response response;
    try {
      response = await _client
          .post(
            _uri('/v1/sessions/exchange'),
            headers: const {'content-type': 'application/json'},
            body: json.encode({
              'company_code': companyCode,
              'device_id': deviceId,
            }),
          )
          .timeout(_timeout);
    } on SocketException catch (e) {
      throw BackendException('Network error: ${e.message}');
    } on HttpException catch (e) {
      throw BackendException('HTTP error: ${e.message}');
    }

    final decoded = _decodeBody(response);

    if (response.statusCode != 200) {
      throw BackendException(
        decoded['message'] as String? ?? 'Session exchange failed',
        statusCode: response.statusCode,
        errorCode: decoded['error'] as String?,
      );
    }

    return Session(
      companyCode: companyCode,
      orgId: decoded['org_id'] as String,
      userId: decoded['user_id'] as String,
      token: decoded['token'] as String,
      expiresAt: DateTime.parse(decoded['expires_at'] as String),
    );
  }

  // ------------------------------------------------------------------
  // POST /v1/scan
  // ------------------------------------------------------------------
  Future<List<Receipt>> scan({
    required Uint8List imageBytes,
    required String mimeType,
    required Session session,
    List<Map<String, String>> projects = const [],
  }) async {
    if (useMock) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      return deduplicateReceipts(mockReceipts());
    }

    final optimized = optimizeForApi(imageBytes, originalMime: mimeType);
    final base64Image = base64Encode(optimized.bytes);

    final http.Response response;
    try {
      response = await _client
          .post(
            _uri('/v1/scan'),
            headers: {
              'content-type': 'application/json',
              'authorization': 'Bearer ${session.token}',
            },
            body: json.encode({
              'company_code': session.companyCode,
              'projects': projects,
              'image': {
                'mime_type': optimized.mimeType,
                'data': base64Image,
              },
            }),
          )
          .timeout(_timeout);
    } on SocketException catch (e) {
      throw BackendException('Network error: ${e.message}');
    } on HttpException catch (e) {
      throw BackendException('HTTP error: ${e.message}');
    }

    final decoded = _decodeBody(response);

    if (response.statusCode != 200) {
      throw BackendException(
        decoded['message'] as String? ?? 'Scan failed',
        statusCode: response.statusCode,
        errorCode: decoded['error'] as String?,
      );
    }

    final rawReceipts = decoded['receipts'];
    if (rawReceipts is! List) {
      throw BackendException(
        'Unexpected scan response: missing receipts array',
      );
    }

    final receipts = <Receipt>[];
    for (var i = 0; i < rawReceipts.length; i++) {
      final entry = rawReceipts[i];
      if (entry is Map<String, dynamic>) {
        receipts.add(Receipt.fromJson(entry, fallbackId: 'r${i + 1}'));
      } else if (entry is Map) {
        receipts.add(
          Receipt.fromJson(
            Map<String, dynamic>.from(entry),
            fallbackId: 'r${i + 1}',
          ),
        );
      }
    }
    return receipts;
  }

  Map<String, dynamic> _decodeBody(http.Response response) {
    if (response.body.isEmpty) return const {};
    try {
      final v = json.decode(response.body);
      if (v is Map<String, dynamic>) return v;
      return {'message': response.body};
    } catch (_) {
      return {'message': response.body};
    }
  }
}
