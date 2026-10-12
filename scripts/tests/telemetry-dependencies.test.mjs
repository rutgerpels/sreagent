import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createServer } from "node:http";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

async function verifyFetchTelemetry(service) {
  const require = createRequire(resolve(`src/${service}/package.json`));
  const monitorPath = require.resolve("@azure/monitor-opentelemetry");
  const sdkRequire = createRequire(monitorPath);
  const { NodeTracerProvider } = sdkRequire("@opentelemetry/sdk-trace-node");
  const { InMemorySpanExporter, SimpleSpanProcessor } = sdkRequire(
    "@opentelemetry/sdk-trace-base",
  );
  const { trace, SpanKind, SpanStatusCode } = require("@opentelemetry/api");
  const exporter = new InMemorySpanExporter();
  const provider = new NodeTracerProvider({
    spanProcessors: [new SimpleSpanProcessor(exporter)],
  });

  // Exercise the compiled bootstrap without sending telemetry to Azure.
  const monitor = require(monitorPath);
  monitor.useAzureMonitor = () => provider.register();
  process.env.APPLICATIONINSIGHTS_CONNECTION_STRING = "offline-exporter-stub";
  require(resolve(`src/${service}/dist/telemetry.js`));

  const received = [];
  const server = createServer((request, response) => {
    received.push(request.headers.traceparent);
    response.statusCode = request.url === "/fail" ? 500 : 200;
    response.end("fixture");
  });
  await new Promise((accept) => server.listen(0, "127.0.0.1", accept));
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  const url = `http://127.0.0.1:${address.port}`;
  let parentContext;
  try {
    await trace.getTracer("dependency-regression").startActiveSpan(
      "checkout",
      async (parent) => {
        parentContext = parent.spanContext();
        try {
          for (const path of ["/pay", "/fail"]) {
            const response = await fetch(`${url}${path}`, {
              method: "POST",
              signal: AbortSignal.timeout(5_000),
            });
            await response.text();
          }
        } finally {
          parent.end();
        }
      },
    );
    await provider.forceFlush();
    const clients = exporter.getFinishedSpans().filter(
      (span) => span.kind === SpanKind.CLIENT,
    );
    assert.equal(clients.length, 2, "Each fetch must emit one dependency span.");
    for (const [index, span] of clients.entries()) {
      assert.equal(span.spanContext().traceId, parentContext.traceId);
      assert.equal(span.parentSpanContext?.spanId, parentContext.spanId);
      assert.equal(
        received[index],
        `00-${span.spanContext().traceId}-${span.spanContext().spanId}-01`,
      );
    }
    assert.equal(clients[1].status.code, SpanStatusCode.ERROR);
  } finally {
    server.closeAllConnections();
    await new Promise((accept) => server.close(accept));
    await provider.shutdown();
  }
}

if (process.argv[2]) {
  await verifyFetchTelemetry(process.argv[2]);
} else {
  for (const service of ["frontend", "checkout-api"]) {
    test(`${service} bootstrap traces fetch and propagates checkout context`, () => {
      const result = spawnSync(
        process.execPath,
        [fileURLToPath(import.meta.url), service],
        { encoding: "utf8", timeout: 60_000 },
      );
      assert.ifError(result.error);
      assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    });
  }
}
