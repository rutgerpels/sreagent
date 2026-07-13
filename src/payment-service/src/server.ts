// Telemetry must be the first import so HTTP auto-instrumentation is in place.
import './telemetry';

import express, { Request, Response } from 'express';
import { startBackgroundLeak, leakStats } from './leak';

const app = express();
app.use(express.json());

const SERVICE_NAME = process.env.SERVICE_NAME ?? 'payment-service';
const PORT = Number.parseInt(process.env.PORT ?? '8080', 10);

app.get('/health', (_req: Request, res: Response) => {
  res.json({ status: 'ok', service: SERVICE_NAME });
});

// Liveness vs readiness split so a leaking-but-alive pod is still reported up.
app.get('/ready', (_req: Request, res: Response) => {
  res.json({ status: 'ready', service: SERVICE_NAME, leak: leakStats() });
});

app.post('/pay', (req: Request, res: Response) => {
  const amount = Number(req.body?.amount ?? 0);
  const currency = String(req.body?.currency ?? 'EUR');

  // Simulate a tiny bit of processing work.
  const authCode = Math.random().toString(36).slice(2, 10).toUpperCase();

  res.json({
    status: 'approved',
    service: SERVICE_NAME,
    amount,
    currency,
    authCode,
    processedAt: new Date().toISOString(),
  });
});

const leakTimer = startBackgroundLeak();

const server = app.listen(PORT, () => {
  // eslint-disable-next-line no-console
  console.log(`[${SERVICE_NAME}] listening on :${PORT} (leak enabled: ${leakStats().enabled})`);
});

const shutdown = (signal: string): void => {
  // eslint-disable-next-line no-console
  console.log(`[${SERVICE_NAME}] received ${signal}, shutting down`);
  clearInterval(leakTimer);
  server.close(() => process.exit(0));
};
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
