import assert from "node:assert/strict";
import { resolve } from "node:path";
import test from "node:test";
import {
  buildExtendedBody,
  desiredSubsetMatches,
  loadDesiredState,
  parseExplicitBoolean,
  renderDesiredState,
  stableJson,
} from "../lib/sre-agent-reconciler.mjs";

const config = resolve("agent/scenario-c");
const disabledEnvironment = {
  SRE_CODE_ACCESS_ENABLED: "false",
  SRE_REMEDIATION_CONNECTOR_ENABLED: "false",
};

test("loads the supported Scenario C desired state", () => {
  const desired = loadDesiredState(config, disabledEnvironment);
  assert.equal(desired.expectedAgent.incidentPlatform, "AzMonitor");
  assert.deepEqual(desired.expectedAgent.connectors, [
    "app-insights",
    "azure-monitor",
    "log-analytics",
  ]);
  assert.equal(desired.subagents[0].name, "gitops-remediation");
  assert.match(
    desired.subagents[0].properties.instructions,
    /Never modify Azure resources directly/,
  );
  assert.equal(desired.codeAccess.enabled, false);
  assert.equal(desired.codeAccess.domain, "github.com");
});

test("requires complete Key Vault-backed Code Access metadata", () => {
  assert.throws(
    () =>
      loadDesiredState(config, {
        ...disabledEnvironment,
        SRE_CODE_ACCESS_ENABLED: "true",
      }),
    /Code Access is enabled but missing/,
  );
});

test("fails closed for unsupported remote MCP managed identity", () => {
  assert.throws(
    () =>
      loadDesiredState(config, {
        ...disabledEnvironment,
        SRE_REMEDIATION_CONNECTOR_ENABLED: "true",
      }),
    /fails closed/,
  );
});

test("renders no Code Access credential values", () => {
  const desired = loadDesiredState(config, {
    ...disabledEnvironment,
    SRE_CODE_ACCESS_ENABLED: "true",
    SRE_CODE_ACCESS_GITHUB_APP_CLIENT_ID: "Iv1.example",
    SRE_CODE_ACCESS_PRIVATE_KEY_SECRET_URI: "https://vault.example/secrets/key",
    SRE_CODE_ACCESS_KEY_VAULT_MANAGED_IDENTITY_ID:
      "/subscriptions/example/identities/agent",
    SRE_CODE_ACCESS_REPOSITORY_URL: "https://github.com/example/repository",
  });
  const rendered = JSON.stringify(renderDesiredState(desired));
  assert.doesNotMatch(rendered, /vault\.example/);
  assert.doesNotMatch(rendered, /Iv1\.example/);
  assert.match(rendered, /Key Vault references from environment/);
});

test("builds the documented extended-agent envelope", () => {
  assert.deepEqual(
    buildExtendedBody("health", "ScheduledTask", { isEnabled: true }),
    {
      name: "health",
      type: "ScheduledTask",
      tags: ["contosopay-scenario-c"],
      properties: { isEnabled: true },
    },
  );
  assert.deepEqual(stableJson({ z: 1, a: { d: 2, b: 3 } }), {
    a: { b: 3, d: 2 },
    z: 1,
  });
  assert.equal(parseExplicitBoolean("true", "setting"), true);
  assert.throws(() => parseExplicitBoolean("", "setting"), /explicitly set/);
});

test("detects drift while allowing service-populated properties", () => {
  assert.equal(
    desiredSubsetMatches(
      {
        name: "health",
        properties: { isEnabled: true, provisioningState: "Succeeded" },
      },
      { name: "health", properties: { isEnabled: true } },
    ),
    true,
  );
  assert.equal(
    desiredSubsetMatches(
      { name: "health", properties: { isEnabled: false } },
      { name: "health", properties: { isEnabled: true } },
    ),
    false,
  );
});
