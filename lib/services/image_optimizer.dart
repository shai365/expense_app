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

const int _maxImageDimension = 1024;
const int _jpegQuality = 80;

/// Shrinks the image to a sane max long-side and re-encodes as JPEG so the
/// payload over the wire to the backend stays small. Falls back to the
/// original bytes when the image is already small enough or can't be decoded.
OptimizedImage optimizeForApi(
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
