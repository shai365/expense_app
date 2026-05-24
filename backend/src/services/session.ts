import jwt, { type JwtPayload, type SignOptions } from 'jsonwebtoken';

const DEFAULT_TTL_SECONDS = 60 * 60 * 24 * 7; // 7 days

export interface SessionClaims {
  orgId: string;
  userId: string;
}

export interface IssuedSession {
  token: string;
  expiresAt: Date;
}

export class SessionError extends Error {
  constructor(public code: 'config_missing' | 'invalid' | 'expired', message: string) {
    super(message);
    this.name = 'SessionError';
  }
}

function getSecret(): string {
  const secret = process.env.SESSION_JWT_SECRET;
  if (!secret || secret.length < 32) {
    throw new SessionError(
      'config_missing',
      'SESSION_JWT_SECRET must be set to a string of at least 32 characters',
    );
  }
  return secret;
}

function getTtlSeconds(): number {
  const raw = process.env.SESSION_JWT_TTL_SECONDS;
  if (!raw) return DEFAULT_TTL_SECONDS;
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : DEFAULT_TTL_SECONDS;
}

export function issueSession(claims: SessionClaims): IssuedSession {
  const ttl = getTtlSeconds();
  const options: SignOptions = { expiresIn: ttl, algorithm: 'HS256' };
  const token = jwt.sign(
    { org_id: claims.orgId, user_id: claims.userId },
    getSecret(),
    options,
  );
  const expiresAt = new Date(Date.now() + ttl * 1000);
  return { token, expiresAt };
}

export function verifySession(token: string): SessionClaims {
  let decoded: string | JwtPayload;
  try {
    decoded = jwt.verify(token, getSecret(), { algorithms: ['HS256'] });
  } catch (err) {
    const name = (err as Error).name;
    if (name === 'TokenExpiredError') {
      throw new SessionError('expired', 'Session token has expired');
    }
    throw new SessionError('invalid', 'Session token is invalid');
  }
  if (typeof decoded === 'string' || decoded === null) {
    throw new SessionError('invalid', 'Session token has unexpected shape');
  }
  const orgId = (decoded as JwtPayload & { org_id?: unknown }).org_id;
  const userId = (decoded as JwtPayload & { user_id?: unknown }).user_id;
  if (typeof orgId !== 'string' || typeof userId !== 'string') {
    throw new SessionError('invalid', 'Session token is missing required claims');
  }
  return { orgId, userId };
}
