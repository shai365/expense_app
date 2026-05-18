import type { Request, Response, NextFunction } from 'express';
import {
  analyzeReceipts,
  GeminiError,
  type Project,
} from '../services/gemini.js';

interface ScanBody {
  image?: { data?: unknown; mime_type?: unknown };
  company_code?: unknown;
  projects?: unknown;
}

export async function scanHandler(
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> {
  try {
    const body = (req.body ?? {}) as ScanBody;
    const data = body.image?.data;
    const mime = body.image?.mime_type;
    const companyCode = body.company_code;

    if (typeof data !== 'string' || data.length === 0) {
      res.status(400).json({
        error: 'bad_request',
        message: 'image.data (base64 string) is required',
      });
      return;
    }
    if (typeof mime !== 'string' || !mime.startsWith('image/')) {
      res.status(400).json({
        error: 'bad_request',
        message: 'image.mime_type must be an "image/*" string',
      });
      return;
    }
    if (typeof companyCode !== 'string' || companyCode.length === 0) {
      res.status(400).json({
        error: 'bad_request',
        message: 'company_code is required',
      });
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

    const receipts = await analyzeReceipts({
      imageBase64: data,
      mimeType: mime,
      companyCode,
      projects,
    });

    res.status(200).json({ receipts });
  } catch (err) {
    if (err instanceof GeminiError) {
      const status = err.code === 'config_missing' ? 500 : 502;
      res.status(status).json({ error: err.code, message: err.message });
      return;
    }
    next(err);
  }
}
