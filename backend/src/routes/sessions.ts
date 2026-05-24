import type { Request, Response, NextFunction } from 'express';
import { prisma } from '../db.js';
import { issueSession, SessionError } from '../services/session.js';

interface ExchangeBody {
  company_code?: unknown;
  device_id?: unknown;
}

function badRequest(res: Response, message: string): void {
  res.status(400).json({ error: 'bad_request', message });
}

export async function exchangeSessionHandler(
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> {
  const body = (req.body ?? {}) as ExchangeBody;
  const companyCode = body.company_code;
  const deviceId = body.device_id;

  if (typeof companyCode !== 'string' || companyCode.trim().length === 0) {
    badRequest(res, 'company_code is required');
    return;
  }
  if (typeof deviceId !== 'string' || deviceId.trim().length === 0) {
    badRequest(res, 'device_id is required');
    return;
  }

  const normalizedCode = companyCode.trim();

  try {
    // Case-insensitive lookup matches the partial unique index on
    // lower(company_code) added in migration 002.
    const org = await prisma.organization.findFirst({
      where: {
        companyCode: { equals: normalizedCode, mode: 'insensitive' },
        deletedAt: null,
      },
      select: { id: true },
    });

    if (!org) {
      res.status(404).json({
        error: 'unknown_company_code',
        message: 'No active organization matches that company_code',
      });
      return;
    }

    // For v1, the Flutter client identifies itself with a company_code only,
    // so we pick the earliest active owner membership as the acting user.
    // Once real per-user auth lands, this step is replaced by a Supabase JWT
    // exchange and we drop company_code from the login flow entirely.
    const membership = await prisma.membership.findFirst({
      where: { orgId: org.id, role: 'owner', status: 'active' },
      orderBy: { createdAt: 'asc' },
      select: { userId: true },
    });

    if (!membership) {
      res.status(409).json({
        error: 'no_owner_membership',
        message: 'Organization has no active owner membership',
      });
      return;
    }

    const session = issueSession({ orgId: org.id, userId: membership.userId });

    res.status(200).json({
      org_id: org.id,
      user_id: membership.userId,
      token: session.token,
      expires_at: session.expiresAt.toISOString(),
    });
  } catch (err) {
    if (err instanceof SessionError && err.code === 'config_missing') {
      res.status(500).json({ error: err.code, message: err.message });
      return;
    }
    next(err);
  }
}
