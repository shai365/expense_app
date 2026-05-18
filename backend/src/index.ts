import express, { type Request, type Response, type NextFunction } from 'express';
import { scanHandler } from './routes/scan.js';

const app = express();
const PORT = Number(process.env.PORT) || 8080;

app.use(express.json({ limit: '15mb' }));

app.get('/healthz', (_req: Request, res: Response) => {
  res.status(200).json({ status: 'ok' });
});

app.post('/v1/scan', scanHandler);

app.use((err: unknown, _req: Request, res: Response, _next: NextFunction) => {
  console.error('unhandled_error', err);
  res.status(500).json({ error: 'internal_error' });
});

app.listen(PORT, () => {
  console.log(`Smart Expense Agent backend listening on :${PORT}`);
});
