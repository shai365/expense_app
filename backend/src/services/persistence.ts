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

async function resolveProjectId(
  orgId: string,
  projectName: string | null,
): Promise<string | null> {
  if (!projectName) return null;
  const project = await prisma.project.findUnique({
    where: { orgId_name: { orgId, name: projectName } },
    select: { id: true },
  });
  return project?.id ?? null;
}

export async function persistReceipts(
  input: PersistReceiptsInput,
): Promise<PersistedReceipt[]> {
  const persisted: PersistedReceipt[] = [];
  const scannedAt = new Date();

  for (const receipt of input.receipts) {
    const projectId = await resolveProjectId(input.orgId, receipt.project_name);
    const vatRate = receipt.vat !== null ? statutoryRateFor(receipt.date) : null;

    try {
      const created = await prisma.$transaction(async (tx) => {
        const row = await tx.receipt.create({
          data: {
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
            boundingBox: receipt.bounding_box as Prisma.InputJsonValue,
            confidence: receipt.confidence,
            scannedAt,
          },
          select: { id: true },
        });

        if (receipt.items.length > 0) {
          await tx.receiptItem.createMany({
            data: receipt.items.map((item, ord) => ({
              receiptId: row.id,
              ord,
              code: item.code,
              description: item.description,
              quantity: item.quantity,
              price: item.price,
            })),
          });
        }

        return row;
      });

      persisted.push({ id: created.id, duplicate: false, data: receipt });
    } catch (e) {
      if (
        e instanceof Prisma.PrismaClientKnownRequestError &&
        e.code === 'P2002' &&
        receipt.invoice_number
      ) {
        const existing = await prisma.receipt.findFirst({
          where: {
            orgId: input.orgId,
            invoiceNumber: receipt.invoice_number,
            deletedAt: null,
          },
          select: { id: true },
        });
        if (existing) {
          persisted.push({ id: existing.id, duplicate: true, data: receipt });
          continue;
        }
      }
      throw e;
    }
  }

  return persisted;
}
