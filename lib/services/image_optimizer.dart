import 'dart:typed_data';

import 'package:image/image.dart' as img;

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

// Slow-path-only constants. ImagePicker is configured to deliver bytes that
// already meet our wire-format requirements (1200px max, JPEG q88), so the
// decode/resize/encode pipeline below is now a fallback for HEIC inputs or
// unexpectedly oversized files — NOT the primary path. See needsOptimizing
// below; the fast path skips this work entirely. 1200px keeps Hebrew text
// readable for OCR while shrinking the wire payload enough to fit a sub-7s
// single-scan demo target.
const int _maxImageDimension = 1200;
const int _jpegQuality = 88;

// Upper bound for the fast-path: any JPEG <= this stays untouched. At the
// 1200px cap / q88, ImagePicker output typically lands at ~150–300KB; the
// 450KB ceiling still lets detail-heavy receipts through while forcing
// anything oversized down the slow path.
const int _passThroughMaxBytes = 450 * 1024;

/// True when the bytes need to go through the decode→resize→encode pipeline.
/// False means the bytes are already an acceptable JPEG and can be sent to
/// the backend as-is — saving a lossy roundtrip AND an isolate spawn.
bool needsOptimizing(Uint8List bytes, String mime) {
  if (mime != 'image/jpeg') return true;
  if (bytes.length > _passThroughMaxBytes) return true;
  return false;
}

/// Decodes, resizes, and re-encodes the image as JPEG. This is the SLOW path
/// (pure-Dart decode is ~1–2s for a 2MP image on a phone) and exists only
/// for non-JPEG inputs (HEIC) or unexpectedly oversized files. Callers
/// should check needsOptimizing() first and skip this when possible. Throws
/// if the bytes can't be decoded.
OptimizedImage optimizeForApi(
  Uint8List bytes, {
  String originalMime = 'image/jpeg',
}) {
  final totalSw = Stopwatch()..start();
  // ignore: avoid_print
  print(
    '[client-scan optimizer] start: input=${bytes.length}B '
    '(~${(bytes.length / 1024).toStringAsFixed(1)}KB), mime=$originalMime',
  );

  final decodeSw = Stopwatch()..start();
  final decoded = img.decodeImage(bytes);
  decodeSw.stop();
  // ignore: avoid_print
  print(
    '[client-scan optimizer] img.decodeImage: ${decodeSw.elapsedMilliseconds}ms',
  );

  if (decoded == null) {
    throw StateError(
      'optimizeForApi: could not decode image (mime=$originalMime, '
      '${bytes.length} bytes). The image package does not support HEIC — '
      'capture must produce JPEG/PNG.',
    );
  }

  final longSide =
      decoded.width > decoded.height ? decoded.width : decoded.height;
  // ignore: avoid_print
  print(
    '[client-scan optimizer] decoded dims: ${decoded.width}x${decoded.height} '
    '(long side=$longSide, cap=$_maxImageDimension)',
  );

  final img.Image working;
  final bool wasResized;
  if (longSide > _maxImageDimension) {
    final scale = _maxImageDimension / longSide;
    final resizeSw = Stopwatch()..start();
    working = img.copyResize(
      decoded,
      width: (decoded.width * scale).round(),
      height: (decoded.height * scale).round(),
      interpolation: img.Interpolation.linear,
    );
    resizeSw.stop();
    // ignore: avoid_print
    print(
      '[client-scan optimizer] img.copyResize: ${resizeSw.elapsedMilliseconds}ms '
      '-> ${working.width}x${working.height}',
    );
    wasResized = true;
  } else {
    working = decoded;
    wasResized = false;
    // ignore: avoid_print
    print(
      '[client-scan optimizer] img.copyResize: skipped (already <= $_maxImageDimension)',
    );
  }

  final encodeSw = Stopwatch()..start();
  final encoded =
      Uint8List.fromList(img.encodeJpg(working, quality: _jpegQuality));
  encodeSw.stop();
  // ignore: avoid_print
  print(
    '[client-scan optimizer] img.encodeJpg q$_jpegQuality: '
    '${encodeSw.elapsedMilliseconds}ms -> ${encoded.length}B '
    '(~${(encoded.length / 1024).toStringAsFixed(1)}KB)',
  );

  totalSw.stop();
  final reduction = bytes.isEmpty
      ? 0
      : ((1 - encoded.length / bytes.length) * 100);
  // ignore: avoid_print
  print(
    '[client-scan optimizer] TOTAL: ${totalSw.elapsedMilliseconds}ms '
    '(${bytes.length}B -> ${encoded.length}B, ${reduction.toStringAsFixed(1)}% reduction)',
  );

  return OptimizedImage(
    bytes: encoded,
    mimeType: 'image/jpeg',
    originalBytes: bytes.length,
    finalBytes: encoded.length,
    wasResized: wasResized,
  );
}
