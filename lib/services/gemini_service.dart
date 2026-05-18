import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:image/image.dart' as img;

import '../models/receipt.dart';

class GeminiException implements Exception {
  GeminiException(this.message);
  final String message;
  @override
  String toString() => 'GeminiException: $message';
}

class GeminiService {
  factory GeminiService({
    String? apiKey,
    String model = 'gemini-2.5-flash',
    bool useMock = false,
  }) {
    final resolvedApiKey = (apiKey?.trim().isNotEmpty ?? false)
        ? apiKey!.trim()
        : dotenv.env['GEMINI_API_KEY']?.trim();
    final loaded = resolvedApiKey != null && resolvedApiKey.isNotEmpty;
    if (!loaded) {
      throw GeminiException('GEMINI_API_KEY is not configured.');
    }

    final modelClient = GenerativeModel(
      model: model,
      apiKey: resolvedApiKey,
      generationConfig: GenerationConfig(
        temperature: 0.2,
      ),
      requestOptions: const RequestOptions(apiVersion: 'v1'),
    );

    return GeminiService._internal(
      apiKey: resolvedApiKey,
      useMock: useMock,
      model: modelClient,
    );
  }

  GeminiService._internal({
    required this.apiKey,
    required this.useMock,
    required GenerativeModel model,
  }) : _model = model;

  final String apiKey;
  final bool useMock;
  final GenerativeModel _model;

  static const int _maxImageDimension = 1024;
  static const int _jpegQuality = 80;

