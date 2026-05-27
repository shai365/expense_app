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

const int _maxImageDimension = 960;
const int _jpegQuality = 70;

/// Shrinks the image to a sane max long-side and re-encodes as JPEG so the
/// payload over the wire to the backend stays small. Always re-encodes —
/// even when the image is already under the dimension cap — to guarantee
/// the wire format is JPEG at the configured quality. Throws if the bytes
/// can't be decoded (e.g. HEIC), since silently passing the original
/// through would bypass compression entirely.
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
