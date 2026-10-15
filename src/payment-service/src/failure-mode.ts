/**
 * Scenario D fault: a deterministic payment-authorization failure.
 *
 * PAYMENT_FAILURE_MODE is read from the process environment (default "off").
 * "unavailable" makes POST /pay return HTTP 503 while /health and /ready stay
 * healthy, so the fault looks like a bad downstream dependency rather than a
 * crashed container. Recovery is a configuration change that produces a fresh
 * healthy revision, not a restart or a scale-out.
 */

export type FailureMode = 'off' | 'unavailable';

const VALID_MODES: readonly FailureMode[] = ['off', 'unavailable'];

export function parseFailureMode(raw: string | undefined): FailureMode {
  const value = (raw ?? '').trim().toLowerCase() || 'off';
  if (!(VALID_MODES as readonly string[]).includes(value)) {
    // Fail fast: a typo must never silently look like a healthy "off".
    throw new Error(`Invalid PAYMENT_FAILURE_MODE "${raw}". Expected one of: ${VALID_MODES.join(', ')}.`);
  }
  return value as FailureMode;
}

export interface PaymentFailureResponse {
  status: 'declined';
  error: string;
  reason: 'payment-processor-unavailable';
}

export function failureResponseFor(mode: FailureMode): { statusCode: number; body: PaymentFailureResponse } | null {
  if (mode === 'off') {
    return null;
  }
  return {
    statusCode: 503,
    body: {
      status: 'declined',
      error: 'payment processor unavailable',
      reason: 'payment-processor-unavailable',
    },
  };
}
