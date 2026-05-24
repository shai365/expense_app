import type { Request, Response, NextFunction } from 'express';
import { verifySession, SessionError } from '../services/session.js';

export interface AuthContext {
  orgId: string;
  userId: string;
}

declare module 'express-serve-static-core' {
  interface Request {
    auth?: AuthContext;
  }
}

export function requireAuth(
  req: Request,
  res: Response,
  next: NextFunction,
): void {
  const header = req.header('authorization') ?? req.header('Authorization');
  if (!header || !header.toLowerCase().startsWith('bearer ')) {
    res.status(401).json({
      error: 'missing_token',
      message: 'Authorization Bearer token is required',
    });
    return;
  }

  const token = header.slice('bearer '.length).trim();
  if (!token) {
    res.status(401).json({
      error: 'missing_token',
      message: 'Bearer token value is empty',
    });
    return;
  }

  try {
    const claims = verifySession(token);
    req.auth = { orgId: claims.orgId, userId: claims.userId };
    next();
  } catch (err) {
    if (err instanceof SessionError) {
      if (err.code === 'config_missing') {
        res.status(500).json({ error: err.code, message: err.message });
        return;
      }
      const status = err.code === 'expired' ? 401 : 401;
      res.status(status).json({ error: err.code, message: err.message });
      return;
    }
    next(err);
  }
}
