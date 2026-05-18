import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../models/receipt.dart';

class ImageCropper {
  static Future<List<Receipt>> attachCrops({
    required Uint8List sourceBytes,
    required List<Receipt> receipts,
  }) async {
    if (receipts.isEmpty) return receipts;
    final crops = await compute(
      _cropAll,
      _CropRequest(sourceBytes, receipts),
    );
    for (final entry in crops.entries) {
      final receipt = receipts.firstWhere((r) => r.id == entry.key);
      receipt.croppedImage = entry.value;
    }
    return receipts;
  }
}

class _CropRequest {
  _CropRequest(this.bytes, this.receipts);
  final Uint8List bytes;
  final List<Receipt> receipts;
}

Map<String, Uint8List> _cropAll(_CropRequest req) {
  final decoded = img.decodeImage(req.bytes);
  if (decoded == null) return const {};

  final width = decoded.width;
  final height = decoded.height;
  final result = <String, Uint8List>{};

  const padFrac = 0.10;

  for (final r in req.receipts) {
    final box = r.boundingBox;
    if (box == null) continue;

    final boxW = (box.xMax - box.xMin) * width;
    final boxH = (box.yMax - box.yMin) * height;
    final padX = (boxW * padFrac).round();
    final padY = (boxH * padFrac).round();

    final x = ((box.xMin * width).round() - padX).clamp(0, width - 1);
    final y = ((box.yMin * height).round() - padY).clamp(0, height - 1);
    final xEnd = ((box.xMax * width).round() + padX).clamp(x + 1, width);
    final yEnd = ((box.yMax * height).round() + padY).clamp(y + 1, height);
    final w = xEnd - x;
    final h = yEnd - y;

    if (w < 16 || h < 16) continue;

    final cropped = img.copyCrop(decoded, x: x, y: y, width: w, height: h);
    result[r.id] = Uint8List.fromList(img.encodeJpg(cropped, quality: 82));
  }

  return result;
}