  static const _systemPrompt = '''
Role: Financial OCR Agent for Israeli receipts.
Input: A single image that may contain one or many receipts.
Context: A list of company projects (name + address) and a Company Code.

Instructions:
1. Detect every distinct receipt boundary in the image. Bulk shots may contain up to ~20 receipts; identify each one separately even when they overlap.
2. For each receipt, return a tight bounding box that frames only that receipt.
   - Coordinates: [ymin, xmin, ymax, xmax] normalized to 0-1000 (top-left origin).
3. Extract for each receipt — invoice_number is the HIGHEST PRIORITY field, treat it as the primary key:
   - invoice_number (PRIMARY KEY): the receipt/invoice identifier. Hebrew labels: "מספר חשבונית", "מס' חשבונית", "מס' קבלה", "חשבונית מס'". Also accept "Invoice #", "Receipt #", "מסמך מספר". Return the raw alphanumeric value with no prefix label. Set null only if truly absent on the printed receipt.
   - date (YYYY-MM-DD if possible)
   - business_name
   - amount (FINAL "Total to Pay" — see Totals rules below)
   - vat (Israeli מע"מ — see VAT rules below)
   - start_time and end_time (HH:MM, ONLY for parking receipts — entry/exit times. Null for all other categories.)
4. Totals rules (CRITICAL for Hebrew supermarket receipts — Carrefour, City Market, Shufersal, Rami Levy, Victory, etc.):
   a. The "amount" field must be the FINAL amount the customer paid AFTER all discounts. Look for the LAST total printed on the receipt — common Hebrew labels include "סה"כ לתשלום", "לתשלום", "סך הכל לתשלום", "סהכ לתשלום", "סך לתשלום".
   b. Do NOT confuse this with "Total before discounts" — Hebrew labels like "סה"כ לפני הנחה", "סכום ביניים", "סה"כ לפני הנחות", "סך הכל לפני הנחה". These are intermediate totals; ignore them for the amount field.
   c. If you see TWO totals, the LOWER one (after discounts) is the correct "amount".
5. VAT rules (Israeli מע"מ):
   a. If the receipt explicitly prints a VAT line (look for the Hebrew label מע"מ, the spelled form מעמ, the English VAT, or "מס ערך מוסף"), return that exact decimal number.
   b. If VAT is NOT explicitly printed AND the business is one that typically includes VAT in the displayed total (retail, restaurants, gas stations, parking, transportation, hotels, most service shops), CALCULATE the VAT portion as: vat = round(amount / 1.17 * 0.17, 2). Return this calculated value.
   c. Only return null when amount is unknown OR the business is clearly VAT-exempt (e.g. private receipts, tips, donations, foreign vendors).
6. CATEGORY — classify each receipt into EXACTLY ONE of these six values (return the Hebrew string exactly):
   - "הוצאות חניה" — parking lots, parking meters, "חניון", "חניה"
   - "הוצאות רכב" — fuel/gas stations, car wash, EV charging, car repairs, tires, oil change, car insurance
   - "תחבורה ציבורית" — taxi (מונית, גט, יאנגו), bus, train (רכבת ישראל), light rail, ride sharing
   - "מזון ואירוח" — restaurants, cafes, bars, supermarkets, food delivery, hotels, catering, fast food
   - "תוכנה ותקשורת" — technology and AI service providers, SaaS, cloud, software subscriptions, hosting, domain registrars, telecom/phone/internet bills. When the business_name matches a recognizable tech or AI vendor (e.g. Google, Anthropic, Claude, OpenAI, ChatGPT, AWS, Amazon Web Services, Microsoft, Azure, Adobe, GitHub, GitLab, Cloudflare, Vercel, Netlify, JetBrains, Atlassian, Slack, Zoom, Notion, Figma, Dropbox, Apple iCloud, Bezeq, HOT, Cellcom, Partner, Pelephone), classify as "תוכנה ותקשורת" regardless of any food/parking/transport interpretation.
   - "אחר" — DEFAULT FALLBACK. Use this whenever the receipt does not clearly fit any of the five categories above.
7. ITEMS — extract EVERY line item printed on the receipt:
   - DO NOT aggregate or deduplicate. If "חלב 3%" appears twice on two separate rows, return it twice as two separate item objects. Preserve printed order.
   - Each item object: { "code": string|null, "description": string|null, "quantity": number|null, "price": number|null }
     - code: product/PLU/SKU code if printed (often a 7–13 digit barcode column next to the item). Null if absent.
     - description: the item's printed name in its original language (Hebrew if Hebrew).
     - quantity: numeric quantity (default 1 when unspecified but the line is clearly a purchased item).
     - price: the LINE TOTAL for that row in the receipt's currency (quantity × unit price), as a positive number for purchases.
   - DISCOUNTS: receipts often print discount lines like "הנחה", "מבצע", "הנחת חבר", "הנחת מועדון", "הטבת קופון" with negative amounts. Represent them either as:
       a) a separate line item with description = the discount label and price = the negative amount (preferred when the discount applies to multiple items), OR
       b) by reducing the price of the specific item the discount applies to (when the discount is clearly tied to a single preceding line).
   - For pure non-supermarket receipts (parking, fuel, taxi) with no itemized breakdown, return an empty items array [].
8. Map to project_name using the provided Project List by address proximity / business name. If your confidence in the project mapping is below 85%, set project_name to null.
9. Always return a confidence value between 0.0 and 1.0 reflecting your overall extraction confidence for that receipt.
10. If no receipts are detected, return an empty array.

Output format (CRITICAL):
Return ONLY a raw JSON array. No prose, no explanation, no markdown code fences (no ```), no leading or trailing text. The very first character of your response must be `[` and the very last character must be `]`.

Each element of the array must be an object with this exact shape:
{
  "bounding_box": [ymin, xmin, ymax, xmax],
  "invoice_number": string|null,
  "date": string|null,
  "business_name": string|null,
  "amount": number|null,
  "vat": number|null,
  "start_time": string|null,
  "end_time": string|null,
  "project_name": string|null,
  "category": "הוצאות חניה" | "הוצאות רכב" | "תחבורה ציבורית" | "מזון ואירוח" | "תוכנה ותקשורת" | "אחר",
  "items": [
    { "code": string|null, "description": string|null, "quantity": number|null, "price": number|null }
  ],
  "confidence": number
}

If no receipts are found, return exactly: []
''';

  Future<List<Receipt>> analyzeReceipts({
    required Uint8List imageBytes,
    required String mimeType,
    required String companyCode,
    List<Map<String, String>> projects = const [],
  }) async {
    if (useMock) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      return deduplicate(mockReceipts());
    }

    final optimized = optimizeForApi(imageBytes, originalMime: mimeType);

    final projectsBlock = projects.isEmpty
        ? '(none on file yet)'
        : projects
            .map((p) => '- ${p['name']} @ ${p['address'] ?? ''}')
            .join('\n');

