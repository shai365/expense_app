import express, { type Request, type Response, type NextFunction } from 'express';
import { randomBytes } from 'node:crypto';
import { scanHandler } from './routes/scan.js';
import { exchangeSessionHandler } from './routes/sessions.js';
import { requireAuth } from './middleware/auth.js';

const app = express();
const PORT = Number(process.env.PORT) || 8080;

// --- perf telemetry: stamp /v1/scan requests on arrival, time JSON parse ---
declare module 'express-serve-static-core' {
  interface Request {
    reqId?: string;
    receivedAt?: number;
    contentLength?: number;
  }
}

app.use((req, _res, next) => {
  if (req.path === '/v1/scan' && req.method === 'POST') {
    req.reqId = randomBytes(4).toString('hex');
    req.receivedAt = Date.now();
    req.contentLength = Number(req.headers['content-length']) || 0;
    console.log(
      `[scan ${req.reqId}] >>> request received: Content-Length=${req.contentLength}B (${(req.contentLength / 1024).toFixed(1)}KB)`,
    );
    console.time(`[scan ${req.reqId}] express.json parse`);
  }
  next();
});

app.use(express.json({ limit: '15mb' }));

app.use((req, _res, next) => {
  if (req.path === '/v1/scan' && req.method === 'POST' && req.reqId) {
    console.timeEnd(`[scan ${req.reqId}] express.json parse`);
  }
  next();
});

app.get('/healthz', (_req: Request, res: Response) => {
  res.status(200).json({ status: 'ok' });
});

app.post('/v1/sessions/exchange', exchangeSessionHandler);
app.post('/v1/scan', requireAuth, scanHandler);

app.use((err: unknown, _req: Request, res: Response, _next: NextFunction) => {
  console.error('unhandled_error', err);
  res.status(500).json({ error: 'internal_error' });
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`Smart Expense Agent backend listening on http://0.0.0.0:${PORT}`);
});

