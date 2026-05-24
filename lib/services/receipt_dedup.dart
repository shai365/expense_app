import '../models/receipt.dart';

/// Cross-image receipt deduplication.
///
/// Primary key: invoice_number (case-insensitive, trimmed).
/// Fallback when invoice_number is missing on BOTH candidates:
/// match on business_name + date + amount when all three are present.
///
/// On collision the higher-confidence receipt wins; ties (within 0.05)
/// fall back to the receipt with more populated fields. Non-null fields
/// from the loser are merged into the winner so partial captures don't
/// drop data.
List<Receipt> deduplicateReceipts(List<Receipt> receipts) {
  final kept = <Receipt>[];

  for (final candidate in receipts) {
    final candidateInv = _normInvoice(candidate.invoiceNumber);
    var duplicateAt = -1;

    for (var i = 0; i < kept.length; i++) {
      final existing = kept[i];
      final existingInv = _normInvoice(existing.invoiceNumber);

      if (candidateInv != null && existingInv == candidateInv) {
        duplicateAt = i;
        break;
      }

      if (candidateInv == null && existingInv == null) {
        if (_textsEqual(candidate.businessName, existing.businessName) &&
            _textsEqual(candidate.date, existing.date) &&
            _amountsEqual(candidate.amount, existing.amount)) {
          duplicateAt = i;
          break;
        }
      }
    }

    if (duplicateAt == -1) {
      kept.add(candidate);
    } else {
      final existing = kept[duplicateAt];
      final winner = _pickWinner(candidate, existing);
      final loser = identical(winner, candidate) ? existing : candidate;
      kept[duplicateAt] = _mergeFields(winner, loser);
    }
  }

  return kept;
}

Receipt _pickWinner(Receipt a, Receipt b) {
  final diff = (a.confidence - b.confidence).abs();
  if (diff < 0.05) {
    final aScore = _completenessScore(a);
    final bScore = _completenessScore(b);
    if (aScore != bScore) return aScore > bScore ? a : b;
  }
  return a.confidence >= b.confidence ? a : b;
}

int _completenessScore(Receipt r) {
  var score = 0;
  if (r.invoiceNumber != null) score++;
  if (r.date != null) score++;
  if (r.businessName != null) score++;
  if (r.amount != null) score++;
  if (r.vat != null) score++;
  if (r.projectName != null) score++;
  if (r.category != ReceiptCategory.other) score++;
  score += r.items.length;
  return score;
}

Receipt _mergeFields(Receipt winner, Receipt loser) {
  return Receipt(
    id: winner.id,
    invoiceNumber: winner.invoiceNumber ?? loser.invoiceNumber,
    date: winner.date ?? loser.date,
    businessName: winner.businessName ?? loser.businessName,
    amount: winner.amount ?? loser.amount,
    vat: winner.vat ?? loser.vat,
    startTime: winner.startTime ?? loser.startTime,
    endTime: winner.endTime ?? loser.endTime,
    projectName: winner.projectName ?? loser.projectName,
    category: winner.category == ReceiptCategory.other
        ? loser.category
        : winner.category,
    items: winner.items.length >= loser.items.length
        ? winner.items
        : loser.items,
    confidence: winner.confidence >= loser.confidence
        ? winner.confidence
        : loser.confidence,
    boundingBox: winner.boundingBox ?? loser.boundingBox,
    duplicate: winner.duplicate || loser.duplicate,
  )..croppedImage = winner.croppedImage ?? loser.croppedImage;
}

String? _normInvoice(String? raw) {
  if (raw == null) return null;
  final t = raw.trim().toLowerCase();
  return t.isEmpty ? null : t;
}

bool _textsEqual(String? a, String? b) {
  if (a == null || b == null) return false;
  return a.trim().toLowerCase() == b.trim().toLowerCase();
}

bool _amountsEqual(double? a, double? b) {
  if (a == null || b == null) return false;
  return (a - b).abs() < 0.005;
}
