import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../config/api_config.dart';
import '../services/auth_service.dart';
import '../services/backend_service.dart';
import '../services/image_cropper.dart';
import '../services/image_optimizer.dart';
import '../services/receipt_dedup.dart';
import '../theme/app_theme.dart';
import 'login_screen.dart';
import 'results_screen.dart';

// Max simultaneous /v1/scan requests in flight. Bumped from 3→5 alongside
// the 2048→1200 image cap: smaller payloads (~150–300KB at 1200px/q88) mean
// less per-request CPU pressure on Render's single vCPU, so we can run more
// requests in parallel without choking the JSON parse step.
const int _maxConcurrentScans = 5;

class _ScanPool {
  _ScanPool(this.max);
  final int max;
  int _inFlight = 0;
  final _waiting = <Completer<void>>[];

  Future<T> run<T>(Future<T> Function() task) async {
    if (_inFlight >= max) {
      final c = Completer<void>();
      _waiting.add(c);
      await c.future;
    }
    _inFlight++;
    try {
      return await task();
    } finally {
      _inFlight--;
      if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
    }
  }
}

class _CompressJob {
  const _CompressJob(this.bytes, this.mime);
  final Uint8List bytes;
  final String mime;
}

// Top-level (free) function — must live outside any class so `compute`
// can ship it to the worker isolate without dragging in an enclosing
// `this`.
Uint8List _compressJpegInIsolate(_CompressJob job) {
  return optimizeForApi(job.bytes, originalMime: job.mime).bytes;
}

