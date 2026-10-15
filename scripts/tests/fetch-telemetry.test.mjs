import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { promisify } from "node:util";
import test from "node:test";

const execute = promisify(execFile);

async function verifyFetchTelemetry(serviceDirectory, enabled) {
  const { createRequire, default: Module } = await import("node:module");
  const assert = (await import("node:assert/strict")).default;
  const { once } = await import("node:events");
  const { join } = await import("node:path");
  const require = createRequire(join(serviceDirectory, "package.json"));
  const { context, trace, SpanKind, SpanStatusCode } = require("@opentelemetry/api");
  const { NodeTracerProvider } = require("@opentelemetry/sdk-trace-node");
  const { InMemorySpanExporter, SimpleSpanProcessor } = require("@opentelemetry/sdk-trace-base");
  const { registerInstrumentations } = require("@opentelemetry/instrumentation");
  const { HttpInstrumentation } = require("@opentelemetry/instrumentation-http");
  const exporter = new InMemorySpanExporter();
  const provider = new NodeTracerProvider({
    spanProcessors: [new SimpleSpanProcessor(exporter)],
  });
  provider.register();

  const azureModulePath = require.resolve("@azure/monitor-opentelemetry");
  const azureModule = new Module(azureModulePath);
  let bootstrapCalls = 0;
  azureModule.exports = {
    useAzureMonitor(options) {
      assert.equal(options.azureMonitorExporterOptions.connectionString, "test-only");
      bootstrapCalls++;
      registerInstrumentations({ instrumentations: [new HttpInstrumentation()] });
    },
  };
  azureModule.loaded = true;
  require.cache[azureModulePath] = azureModule;
  delete process.env.TELEMETRY_MANAGED_IDENTITY_CLIENT_ID;
  if (enabled) {
    process.env.APPLICATIONINSIGHTS_CONNECTION_STRING = "test-only";
  } else {
    delete process.env.APPLICATIONINSIGHTS_CONNECTION_STRING;
  }
  require(join(serviceDirectory, "dist", "telemetry.js"));
  assert.equal(bootstrapCalls, enabled ? 1 : 0);

  const http = require("node:http");
  const received = [];
  const server = http.createServer((request, response) => {
    received.push({
      traceparent: request.headers.traceparent,
      spanContext: trace.getSpan(context.active())?.spanContext(),
    });
    response.writeHead(request.url === "/failure" ? 503 : 200, {
      "content-type": "application/json",
    });
    response.end('{"status":"test"}');
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const port = server.address().port;
  const parents = [];

  try {
    for (const [path, expectedStatus] of [["/success", 200], ["/failure", 503]]) {
      await trace.getTracer("fetch-regression").startActiveSpan(path, async (span) => {
        parents.push(span.spanContext());
        try {
          const response = await fetch(`http://127.0.0.1:${port}${path}`, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: '{"amount":42,"currency":"EUR"}',
          });
          assert.equal(response.status, expectedStatus);
          assert.deepEqual(await response.json(), { status: "test" });
        } finally {
          span.end();
        }
      });
    }
    await new Promise((resolve) => setImmediate(resolve));
    await provider.forceFlush();
    const spans = exporter.getFinishedSpans();
    const clients = spans.filter((span) => span.kind === SpanKind.CLIENT);
    const servers = spans.filter((span) => span.kind === SpanKind.SERVER);
    if (enabled) {
      assert.equal(clients.length, 2, "exactly one dependency span per fetch");
      assert.equal(servers.length, 2);
      for (let index = 0; index < received.length; index++) {
        const parent = parents[index];
        const client = clients.find((span) => span.spanContext().traceId === parent.traceId);
        const serverSpan = servers.find((span) => span.spanContext().traceId === parent.traceId);
        assert.ok(client);
        assert.ok(serverSpan);
        assert.equal(client.parentSpanContext.spanId, parent.spanId);
        assert.equal(serverSpan.parentSpanContext.spanId, client.spanContext().spanId);
        assert.equal(received[index].spanContext.traceId, parent.traceId);
        assert.equal(
          received[index].traceparent,
          `00-${parent.traceId}-${client.spanContext().spanId}-01`,
        );
      }
      assert.equal(
        clients.find((span) => span.attributes["http.response.status_code"] === 503)?.status.code,
        SpanStatusCode.ERROR,
      );
    } else {
      assert.equal(clients.length, 0);
      assert.equal(servers.length, 0);
      assert.ok(received.every((request) => request.traceparent === undefined));
    }
  } finally {
    server.closeAllConnections();
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    await provider.shutdown();
  }
}

for (const service of ["frontend", "checkout-api"]) {
  const directory = resolve("src", service);
  const require = createRequire(resolve(directory, "package.json"));
  test(`${service}: native fetch dependencies preserve HTTP behavior and distributed context`, async () => {
    assert.ok(require.resolve("@azure/monitor-opentelemetry"));
    await execute(process.execPath, [
      "-e", `(${verifyFetchTelemetry.toString()})(${JSON.stringify(directory)},true).catch(error => { console.error(error); process.exitCode = 1; })`,
    ], { timeout: 30_000, maxBuffer: 1024 * 1024 });
  });
  test(`${service}: missing telemetry configuration leaves native fetch uninstrumented`, async () => {
    await execute(process.execPath, [
      "-e", `(${verifyFetchTelemetry.toString()})(${JSON.stringify(directory)},false).catch(error => { console.error(error); process.exitCode = 1; })`,
    ], { timeout: 30_000, maxBuffer: 1024 * 1024 });
  });
}
