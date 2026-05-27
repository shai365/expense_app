import type { Request, Response, NextFunction } from 'express';
import {
  analyzeReceipts,
  GEMINI_MODEL,
  GeminiError,
  type GeminiReceipt,
  type Project,
} from '../services/gemini.js';
import { persistReceipts } from '../services/persistence.js';
import { prisma } from '../db.js';

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

  const reqId = req.reqId ?? 'noid';
  const handlerStart = Date.now();
  const queueMs =
    req.receivedAt !== undefined ? handlerStart - req.receivedAt : -1;
  console.log(
    `[scan ${reqId}] handler start (queue+auth+parse = ${queueMs}ms after receive)`,
  );

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

  // ---- payload telemetry -------------------------------------------------
  const base64Len = data.length;
  const decodedBytes = Math.floor((base64Len * 3) / 4); // approx, ignoring padding
  console.log(
    `[scan ${reqId}] payload: base64.length=${base64Len} chars (~${(base64Len / 1024).toFixed(1)}KB), ` +
      `decoded≈${decodedBytes}B (~${(decodedBytes / 1024).toFixed(1)}KB), mime=${mime}, ` +
      `projects=${projects.length}`,
  );
  // NOTE: server does NOT decode the image — base64 is forwarded to Gemini
  // as inlineData. Server-side decode cost = 0ms by design.
  console.log(`[scan ${reqId}] server-side image decode: 0ms (passthrough)`);

  let scanJobId: string;
  console.time(`[scan ${reqId}] db.scanJob.create`);
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
    console.timeEnd(`[scan ${reqId}] db.scanJob.create`);
    next(err);
    return;
  }
  console.timeEnd(`[scan ${reqId}] db.scanJob.create`);

  const startedAt = Date.now();
  let receipts: GeminiReceipt[];
  console.time(`[scan ${reqId}] gemini.analyzeReceipts TOTAL`);
  try {
    receipts = await analyzeReceipts({
      imageBase64: data,
      mimeType: mime,
      companyCode,
      projects,
      reqId,
    });
  } catch (err) {
    console.timeEnd(`[scan ${reqId}] gemini.analyzeReceipts TOTAL`);
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
  console.timeEnd(`[scan ${reqId}] gemini.analyzeReceipts TOTAL`);
  console.log(
    `[scan ${reqId}] gemini returned ${receipts.length} receipt(s)`,
  );

  try {
    console.time(`[scan ${reqId}] persistReceipts TOTAL`);
    const persisted = await persistReceipts({
      orgId,
      userId,
      scanJobId,
      receipts,
      reqId,
    });
    console.timeEnd(`[scan ${reqId}] persistReceipts TOTAL`);

    const responseBytes = Buffer.byteLength(JSON.stringify(receipts), 'utf8');
    console.time(`[scan ${reqId}] db.scanJob.update succeeded`);
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
    console.timeEnd(`[scan ${reqId}] db.scanJob.update succeeded`);

    const totalMs = Date.now() - (req.receivedAt ?? handlerStart);
    console.log(
      `[scan ${reqId}] <<< DONE: total=${totalMs}ms, gemini->done=${Date.now() - startedAt}ms, responseBytes=${responseBytes}`,
    );

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
