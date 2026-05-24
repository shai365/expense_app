import express, { type Request, type Response, type NextFunction } from 'express';
import { scanHandler } from './routes/scan.js';
import { exchangeSessionHandler } from './routes/sessions.js';
import { requireAuth } from './middleware/auth.js';

const app = express();
const PORT = Number(process.env.PORT) || 8080;

app.use(express.json({ limit: '15mb' }));

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

