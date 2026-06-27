/**
 * The planted fault — the heart of the demo.
 *
 * A gradual, recoverable memory leak gated behind the ENABLE_SLOW_LEAK feature
 * flag (default OFF). When enabled, memory climbs steadily so that:
 *   - a revision restart clears it (mitigation #1), and
 *   - raising the scale rule spreads load and slows it (mitigation #2).
 *
 * The flag value comes from configuration the app reads at runtime, so flipping
 * it is shipped as a real git commit + GitHub Actions deployment, letting the
 * SRE Agent correlate the incident with a specific commit.
 */

// Module-scoped sink that is intentionally never released while the flag is on.
const leakedChunks: Buffer[] = [];

const flagOn = (): boolean => (process.env.ENABLE_SLOW_LEAK ?? 'false').toLowerCase() === 'true';

const chunkBytes = (): number => {
  const kb = Number.parseInt(process.env.LEAK_CHUNK_KB ?? '256', 10);
  return (Number.isFinite(kb) && kb > 0 ? kb : 256) * 1024;
};

/** Leak a chunk per processed payment when the flag is on. */
export function leakPerRequest(): void {
  if (!flagOn()) {
    return;
  }
  leakedChunks.push(Buffer.alloc(chunkBytes(), 1));
}

/**
 * Start a steady background leak so memory climbs over ~30–40 minutes even when
 * request volume is low. No-op while the flag is off. Returns a stop handle.
 */
export function startBackgroundLeak(): NodeJS.Timeout {
  const intervalMs = Number.parseInt(process.env.LEAK_INTERVAL_MS ?? '5000', 10);
  const timer = setInterval(() => {
    if (flagOn()) {
      leakedChunks.push(Buffer.alloc(chunkBytes(), 1));
    }
  }, Number.isFinite(intervalMs) && intervalMs > 0 ? intervalMs : 5000);
  // Do not keep the event loop alive solely for the leak timer.
  timer.unref();
  return timer;
}

export function leakStats(): { enabled: boolean; chunks: number; approxBytes: number } {
  return {
    enabled: flagOn(),
    chunks: leakedChunks.length,
    approxBytes: leakedChunks.length * chunkBytes(),
  };
}
