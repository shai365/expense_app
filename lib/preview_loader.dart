// THROWAWAY preview harness — not part of the app.
//
// Launch standalone (does not touch lib/main.dart or any app logic):
//   flutter run -t lib/preview_loader.dart -d chrome
//
// Eyeballs the organic ThinkingBrush "Claude brush star" loader in
// isolation. Safe to delete.

import 'package:flutter/material.dart';

import 'widgets/thinking_indicator.dart';

void main() => runApp(const _LoaderPreviewApp());

class _LoaderPreviewApp extends StatelessWidget {
  const _LoaderPreviewApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ThinkingBrush preview',
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFFF8FAFC),
        appBar: AppBar(title: const Text('ThinkingBrush preview')),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Large — best for judging the organic ray shimmer.
                const ThinkingBrush(size: 140),
                const SizedBox(height: 16),
                const Text('size: 140'),
                const SizedBox(height: 44),

                // Mid — the likely in-app size.
                const ThinkingBrush(size: 80),
                const SizedBox(height: 16),
                const Text('size: 80'),
                const SizedBox(height: 44),

                // Small — sanity check at compact scale.
                const ThinkingBrush(size: 48),
                const SizedBox(height: 16),
                const Text('size: 48'),
                const SizedBox(height: 44),

                // Denser ray burst variant for comparison.
                const ThinkingBrush(size: 100, rayCount: 18, strokeWidth: 3),
                const SizedBox(height: 16),
                const Text('size: 100 — 18 rays, thinner'),
                const SizedBox(height: 44),

                // On a dark card to judge the glow/contrast.
                Container(
                  padding: const EdgeInsets.all(28),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F172A),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const ThinkingBrush(size: 100),
                ),
                const SizedBox(height: 16),
                const Text('size: 100 — on dark surface'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
