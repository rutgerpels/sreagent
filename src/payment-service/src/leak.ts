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
let activeChunkBytes = 0;

const flagOn = (): boolean => (process.env.ENABLE_SLOW_LEAK ?? 'false').toLowerCase() === 'true';

const configuredChunkBytes = (): number => {
  const kb = Number.parseInt(process.env.LEAK_CHUNK_KB ?? '1024', 10);
  return (Number.isFinite(kb) && kb > 0 ? kb : 1024) * 1024;
};

const calibratedChunkBytes = (intervalMs: number): number => {
  const threshold = Number.parseInt(process.env.MEMORY_ALERT_THRESHOLD_BYTES ?? '', 10);
  const targetSeconds = Number.parseInt(process.env.LEAK_TARGET_CROSSING_SECONDS ?? '360', 10);
  if (!Number.isFinite(threshold) || threshold <= 0 || !Number.isFinite(targetSeconds) || targetSeconds <= 0) {
    return configuredChunkBytes();
  }

  const bytesToThreshold = Math.max(threshold - process.memoryUsage().rss, 0);
  const ticksToThreshold = Math.max(Math.floor((targetSeconds * 1000) / intervalMs), 1);
  return Math.max(Math.ceil(bytesToThreshold / ticksToThreshold), 64 * 1024);
};

/**
 * Start a deterministic background leak so the alert fires in roughly 8–12
 * minutes regardless of browser traffic or normal startup-memory variation.
 */
export function startBackgroundLeak(): NodeJS.Timeout {
  const intervalMs = Number.parseInt(process.env.LEAK_INTERVAL_MS ?? '2000', 10);
  const effectiveIntervalMs = Number.isFinite(intervalMs) && intervalMs > 0 ? intervalMs : 2000;
  activeChunkBytes = calibratedChunkBytes(effectiveIntervalMs);
  const timer = setInterval(() => {
    if (flagOn()) {
      leakedChunks.push(Buffer.alloc(activeChunkBytes, 1));
    }
  }, effectiveIntervalMs);
  // Do not keep the event loop alive solely for the leak timer.
  timer.unref();
  return timer;
}

export function leakStats(): { enabled: boolean; chunks: number; approxBytes: number } {
  return {
    enabled: flagOn(),
    chunks: leakedChunks.length,
    approxBytes: leakedChunks.length * activeChunkBytes,
  };
}