class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key, required this.companyCode});

  final String companyCode;

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  static const int _maxGalleryImages = 10;

  final _picker = ImagePicker();
  bool _busy = false;
  String? _statusMessage;

  Future<void> _capture(ImageSource source) async {
    if (_busy) return;
    final useMock = ApiConfig.useMockBackend;

    final auth = AuthService();
    final session = await auth.getSession();
    if (!useMock && session == null) {
      if (!mounted) return;
      // Session expired or missing — bounce back to login.
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
      return;
    }

    final List<XFile> files;
    try {
      files = await _pickFiles(source);
    } catch (e) {
      _showError('Could not open image: $e');
      return;
    }
    if (files.isEmpty) return;

    setState(() {
      _busy = true;
      _statusMessage = useMock
          ? 'Loading mock receipts…'
          : (files.length == 1
              ? 'Sending receipt to the server…'
              : 'Processing 0 of ${files.length} images…');
    });

    final backend = BackendService(
      baseUrl: ApiConfig.backendBaseUrl,
      useMock: useMock,
    );

    try {
      // ----- Phase 1: read + compress all images in parallel on worker
      // isolates. File reads are cheap async I/O; compression (decode →
      // resize → re-encode JPEG) is CPU-heavy and used to run on the UI
      // isolate, which stalled the main thread for ~N × 300ms when the
      // gallery picked N images. Isolate.run lets the OS schedule the
      // work across cores.
      if (mounted && files.length > 1) {
        setState(() {
          _statusMessage = 'Compressing ${files.length} images…';
        });
      }
      final phase1Sw = Stopwatch()..start();
      final prepared = await Future.wait(files.map((file) async {
        final original = await file.readAsBytes();
        final mime = _mimeFor(file.name);
        // Fast path: ImagePicker already delivered an acceptable JPEG, so
        // we ship the same bytes unchanged — no isolate spawn, no second
        // lossy roundtrip, no text-edge smear. The slow path (compute +
        // pure-Dart decode/resize/encode) only runs for HEIC inputs or
        // oversized files. compute() uses a top-level function (NOT an
        // inline closure) so `this` can't leak into the worker isolate.
        final Uint8List jpeg;
        if (needsOptimizing(original, mime)) {
          jpeg = await compute(
            _compressJpegInIsolate,
            _CompressJob(original, mime),
          );
        } else {
          jpeg = original;
        }
        return _PreparedImage(original: original, jpeg: jpeg);
      }));
      phase1Sw.stop();
      // ignore: avoid_print
      print(
        '[capture] phase1 read+compress ${files.length} images: '
        '${phase1Sw.elapsedMilliseconds}ms',
      );

      // ----- Phase 2: send to backend with bounded concurrency. Crops
      // happen per-result and already run on a worker isolate via
      // ImageCropper.attachCrops (compute()), so they don't block UI.
      final pool = _ScanPool(_maxConcurrentScans);
      var completed = 0;
      if (mounted && files.length > 1) {
        setState(() {
          _statusMessage = 'Processing 0 of ${files.length} images…';
        });
      }
      final phase2Sw = Stopwatch()..start();
      final perImage = await Future.wait(
        List.generate(files.length, (i) async {
          final p = prepared[i];
          final receipts = await pool.run(
            () => backend.scan(jpegBytes: p.jpeg, session: session!),
          );
          await ImageCropper.attachCrops(
            sourceBytes: p.original,
            receipts: receipts,
          );
          completed++;
          if (mounted && files.length > 1) {
            setState(() {
              _statusMessage =
                  'Processing $completed of ${files.length} images…';
            });
          }
          return receipts;
        }),
      );
      phase2Sw.stop();
      // ignore: avoid_print
      print(
        '[capture] phase2 scan+crop ${files.length} images '
        '(pool=$_maxConcurrentScans): ${phase2Sw.elapsedMilliseconds}ms',
      );

      final merged =
          deduplicateReceipts(perImage.expand((r) => r).toList());

      if (!mounted) return;

      if (merged.isEmpty) {
        setState(() {
          _busy = false;
          _statusMessage = null;
        });
        _showError(
          'No receipts detected. Try again with better lighting or different images.',
        );
        return;
      }

      setState(() {
        _busy = false;
        _statusMessage = null;
      });

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ResultsScreen(receipts: merged),
        ),
      );
    } on BackendException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _statusMessage = null;
      });
      // Token rejected → push the user to login.
      if (e.errorCode == 'expired' ||
          e.errorCode == 'invalid' ||
          e.errorCode == 'missing_token' ||
          e.statusCode == 401) {
        await auth.signOut();
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
        );
        return;
      }
      _showError('Scan failed: ${e.message}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _statusMessage = null;
      });
      _showError('Scan failed: $e');
    } finally {
      backend.close();
    }
  }

  Future<List<XFile>> _pickFiles(ImageSource source) async {
    // Picker config delivers final wire dimensions directly using the
    // platform's hardware-accelerated resize (CoreGraphics/BitmapFactory).
    // Bounding BOTH dimensions at 2048 means portrait shots also land
    // ≤2048 on their long side, so the optimizer's fast path can pass
    // bytes straight through without a second decode/resize/encode.
    if (source == ImageSource.camera) {
      final picked = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1200,
        maxHeight: 1200,
        imageQuality: 88,
      );
      return picked == null ? const [] : [picked];
    }

    // Gallery: allow multi-select, hard-capped at _maxGalleryImages.
    final picked = await _picker.pickMultiImage(
      maxWidth: 1200,
      maxHeight: 1200,
      imageQuality: 88,
      limit: _maxGalleryImages,
    );
    if (picked.isEmpty) return const [];
    if (picked.length > _maxGalleryImages) {
      _showInfo(
        'You selected ${picked.length} images — only the first '
        '$_maxGalleryImages will be processed.',
      );
      return picked.sublist(0, _maxGalleryImages);
    }
    return picked;
  }

  String _mimeFor(String filename) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.heic') || lower.endsWith('.heif')) return 'image/heic';
    return 'image/jpeg';
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppTheme.error,
      ),
    );
  }

  void _showInfo(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan receipts'),
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
      ),
      body: AbsorbPointer(
        absorbing: _busy,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              const Text(
                'Capture one receipt or a tray of up to ~20 in a single photo. '
                'From your gallery you can pick up to $_maxGalleryImages images — '
                'all processed in parallel.',
                style: TextStyle(
                  fontSize: 15,
                  color: AppTheme.textSecondary,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 32),
              _ActionTile(
                icon: Icons.photo_camera_rounded,
                title: 'Take photo',
                subtitle: 'Use the camera',
                onTap: () => _capture(ImageSource.camera),
              ),
              const SizedBox(height: 12),
              _ActionTile(
                icon: Icons.photo_library_rounded,
                title: 'Pick from gallery',
                subtitle: 'Choose up to $_maxGalleryImages images',
                onTap: () => _capture(ImageSource.gallery),
              ),
              const Spacer(),
              if (_busy)
                Column(
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(
                      _statusMessage ?? 'Working…',
                      style: const TextStyle(
                        fontSize: 14,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreparedImage {
  const _PreparedImage({required this.original, required this.jpeg});
  final Uint8List original;
  final Uint8List jpeg;
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: AppTheme.primary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  color: AppTheme.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}
