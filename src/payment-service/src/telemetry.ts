/**
 * Telemetry bootstrap. MUST be imported before express so the Azure Monitor
 * OpenTelemetry distro can auto-instrument incoming/outgoing HTTP calls.
 *
 * The Application Insights connection string is provided via the
 * APPLICATIONINSIGHTS_CONNECTION_STRING environment variable, which Container
 * Apps injects from Azure Key Vault using the app's managed identity (no secret
 * is ever written to source).
 */
import { useAzureMonitor } from '@azure/monitor-opentelemetry';
import { metrics } from '@opentelemetry/api';

const serviceName = process.env.SERVICE_NAME ?? 'payment-service';
const connectionString = process.env.APPLICATIONINSIGHTS_CONNECTION_STRING;

if (connectionString) {
  // Set the cloud role name via the standard OpenTelemetry env var. Passing a
  // custom `resource` object to useAzureMonitor is incompatible with the SDK's
  // immutable ResourceImpl (attributes is getter-only) and crashes on startup.
  process.env.OTEL_SERVICE_NAME = process.env.OTEL_SERVICE_NAME ?? serviceName;
  useAzureMonitor({
    azureMonitorExporterOptions: { connectionString },
  });
  // eslint-disable-next-line no-console
  console.log(`[telemetry] Azure Monitor enabled for ${serviceName}`);
} else {
  // eslint-disable-next-line no-console
  console.log('[telemetry] APPLICATIONINSIGHTS_CONNECTION_STRING not set — telemetry disabled');
}

// Custom observable gauge so the memory trend is explicit in App Insights and
// available for the Azure Monitor alert narrative.
const meter = metrics.getMeter('contosopay');
meter
  .createObservableGauge('process_memory_rss_bytes', {
    description: 'Resident set size of the Node.js process in bytes',
    unit: 'By',
  })
  .addCallback((result) => {
    result.observe(process.memoryUsage().rss, { service: serviceName });
  });

meter
  .createObservableGauge('process_heap_used_bytes', {
    description: 'V8 heap used by the Node.js process in bytes',
    unit: 'By',
  })
  .addCallback((result) => {
    result.observe(process.memoryUsage().heapUsed, { service: serviceName });
  });
