import 'package:flutter/material.dart';

import '../models/receipt.dart';
import '../theme/app_theme.dart';

class ReceiptCard extends StatelessWidget {
  const ReceiptCard({
    super.key,
    required this.receipt,
    required this.index,
    required this.onCategoryChanged,
  });

  final Receipt receipt;
  final int index;
  final ValueChanged<String> onCategoryChanged;

  @override
  Widget build(BuildContext context) {
    final isLowConfidence = receipt.confidence < 0.85;
    final missingProject = receipt.projectName == null;
    final showTimes = receipt.isParking &&
        (receipt.startTime != null || receipt.endTime != null);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: isLowConfidence
              ? AppTheme.error.withValues(alpha: 0.4)
              : const Color(0xFFE2E8F0),
        ),
      ),
      color: AppTheme.surface,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openDrillDown(context, receipt),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Thumbnail(receipt: receipt, index: index),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            receipt.businessName ?? 'Unknown business',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textPrimary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        _ConfidenceChip(confidence: receipt.confidence),
                      ],
                    ),
                    const SizedBox(height: 6),
                    _MetaRow(label: 'Date', value: receipt.date),
                    _MetaRow(
                      label: 'Invoice #',
                      value: receipt.invoiceNumber,
                    ),
                    if (showTimes)
                      _MetaRow(
                        label: 'Time',
                        value:
                            '${receipt.startTime ?? '—'}  →  ${receipt.endTime ?? '—'}',
                      ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.end,
                      children: [
                        _CategoryChip(
                          category: receipt.category,
                          onTap: () => _pickCategory(context),
                        ),
                        Text(
                          receipt.amount != null
                              ? '₪${receipt.amount!.toStringAsFixed(2)}'
                              : '—',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: missingProject
                            ? const Color(0xFFFEF3C7)
                            : const Color(0xFFDCFCE7),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        missingProject
                            ? 'Project: choose manually'
                            : 'Project: ${receipt.projectName}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: missingProject
                              ? const Color(0xFF92400E)
                              : const Color(0xFF166534),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickCategory(BuildContext context) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _CategoryPickerSheet(selected: receipt.category),
    );
    if (picked != null && picked != receipt.category) {
      onCategoryChanged(picked);
    }
  }
}

Future<void> _openDrillDown(BuildContext context, Receipt receipt) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => _ReceiptDetailsSheet(receipt: receipt),
  );
}

void _openOriginalImage(BuildContext context, Receipt receipt) {
  if (receipt.croppedImage == null) return;
  Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder(
      opaque: true,
      barrierColor: Colors.black,
      transitionDuration: const Duration(milliseconds: 280),
      reverseTransitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (_, animation, _) => FadeTransition(
        opacity: animation,
        child: _OriginalImageViewer(receipt: receipt),
      ),
    ),
  );
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.receipt, required this.index});

  final Receipt receipt;
  final int index;

  @override
  Widget build(BuildContext context) {
    final hasCrop = receipt.croppedImage != null;
    final thumb = ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 88,
        height: 110,
        color: const Color(0xFFF1F5F9),
        child: hasCrop
            ? Hero(
                tag: 'receipt-image-${receipt.id}',
                child: Image.memory(receipt.croppedImage!, fit: BoxFit.contain),
              )
            : Center(
                child: Text(
                  '#${index + 1}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ),
      ),
    );
    if (!hasCrop) return thumb;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openOriginalImage(context, receipt),
      child: thumb,
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.label, required this.value});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                color: AppTheme.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value ?? '—',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: value == null
                    ? AppTheme.textSecondary
                    : AppTheme.textPrimary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _ConfidenceChip extends StatelessWidget {
  const _ConfidenceChip({required this.confidence});
  final double confidence;

  @override
  Widget build(BuildContext context) {
    final pct = (confidence * 100).round();
    final isLow = confidence < 0.85;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isLow ? const Color(0xFFFEE2E2) : const Color(0xFFE0F2FE),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$pct%',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: isLow ? const Color(0xFF991B1B) : const Color(0xFF075985),
        ),
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({required this.category, required this.onTap});

  final String category;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = _palette(category);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: palette.background,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                category,
                textDirection: TextDirection.rtl,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: palette.foreground,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.expand_more,
                size: 16,
                color: palette.foreground,
              ),
            ],
          ),
        ),
      ),
    );
  }

  _CategoryPalette _palette(String category) {
    switch (category) {
      case ReceiptCategory.parking:
        return const _CategoryPalette(
          background: Color(0xFFE0E7FF),
          foreground: Color(0xFF3730A3),
        );
      case ReceiptCategory.vehicle:
        return const _CategoryPalette(
          background: Color(0xFFFFE4E6),
          foreground: Color(0xFF9F1239),
        );
      case ReceiptCategory.publicTransport:
        return const _CategoryPalette(
          background: Color(0xFFCCFBF1),
          foreground: Color(0xFF115E59),
        );
      case ReceiptCategory.foodHospitality:
        return const _CategoryPalette(
          background: Color(0xFFFEF3C7),
          foreground: Color(0xFF92400E),
        );
      case ReceiptCategory.softwareCommunications:
        return const _CategoryPalette(
          background: Color(0xFFDBEAFE),
          foreground: Color(0xFF1E40AF),
        );
      default:
        return const _CategoryPalette(
          background: Color(0xFFE2E8F0),
          foreground: Color(0xFF334155),
        );
    }
  }
}