    final userText = '''
Company Code: $companyCode
Project List:
$projectsBlock

Analyse the attached image and return the JSON array described in your instructions.
''';

    final response = await _model.generateContent([
      Content.text(_systemPrompt),
      Content.multi([
        TextPart(userText),
        DataPart(optimized.mimeType, optimized.bytes),
      ]),
    ]);

    final text = response.text;
    if (text == null || text.trim().isEmpty) {
      throw GeminiException('Empty response from model.');
    }

    return deduplicate(_parseReceipts(text));
  }

  static OptimizedImage optimizeForApi(
    Uint8List bytes, {
    String originalMime = 'image/jpeg',
  }) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return OptimizedImage(
        bytes: bytes,
        mimeType: originalMime,
        originalBytes: bytes.length,
        finalBytes: bytes.length,
        wasResized: false,
      );
    }

    final longSide =
        decoded.width > decoded.height ? decoded.width : decoded.height;

    if (longSide <= _maxImageDimension) {
      return OptimizedImage(
        bytes: bytes,
        mimeType: originalMime,
        originalBytes: bytes.length,
        finalBytes: bytes.length,
        wasResized: false,
      );
    }

    final scale = _maxImageDimension / longSide;
    final resized = img.copyResize(
      decoded,
      width: (decoded.width * scale).round(),
      height: (decoded.height * scale).round(),
      interpolation: img.Interpolation.linear,
    );
    final encoded =
        Uint8List.fromList(img.encodeJpg(resized, quality: _jpegQuality));

    return OptimizedImage(
      bytes: encoded,
      mimeType: 'image/jpeg',
      originalBytes: bytes.length,
      finalBytes: encoded.length,
      wasResized: true,
    );
  }

  static List<Receipt> mockReceipts() {
    return [
      Receipt(
        id: 'r1',
        invoiceNumber: 'INV-1042',
        date: '2026-05-08',
        businessName: 'דלק תחנת תל אביב',
        amount: 234.50,
        vat: 34.05,
        startTime: null,
        endTime: null,
        projectName: null,
        category: ReceiptCategory.vehicle,
        items: const [],
        confidence: 0.97,
        boundingBox: const BoundingBox(
          yMin: 0.02,
          xMin: 0.02,
          yMax: 0.32,
          xMax: 0.48,
        ),
      ),
      Receipt(
        id: 'r2',
        invoiceNumber: '94732',
        date: '2026-05-07',
        businessName: 'חניון עזריאלי',
        amount: 45.0,
        vat: 6.54,
        startTime: '09:30',
        endTime: '13:15',
        projectName: null,
        category: ReceiptCategory.parking,
        items: const [],
        confidence: 0.92,
        boundingBox: const BoundingBox(
          yMin: 0.02,
          xMin: 0.52,
          yMax: 0.32,
          xMax: 0.98,
        ),
      ),
      Receipt(
        id: 'r3',
        invoiceNumber: 'A-77821',
        date: '2026-05-06',
        businessName: 'קפה לנדוור',
        amount: 89.0,
        vat: null,
        startTime: null,
        endTime: null,
        projectName: null,
        category: ReceiptCategory.foodHospitality,
        items: const [
          ReceiptItem(
            code: null,
            description: 'קפה הפוך גדול',
            quantity: 2,
            price: 32,
          ),
          ReceiptItem(
            code: null,
            description: 'כריך גבינה',
            quantity: 1,
            price: 25,
          ),
        ],
        confidence: 0.78,
        boundingBox: const BoundingBox(
          yMin: 0.36,
          xMin: 0.02,
          yMax: 0.66,
          xMax: 0.48,
        ),
      ),
      Receipt(
        id: 'r4',
        invoiceNumber: '7700123',
        date: '2026-05-05',
        businessName: 'קרפור סניף רמת גן',
        amount: 312.40,
        vat: 45.40,
        startTime: null,
        endTime: null,
        projectName: null,
        category: ReceiptCategory.foodHospitality,
        items: const [
          ReceiptItem(
            code: '7290000000017',
            description: 'חלב תנובה 3% 1 ליטר',
            quantity: 1,
            price: 6.90,
          ),
          ReceiptItem(
            code: '7290000000017',
            description: 'חלב תנובה 3% 1 ליטר',
            quantity: 1,
            price: 6.90,
          ),
          ReceiptItem(
            code: '7290008580013',
            description: 'לחם אחיד פרוס',
            quantity: 2,
            price: 13.80,
          ),
          ReceiptItem(
            code: null,
            description: 'הנחת מועדון',
            quantity: 1,
            price: -4.20,
          ),
        ],
        confidence: 0.88,
        boundingBox: const BoundingBox(
          yMin: 0.36,
          xMin: 0.52,
          yMax: 0.66,
          xMax: 0.98,
        ),
      ),
      Receipt(
        id: 'r5',
        invoiceNumber: 'GC-2026-04-9931',
        date: '2026-05-04',
        businessName: 'Google Cloud',
        amount: 287.43,
        vat: 41.76,
        startTime: null,
        endTime: null,
        projectName: null,
        category: ReceiptCategory.softwareCommunications,
        items: const [
          ReceiptItem(
            code: null,
            description: 'Compute Engine — n2-standard-4',
            quantity: 1,
            price: 198.20,
          ),
          ReceiptItem(
            code: null,
            description: 'Cloud Storage egress',
            quantity: 1,
            price: 47.45,
          ),
          ReceiptItem(
            code: null,
            description: 'Gemini API usage',
            quantity: 1,
            price: 41.78,
          ),
        ],
        confidence: 0.95,
        boundingBox: const BoundingBox(
          yMin: 0.70,
          xMin: 0.02,
          yMax: 0.98,
          xMax: 0.48,
        ),
      ),
      Receipt(
        id: 'r6',
        invoiceNumber: '20260501-7700',
        date: '2026-05-01',
        businessName: 'בזק - חברת התקשורת',
        amount: 156.90,
        vat: 22.80,
        startTime: null,
        endTime: null,
        projectName: null,
        category: ReceiptCategory.softwareCommunications,
        items: const [],
        confidence: 0.91,
        boundingBox: const BoundingBox(
          yMin: 0.70,
          xMin: 0.52,
          yMax: 0.98,
          xMax: 0.98,
        ),
      ),
    ];
  }

  List<Receipt> deduplicate(List<Receipt> receipts) {
    final kept = <Receipt>[];

    for (final candidate in receipts) {
      final candidateInv = _normInvoice(candidate.invoiceNumber);
      var duplicateAt = -1;

      for (var i = 0; i < kept.length; i++) {
        final existing = kept[i];
        final existingInv = _normInvoice(existing.invoiceNumber);

        // Primary: same invoice number (case-insensitive, trimmed).
        if (candidateInv != null && existingInv == candidateInv) {
          duplicateAt = i;
          break;
        }

        // Fallback: invoice number missing on BOTH sides — match on
        // business_name + date + amount when all three are present and equal.
        if (candidateInv == null && existingInv == null) {
          if (_textsEqual(candidate.businessName, existing.businessName) &&
              _textsEqual(candidate.date, existing.date) &&
              _amountsEqual(candidate.amount, existing.amount)) {
            duplicateAt = i;
            break;
          }
        }
      }

      if (duplicateAt == -1) {
        kept.add(candidate);
      } else {
        final existing = kept[duplicateAt];
        final winner = _pickWinner(candidate, existing);
        final loser = identical(winner, candidate) ? existing : candidate;
        kept[duplicateAt] = _mergeFields(winner, loser);
      }
    }

    return kept;
  }

  // Confidence wins. When confidences are within 0.05, the receipt with more
  // populated fields wins — "most complete data" tiebreak for cross-image
  // duplicates where one source captured a partial copy of the same receipt.
  Receipt _pickWinner(Receipt a, Receipt b) {
    final diff = (a.confidence - b.confidence).abs();
    if (diff < 0.05) {
      final aScore = _completenessScore(a);
      final bScore = _completenessScore(b);
      if (aScore != bScore) return aScore > bScore ? a : b;
    }
    return a.confidence >= b.confidence ? a : b;
  }

  int _completenessScore(Receipt r) {
    var score = 0;
    if (r.invoiceNumber != null) score++;
    if (r.date != null) score++;
    if (r.businessName != null) score++;
    if (r.amount != null) score++;
    if (r.vat != null) score++;
    if (r.projectName != null) score++;
    if (r.category != ReceiptCategory.other) score++;
    score += r.items.length;
    return score;
  }

  Receipt _mergeFields(Receipt winner, Receipt loser) {
    return Receipt(
      id: winner.id,
      invoiceNumber: winner.invoiceNumber ?? loser.invoiceNumber,
      date: winner.date ?? loser.date,
      businessName: winner.businessName ?? loser.businessName,
      amount: winner.amount ?? loser.amount,
      vat: winner.vat ?? loser.vat,
      startTime: winner.startTime ?? loser.startTime,
      endTime: winner.endTime ?? loser.endTime,
      projectName: winner.projectName ?? loser.projectName,
      category: winner.category == ReceiptCategory.other
          ? loser.category
          : winner.category,
      items: winner.items.length >= loser.items.length
          ? winner.items
          : loser.items,
      confidence: winner.confidence >= loser.confidence
          ? winner.confidence
          : loser.confidence,
      boundingBox: winner.boundingBox ?? loser.boundingBox,
      croppedImage: winner.croppedImage ?? loser.croppedImage,
    );
  }

  String? _normInvoice(String? raw) {
    if (raw == null) return null;
    final t = raw.trim().toLowerCase();
    return t.isEmpty ? null : t;
  }

  bool _textsEqual(String? a, String? b) {
    if (a == null || b == null) return false;
    return a.trim().toLowerCase() == b.trim().toLowerCase();
  }

  bool _amountsEqual(double? a, double? b) {
    if (a == null || b == null) return false;
    return (a - b).abs() < 0.005;
  }

  List<Receipt> _parseReceipts(String raw) {
    final cleaned = _extractJson(raw);
    final dynamic decoded;
    try {
      decoded = json.decode(cleaned);
    } on FormatException catch (e) {
      throw GeminiException(
        'Could not parse model output as JSON: ${e.message}',
      );
    }

    final List list;
    if (decoded is List) {
      list = decoded;
    } else if (decoded is Map && decoded['receipts'] is List) {
      list = decoded['receipts'] as List;
    } else {
      throw GeminiException('Unexpected response shape: ${decoded.runtimeType}');
    }

    final receipts = <Receipt>[];
    for (var i = 0; i < list.length; i++) {
      final item = list[i];
      if (item is Map<String, dynamic>) {
        receipts.add(Receipt.fromJson(item, id: 'r${i + 1}'));
      } else if (item is Map) {
        receipts.add(
          Receipt.fromJson(Map<String, dynamic>.from(item), id: 'r${i + 1}'),
        );
      }
    }
    return receipts;
  }

  String _extractJson(String raw) {
    var t = raw.trim();
    if (t.startsWith('```')) {
      final firstNewline = t.indexOf('\n');
      if (firstNewline != -1) t = t.substring(firstNewline + 1);
      if (t.endsWith('```')) t = t.substring(0, t.length - 3);
      t = t.trim();
    }
    if (t.startsWith('[') && t.endsWith(']')) return t;
    if (t.startsWith('{') && t.endsWith('}')) return t;

    final firstBracket = t.indexOf('[');
    final lastBracket = t.lastIndexOf(']');
    if (firstBracket != -1 && lastBracket > firstBracket) {
      return t.substring(firstBracket, lastBracket + 1);
    }
    final firstBrace = t.indexOf('{');
    final lastBrace = t.lastIndexOf('}');
    if (firstBrace != -1 && lastBrace > firstBrace) {
      return t.substring(firstBrace, lastBrace + 1);
    }
    return t;
  }
}

class OptimizedImage {
  const OptimizedImage({
    required this.bytes,
    required this.mimeType,
    required this.originalBytes,
    required this.finalBytes,
    required this.wasResized,
  });

  final Uint8List bytes;
  final String mimeType;
  final int originalBytes;
  final int finalBytes;
  final bool wasResized;

  double get reductionPct =>
      originalBytes == 0 ? 0 : (1 - finalBytes / originalBytes) * 100;
}
