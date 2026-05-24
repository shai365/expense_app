import 'dart:typed_data';

class BoundingBox {
  const BoundingBox({
    required this.yMin,
    required this.xMin,
    required this.yMax,
    required this.xMax,
  });

  final double yMin;
  final double xMin;
  final double yMax;
  final double xMax;

  static BoundingBox? tryFromJson(dynamic value) {
    if (value is! List || value.length < 4) return null;
    final nums = value.map(_toDouble).toList();
    if (nums.any((v) => v == null)) return null;
    return BoundingBox(
      yMin: nums[0]!,
      xMin: nums[1]!,
      yMax: nums[2]!,
      xMax: nums[3]!,
    ).normalized();
  }

  BoundingBox normalized() {
    final maxValue = [yMin, xMin, yMax, xMax]
        .map((v) => v.abs())
        .fold<double>(0, (a, b) => a > b ? a : b);
    final scale = maxValue > 1 ? 1000.0 : 1.0;
    return BoundingBox(
      yMin: (yMin / scale).clamp(0.0, 1.0),
      xMin: (xMin / scale).clamp(0.0, 1.0),
      yMax: (yMax / scale).clamp(0.0, 1.0),
      xMax: (xMax / scale).clamp(0.0, 1.0),
    );
  }
}

class ReceiptCategory {
  static const String parking = 'הוצאות חניה';
  static const String vehicle = 'הוצאות רכב';
  static const String publicTransport = 'תחבורה ציבורית';
  static const String foodHospitality = 'מזון ואירוח';
  static const String softwareCommunications = 'תוכנה ותקשורת';
  static const String other = 'אחר';

  static const List<String> all = [
    parking,
    vehicle,
    publicTransport,
    foodHospitality,
    softwareCommunications,
    other,
  ];

  static String normalize(String? value) {
    if (value == null) return other;
    final trimmed = value.trim();
    if (all.contains(trimmed)) return trimmed;
    return other;
  }
}

class ReceiptItem {
  const ReceiptItem({
    this.code,
    this.description,
    this.quantity,
    this.price,
  });

  final String? code;
  final String? description;
  final num? quantity;
  final num? price;

  factory ReceiptItem.fromJson(Map<String, dynamic> json) {
    return ReceiptItem(
      code: _toString(json['code']),
      description: _toString(json['description']),
      quantity: _toNum(json['quantity']),
      price: _toNum(json['price']),
    );
  }
}

class Receipt {
  Receipt({
    required this.id,
    this.invoiceNumber,
    this.date,
    this.businessName,
    this.amount,
    this.vat,
    this.startTime,
    this.endTime,
    this.projectName,
    required this.category,
    this.items = const [],
    required this.confidence,
    this.boundingBox,
    this.croppedImage,
    this.duplicate = false,
  });

  final String id;
  final String? invoiceNumber;
  final String? date;
  final String? businessName;
  final double? amount;
  final double? vat;
  final String? startTime;
  final String? endTime;
  final String? projectName;
  final String category;
  final List<ReceiptItem> items;
  final double confidence;
  final BoundingBox? boundingBox;
  Uint8List? croppedImage;

  /// True when the backend recognised this receipt as already persisted
  /// (matched on invoice_number for the same org).
  final bool duplicate;

  bool get isParking => category == ReceiptCategory.parking;

  Receipt copyWith({
    String? category,
    List<ReceiptItem>? items,
  }) {
    return Receipt(
      id: id,
      invoiceNumber: invoiceNumber,
      date: date,
      businessName: businessName,
      amount: amount,
      vat: vat,
      startTime: startTime,
      endTime: endTime,
      projectName: projectName,
      category: category ?? this.category,
      items: items ?? this.items,
      confidence: confidence,
      boundingBox: boundingBox,
      duplicate: duplicate,
    )..croppedImage = croppedImage;
  }

  /// Build from JSON. The optional [fallbackId] is used when the payload
  /// doesn't carry an 'id' field — e.g. when parsing a raw Gemini response
  /// during the legacy direct-call path. Backend responses always include
  /// the persisted receipt UUID.
  factory Receipt.fromJson(Map<String, dynamic> json, {String? fallbackId}) {
    final rawItems = json['items'];
    final items = <ReceiptItem>[];
    if (rawItems is List) {
      for (final entry in rawItems) {
        if (entry is Map<String, dynamic>) {
          items.add(ReceiptItem.fromJson(entry));
        } else if (entry is Map) {
          items.add(ReceiptItem.fromJson(Map<String, dynamic>.from(entry)));
        }
      }
    }

    final id = _toString(json['id']) ?? fallbackId;
    if (id == null) {
      throw ArgumentError('Receipt.fromJson: neither id nor fallbackId provided');
    }

    return Receipt(
      id: id,
      invoiceNumber: _toString(json['invoice_number']),
      date: _toString(json['date']),
      businessName: _toString(json['business_name']),
      amount: _toDouble(json['amount']),
      vat: _toDouble(json['vat']),
      startTime: _toString(json['start_time']),
      endTime: _toString(json['end_time']),
      projectName: _toString(json['project_name']),
      category: ReceiptCategory.normalize(_toString(json['category'])),
      items: items,
      confidence: _toDouble(json['confidence']) ?? 0,
      boundingBox: BoundingBox.tryFromJson(json['bounding_box']),
      duplicate: json['duplicate'] == true,
    );
  }
}

double? _toDouble(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  if (value is String) {
    final cleaned = value.replaceAll(RegExp(r'[^0-9.\-]'), '');
    return double.tryParse(cleaned);
  }
  return null;
}

num? _toNum(dynamic value) {
  if (value == null) return null;
  if (value is num) return value;
  if (value is String) {
    final cleaned = value.replaceAll(RegExp(r'[^0-9.\-]'), '');
    return num.tryParse(cleaned);
  }
  return null;
}

String? _toString(dynamic value) {
  if (value == null) return null;
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.toLowerCase() == 'null') return null;
    return trimmed;
  }
  return value.toString();
}
