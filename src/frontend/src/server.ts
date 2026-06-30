// Telemetry must be the first import so HTTP auto-instrumentation is in place.
import './telemetry';

import path from 'node:path';
import express, { NextFunction, Request, Response } from 'express';

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '64kb' }));

const SERVICE_NAME = process.env.SERVICE_NAME ?? 'frontend';
const PORT = Number.parseInt(process.env.PORT ?? '8080', 10);
const CHECKOUT_API_URL = process.env.CHECKOUT_API_URL ?? 'http://localhost:8081';

// Security headers on the only public endpoint. Script/style are served from
// 'self' (see public/app.js) so we avoid 'unsafe-inline'.
app.use((_req: Request, res: Response, next: NextFunction) => {
  res.setHeader(
    'Content-Security-Policy',
    "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
  );
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
  res.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=(), payment=()');
  res.setHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains; preload');
  next();
});

app.get('/health', (_req: Request, res: Response) => {
  res.json({ status: 'ok', service: SERVICE_NAME });
});

app.get('/ready', (_req: Request, res: Response) => {
  res.json({ status: 'ready', service: SERVICE_NAME });
});

// Thin proxy to the internal checkout-api. The browser never talks to internal
// services directly — only this public frontend does, server-side.
app.post('/api/checkout', async (req: Request, res: Response) => {
  const amount = Number(req.body?.amount ?? 49.99);
  const currency = String(req.body?.currency ?? 'EUR');
  try {
    const resp = await fetch(`${CHECKOUT_API_URL}/checkout`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ amount, currency }),
    });
    const data = (await resp.json()) as Record<string, unknown>;
    res.status(resp.status).json(data);
  } catch (err) {
    res.status(502).json({
      status: 'failed',
      service: SERVICE_NAME,
      error: 'checkout-api unreachable',
      detail: err instanceof Error ? err.message : String(err),
    });
  }
});

// Static checkout page.
app.use(express.static(path.join(__dirname, '..', 'public')));

const server = app.listen(PORT, () => {
  // eslint-disable-next-line no-console
  console.log(`[${SERVICE_NAME}] listening on :${PORT} -> checkout at ${CHECKOUT_API_URL}`);
});

const shutdown = (signal: string): void => {
  // eslint-disable-next-line no-console
  console.log(`[${SERVICE_NAME}] received ${signal}, shutting down`);
  server.close(() => process.exit(0));
};
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