class _CategoryPalette {
  const _CategoryPalette({required this.background, required this.foreground});
  final Color background;
  final Color foreground;
}

class _CategoryPickerSheet extends StatelessWidget {
  const _CategoryPickerSheet({required this.selected});
  final String selected;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFFCBD5E1),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 12),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Choose category',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary,
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          for (final option in ReceiptCategory.all)
            ListTile(
              title: Text(
                option,
                textDirection: TextDirection.rtl,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              trailing: option == selected
                  ? const Icon(Icons.check, color: AppTheme.primary)
                  : null,
              onTap: () => Navigator.of(context).pop(option),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _ReceiptDetailsSheet extends StatelessWidget {
  const _ReceiptDetailsSheet({required this.receipt});
  final Receipt receipt;

  @override
  Widget build(BuildContext context) {
    final mediaHeight = MediaQuery.of(context).size.height;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: mediaHeight * 0.85),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFCBD5E1),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    receipt.businessName ?? 'Unknown business',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
                      if (receipt.date != null) receipt.date!,
                      if (receipt.invoiceNumber != null)
                        '#${receipt.invoiceNumber}',
                    ].join(' · '),
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  if (receipt.croppedImage != null) ...[
                    const SizedBox(height: 6),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        onPressed: () => _openOriginalImage(context, receipt),
                        icon: const Icon(Icons.image_search, size: 18),
                        label: const Text(
                          'צפה במקור',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        style: TextButton.styleFrom(
                          foregroundColor: AppTheme.primary,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 0,
                          ),
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Text(
                        receipt.amount != null
                            ? '₪${receipt.amount!.toStringAsFixed(2)}'
                            : '—',
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE2E8F0),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          receipt.category,
                          textDirection: TextDirection.rtl,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF334155),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Row(
                children: [
                  const Text(
                    'Items',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '(${receipt.items.length})',
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: receipt.items.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.fromLTRB(20, 12, 20, 24),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'No itemized breakdown available for this receipt.',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
                      itemCount: receipt.items.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, indent: 16, endIndent: 16),
                      itemBuilder: (_, i) => _ItemTile(item: receipt.items[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OriginalImageViewer extends StatelessWidget {
  const _OriginalImageViewer({required this.receipt});

  final Receipt receipt;

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 6,
              child: Center(
                child: Hero(
                  tag: 'receipt-image-${receipt.id}',
                  child: Image.memory(
                    receipt.croppedImage!,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: topPadding + 8,
            right: 8,
            child: Material(
              color: Colors.black.withValues(alpha: 0.5),
              shape: const CircleBorder(),
              child: IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.item});
  final ReceiptItem item;

  @override
  Widget build(BuildContext context) {
    final isDiscount = (item.price ?? 0) < 0;
    final qty = item.quantity;
    final qtyLabel =
        qty == null ? null : (qty % 1 == 0 ? qty.toInt().toString() : qty.toString());
    final priceText = item.price == null
        ? '—'
        : (isDiscount
            ? '-₪${item.price!.abs().toStringAsFixed(2)}'
            : '₪${item.price!.toStringAsFixed(2)}');

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      title: Text(
        item.description ?? '—',
        textDirection: TextDirection.rtl,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: isDiscount ? const Color(0xFF166534) : AppTheme.textPrimary,
        ),
      ),
      subtitle: (item.code == null && qtyLabel == null)
          ? null
          : Text(
              [
                if (item.code != null) item.code,
                if (qtyLabel != null) 'x$qtyLabel',
              ].whereType<String>().join('  ·  '),
              style: const TextStyle(
                fontSize: 12,
                color: AppTheme.textSecondary,
              ),
            ),
      trailing: Text(
        priceText,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: isDiscount ? const Color(0xFF166534) : AppTheme.textPrimary,
        ),
      ),
    );
  }
}
