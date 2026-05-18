import 'dart:convert';
import 'dart:io';

import 'package:smart_expense_agent/services/gemini_service.dart';

const _compileTimeKey =
    String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');

Future<void> main(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  final useMock = args.contains('--mock');

  final apiKey = _compileTimeKey.isNotEmpty
      ? _compileTimeKey
      : (Platform.environment['GEMINI_API_KEY'] ?? '');

  if (!useMock && apiKey.isEmpty) {
    stderr.writeln(
      'Missing GEMINI_API_KEY. Pass --dart-define=GEMINI_API_KEY=… '
      'or set the env var, or pass --mock for mock data.',
    );
    exit(2);
  }

  final imagePath =
      positional.isNotEmpty ? positional.first : 'test_receipts.jpg';
  final file = File(imagePath);
  if (!file.existsSync()) {
    stderr.writeln('Image not found: $imagePath');
    exit(2);
  }

  final bytes = await file.readAsBytes();
  final mime = _mimeFor(imagePath);

  stdout.writeln('• Image      : $imagePath (${bytes.length} bytes, $mime)');

  if (!useMock) {
    final opt = GeminiService.optimizeForApi(bytes, originalMime: mime);
    if (opt.wasResized) {
      stdout.writeln(
        '• Optimized  : ${opt.finalBytes} bytes (resized + JPEG q80)'
        ' — ${opt.reductionPct.toStringAsFixed(1)}% smaller, mime=${opt.mimeType}',
      );
    } else {
      stdout.writeln(
        '• Optimized  : skipped (≤1024px, sent as-is, mime=${opt.mimeType})',
      );
    }
    stdout.writeln('• Model      : gemini-2.5-flash');
    stdout.writeln('• API ver    : v1');
  } else {
    stdout.writeln('• Mode       : MOCK (no API call)');
  }

  final service = GeminiService(apiKey: apiKey, useMock: useMock);

  try {
    final receipts = await service.analyzeReceipts(
      imageBytes: bytes,
      mimeType: mime,
      companyCode: 'TEST-COMPANY',
    );

    stdout.writeln('\n--- ${receipts.length} receipt(s) ---\n');
    final dump = receipts
        .map((r) => {
              'id': r.id,
              'invoice_number': r.invoiceNumber,
              'date': r.date,
              'business_name': r.businessName,
              'amount': r.amount,
              'vat': r.vat,
              'start_time': r.startTime,
              'end_time': r.endTime,
              'project_name': r.projectName,
              'confidence': r.confidence,
              'bounding_box': r.boundingBox == null
                  ? null
                  : [
                      r.boundingBox!.yMin,
                      r.boundingBox!.xMin,
                      r.boundingBox!.yMax,
                      r.boundingBox!.xMax,
                    ],
            })
        .toList();
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(dump));
  } catch (e, st) {
    stderr.writeln('\nFAILED: $e');
    stderr.writeln(st);
    exit(1);
  }
}

String _mimeFor(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.heic') || lower.endsWith('.heif')) return 'image/heic';
  return 'image/jpeg';
}
