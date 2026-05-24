import type { Request, Response, NextFunction } from 'express';
import {
  analyzeReceipts,
  GeminiError,
  type GeminiReceipt,
  type Project,
} from '../services/gemini.js';
import { persistReceipts } from '../services/persistence.js';
import { prisma } from '../db.js';

const GEMINI_MODEL = process.env.GEMINI_MODEL ?? 'gemini-1.5-flash';

interface ScanBody {
  image?: { data?: unknown; mime_type?: unknown };
  company_code?: unknown;
  projects?: unknown;
}

function badRequest(res: Response, message: string): void {
  res.status(400).json({ error: 'bad_request', message });
}

export async function scanHandler(
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> {
  const auth = req.auth;
  if (!auth) {
    // Defensive: route is mounted behind requireAuth, so this is unreachable
    // unless middleware wiring drifts.
    res.status(401).json({ error: 'unauthenticated' });
    return;
  }

  const body = (req.body ?? {}) as ScanBody;
  const data = body.image?.data;
  const mime = body.image?.mime_type;
  const companyCode = body.company_code;
  const { orgId, userId } = auth;

  if (typeof data !== 'string' || data.length === 0) {
    badRequest(res, 'image.data (base64 string) is required');
    return;
  }
  if (typeof mime !== 'string' || !mime.startsWith('image/')) {
    badRequest(res, 'image.mime_type must be an "image/*" string');
    return;
  }
  if (typeof companyCode !== 'string' || companyCode.length === 0) {
    badRequest(res, 'company_code is required');
    return;
  }

  const projects: Project[] = Array.isArray(body.projects)
    ? body.projects.flatMap((p): Project[] => {
        if (!p || typeof p !== 'object') return [];
        const name = (p as { name?: unknown }).name;
        if (typeof name !== 'string' || name.length === 0) return [];
        const rawAddress = (p as { address?: unknown }).address;
        const address = typeof rawAddress === 'string' ? rawAddress : undefined;
        return [address !== undefined ? { name, address } : { name }];
      })
    : [];

  let scanJobId: string;
  try {
    const scanJob = await prisma.scanJob.create({
      data: {
        orgId,
        userId,
        model: GEMINI_MODEL,
        status: 'pending',
        requestBytes: data.length,
      },
      select: { id: true },
    });
    scanJobId = scanJob.id;
  } catch (err) {
    next(err);
    return;
  }

  const startedAt = Date.now();
  let receipts: GeminiReceipt[];
  try {
    receipts = await analyzeReceipts({
      imageBase64: data,
      mimeType: mime,
      companyCode,
      projects,
    });
  } catch (err) {
    const errorCode =
      err instanceof GeminiError ? err.code : 'gemini_unknown_error';
    await prisma.scanJob
      .update({
        where: { id: scanJobId },
        data: {
          status: 'failed',
          errorCode,
          latencyMs: Date.now() - startedAt,
          completedAt: new Date(),
        },
      })
      .catch((e) => console.error('scan_job_update_failed', e));

    if (err instanceof GeminiError) {
      const status = err.code === 'config_missing' ? 500 : 502;
      res.status(status).json({ error: err.code, message: err.message });
      return;
    }
    next(err);
    return;
  }

  try {
    const persisted = await persistReceipts({
      orgId,
      userId,
      scanJobId,
      receipts,
    });

    const responseBytes = Buffer.byteLength(JSON.stringify(receipts), 'utf8');
    await prisma.scanJob.update({
      where: { id: scanJobId },
      data: {
        status: 'succeeded',
        receiptCount: persisted.length,
        responseBytes,
        latencyMs: Date.now() - startedAt,
        completedAt: new Date(),
      },
    });

    res.status(200).json({
      scan_job_id: scanJobId,
      receipts: persisted.map((p) => ({
        id: p.id,
        duplicate: p.duplicate,
        ...p.data,
      })),
    });
  } catch (err) {
    await prisma.scanJob
      .update({
        where: { id: scanJobId },
        data: {
          status: 'failed',
          errorCode: 'persistence_error',
          latencyMs: Date.now() - startedAt,
          completedAt: new Date(),
        },
      })
      .catch((e) => console.error('scan_job_update_failed', e));
    next(err);
  }
}
