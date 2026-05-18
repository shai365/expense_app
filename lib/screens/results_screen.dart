import 'package:flutter/material.dart';

import '../models/receipt.dart';
import '../theme/app_theme.dart';
import '../widgets/receipt_card.dart';

class ResultsScreen extends StatefulWidget {
  const ResultsScreen({
    super.key,
    required this.receipts,
  });

  final List<Receipt> receipts;

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  late List<Receipt> _receipts;

  @override
  void initState() {
    super.initState();
    _receipts = List<Receipt>.from(widget.receipts);
  }

  void _updateCategory(int index, String category) {
    setState(() {
      _receipts[index] = _receipts[index].copyWith(category: category);
    });
  }

  @override
  Widget build(BuildContext context) {
    final lowConfidenceCount =
        _receipts.where((r) => r.confidence < 0.85).length;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _receipts.length == 1
              ? '1 receipt detected'
              : '${_receipts.length} receipts detected',
        ),
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          _Summary(
            total: _receipts.length,
            lowConfidence: lowConfidenceCount,
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              itemCount: _receipts.length,
              itemBuilder: (context, i) {
                return ReceiptCard(
                  receipt: _receipts[i],
                  index: i,
                  onCategoryChanged: (cat) => _updateCategory(i, cat),
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text('Re-scan'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Saving to local DB is not implemented yet.',
                            ),
                          ),
                        );
                      },
                      child: const Text('Confirm all'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.total, required this.lowConfidence});

  final int total;
  final int lowConfidence;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      decoration: const BoxDecoration(
        color: AppTheme.primary,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            total == 1
                ? '1 receipt found in the image'
                : '$total receipts found in the image',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            lowConfidence == 0
                ? 'All entries above 85% confidence — verify and confirm.'
                : '$lowConfidence below 85% — review highlighted cards.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}
