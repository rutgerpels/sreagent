// Telemetry must be the first import so HTTP auto-instrumentation is in place.
import './telemetry';

import express, { Request, Response } from 'express';

const app = express();
app.use(express.json());

const SERVICE_NAME = process.env.SERVICE_NAME ?? 'checkout-api';
const PORT = Number.parseInt(process.env.PORT ?? '8080', 10);
const PAYMENT_SERVICE_URL = process.env.PAYMENT_SERVICE_URL ?? 'http://localhost:8082';

app.get('/health', (_req: Request, res: Response) => {
  res.json({ status: 'ok', service: SERVICE_NAME });
});

app.get('/ready', (_req: Request, res: Response) => {
  res.json({ status: 'ready', service: SERVICE_NAME });
});

app.post('/checkout', async (req: Request, res: Response) => {
  const amount = Number(req.body?.amount ?? 49.99);
  const currency = String(req.body?.currency ?? 'EUR');
  const orderId = `ord_${Math.random().toString(36).slice(2, 10)}`;

  try {
    const payResp = await fetch(`${PAYMENT_SERVICE_URL}/pay`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ amount, currency, orderId }),
    });

    if (!payResp.ok) {
      const text = await payResp.text();
      return res.status(502).json({
        status: 'failed',
        service: SERVICE_NAME,
        orderId,
        error: `payment-service returned ${payResp.status}`,
        detail: text.slice(0, 200),
      });
    }

    const payment = (await payResp.json()) as Record<string, unknown>;
    return res.json({
      status: 'confirmed',
      service: SERVICE_NAME,
      orderId,
      amount,
      currency,
      payment,
      confirmedAt: new Date().toISOString(),
    });
  } catch (err) {
    return res.status(502).json({
      status: 'failed',
      service: SERVICE_NAME,
      orderId,
      error: 'payment-service unreachable',
      detail: err instanceof Error ? err.message : String(err),
    });
  }
});

const server = app.listen(PORT, () => {
  // eslint-disable-next-line no-console
  console.log(`[${SERVICE_NAME}] listening on :${PORT} -> payment at ${PAYMENT_SERVICE_URL}`);
});

const shutdown = (signal: string): void => {
  // eslint-disable-next-line no-console
  console.log(`[${SERVICE_NAME}] received ${signal}, shutting down`);
  server.close(() => process.exit(0));
};
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
