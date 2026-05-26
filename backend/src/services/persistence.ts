import { randomUUID } from 'node:crypto';
import { Prisma } from '@prisma/client';
import { prisma } from '../db.js';
import type { GeminiReceipt } from './gemini.js';

const VAT_RATE_CURRENT = 0.18;
const VAT_RATE_HISTORICAL = 0.17;
const VAT_CUTOFF = Date.UTC(2025, 0, 1);

export interface PersistedReceipt {
  id: string;
  duplicate: boolean;
  data: GeminiReceipt;
}

export interface PersistReceiptsInput {
  orgId: string;
  userId: string;
  scanJobId: string;
  receipts: GeminiReceipt[];
}

function statutoryRateFor(dateStr: string | null): number {
  if (!dateStr) return VAT_RATE_CURRENT;
  const parsed = Date.parse(dateStr);
  if (Number.isNaN(parsed)) return VAT_RATE_CURRENT;
  return parsed < VAT_CUTOFF ? VAT_RATE_HISTORICAL : VAT_RATE_CURRENT;
}

function vatSourceFor(receipt: GeminiReceipt): string {
  if (receipt.vat === null) return 'unknown';
  return statutoryRateFor(receipt.date) === VAT_RATE_HISTORICAL
    ? 'calculated_historical'
    : 'calculated_current';
}

function parseReceiptDate(dateStr: string | null): Date | null {
  if (!dateStr) return null;
  const ms = Date.parse(`${dateStr}T00:00:00Z`);
  return Number.isNaN(ms) ? null : new Date(ms);
}

function parseTimeOfDay(timeStr: string | null): Date | null {
  if (!timeStr) return null;
  const ms = Date.parse(`1970-01-01T${timeStr}:00Z`);
  return Number.isNaN(ms) ? null : new Date(ms);
}

export async function persistReceipts(
  input: PersistReceiptsInput,
): Promise<PersistedReceipt[]> {
  if (input.receipts.length === 0) return [];

  const scannedAt = new Date();

  const projectNames = Array.from(
    new Set(
      input.receipts
        .map((r) => r.project_name)
        .filter((n): n is string => !!n),
    ),
  );
  const invoiceNumbers = Array.from(
    new Set(
      input.receipts
        .map((r) => r.invoice_number)
        .filter((n): n is string => !!n),
    ),
  );

  const [projectRows, duplicateRows] = await Promise.all([
    projectNames.length > 0
      ? prisma.project.findMany({
          where: { orgId: input.orgId, name: { in: projectNames } },
          select: { id: true, name: true },
        })
      : Promise.resolve([] as { id: string; name: string }[]),
    invoiceNumbers.length > 0
      ? prisma.receipt.findMany({
          where: {
            orgId: input.orgId,
            invoiceNumber: { in: invoiceNumbers },
            deletedAt: null,
          },
          select: { id: true, invoiceNumber: true },
        })
      : Promise.resolve([] as { id: string; invoiceNumber: string | null }[]),
  ]);

  const projectIdByName = new Map(projectRows.map((p) => [p.name, p.id]));
  const existingIdByInvoice = new Map<string, string>();
  for (const row of duplicateRows) {
    if (row.invoiceNumber) existingIdByInvoice.set(row.invoiceNumber, row.id);
  }

  const queuedIdByInvoice = new Map<string, string>();
  const results: PersistedReceipt[] = [];
  const receiptRows: Prisma.ReceiptCreateManyInput[] = [];
  const itemRows: Prisma.ReceiptItemCreateManyInput[] = [];

  for (const receipt of input.receipts) {
    if (receipt.invoice_number) {
      const existing = existingIdByInvoice.get(receipt.invoice_number);
      if (existing) {
        results.push({ id: existing, duplicate: true, data: receipt });
        continue;
      }
      const queued = queuedIdByInvoice.get(receipt.invoice_number);
      if (queued) {
        results.push({ id: queued, duplicate: true, data: receipt });
        continue;
      }
    }

    const id = randomUUID();
    if (receipt.invoice_number) {
      queuedIdByInvoice.set(receipt.invoice_number, id);
    }

    const projectId = receipt.project_name
      ? projectIdByName.get(receipt.project_name) ?? null
      : null;
    const vatRate = receipt.vat !== null ? statutoryRateFor(receipt.date) : null;

    receiptRows.push({
      id,
      orgId: input.orgId,
      scannedByUserId: input.userId,
      scanJobId: input.scanJobId,
      invoiceNumber: receipt.invoice_number,
      receiptDate: parseReceiptDate(receipt.date),
      businessName: receipt.business_name,
      amount: receipt.amount,
      vatAmount: receipt.vat,
      vatRate,
      vatSource: vatSourceFor(receipt),
      startTime: parseTimeOfDay(receipt.start_time),
      endTime: parseTimeOfDay(receipt.end_time),
      projectId,
      category: receipt.category,
      boundingBox:
        receipt.bounding_box === null
          ? Prisma.JsonNull
          : (receipt.bounding_box as Prisma.InputJsonValue),
      confidence: receipt.confidence,
      scannedAt,
    });

    receipt.items.forEach((item, ord) => {
      itemRows.push({
        receiptId: id,
        ord,
        code: item.code,
        description: item.description,
        quantity: item.quantity,
        price: item.price,
      });
    });

    results.push({ id, duplicate: false, data: receipt });
  }

  if (receiptRows.length > 0) {
    const writes: Prisma.PrismaPromise<unknown>[] = [
      prisma.receipt.createMany({ data: receiptRows }),
    ];
    if (itemRows.length > 0) {
      writes.push(prisma.receiptItem.createMany({ data: itemRows }));
    }
    await prisma.$transaction(writes);
  }

  return results;
}
