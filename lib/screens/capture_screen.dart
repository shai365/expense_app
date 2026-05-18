import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../config/api_config.dart';
import '../models/receipt.dart';
import '../services/gemini_service.dart';
import '../services/image_cropper.dart';
import '../theme/app_theme.dart';
import 'results_screen.dart';

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
    final useMock = ApiConfig.useMockGemini;
    if (!useMock && !ApiConfig.hasGeminiKey) {
      _showError(
        'Gemini API key not set. Pass --dart-define=GEMINI_API_KEY=… '
        'when running the app.',
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
              ? 'Asking Gemini to detect receipts…'
              : 'Processing 0 of ${files.length} images…');
    });

    final service = GeminiService(
      apiKey: ApiConfig.geminiApiKey,
      useMock: useMock,
    );

    var completed = 0;

    Future<List<Receipt>> processOne(XFile file) async {
      final bytes = await file.readAsBytes();
      final receipts = await service.analyzeReceipts(
        imageBytes: bytes,
        mimeType: _mimeFor(file.name),
        companyCode: widget.companyCode,
      );
      // Crop from THIS image so each receipt's thumbnail matches its source.
      await ImageCropper.attachCrops(sourceBytes: bytes, receipts: receipts);

      completed++;
      if (mounted && files.length > 1) {
        setState(() {
          _statusMessage =
              'Processing $completed of ${files.length} images…';
        });
      }
      return receipts;
    }

    try {
      final perImage = await Future.wait(files.map(processOne));
      final merged = service.deduplicate(perImage.expand((r) => r).toList());

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
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _statusMessage = null;
      });
      _showError('Analysis failed: $e');
    }
  }

  Future<List<XFile>> _pickFiles(ImageSource source) async {
    if (source == ImageSource.camera) {
      final picked = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 2048,
        imageQuality: 88,
      );
      return picked == null ? const [] : [picked];
    }

    // Gallery: allow multi-select, hard-capped at _maxGalleryImages.
    final picked = await _picker.pickMultiImage(
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
