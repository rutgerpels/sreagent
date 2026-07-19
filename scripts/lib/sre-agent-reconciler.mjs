import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const API_VERSION = "2025-05-01-preview";
const DATA_PLANE_RESOURCE = "https://azuresre.dev";
const RETRYABLE_STATUS = new Set([403, 409, 429, 500, 502, 503, 504]);
const MANAGED_TAG = "contosopay-scenario-c";

function readJson(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

export function parseExplicitBoolean(value, name) {
  if (value === "true" || value === true) return true;
  if (value === "false" || value === false) return false;
  throw new Error(`${name} must be explicitly set to true or false.`);
}

export function buildExtendedBody(name, type, properties) {
  return { name, type, tags: [MANAGED_TAG], properties };
}

export function stableJson(value) {
  if (Array.isArray(value)) return value.map(stableJson);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, item]) => [key, stableJson(item)]),
    );
  }
  return value;
}

export function desiredSubsetMatches(actual, desired) {
  if (Array.isArray(desired)) {
    return (
      Array.isArray(actual) &&
      JSON.stringify(stableJson(actual)) === JSON.stringify(stableJson(desired))
    );
  }
  if (desired && typeof desired === "object") {
    return (
      actual !== null &&
      typeof actual === "object" &&
      Object.entries(desired).every(([key, value]) =>
        desiredSubsetMatches(actual[key], value),
      )
    );
  }
  return actual === desired;
}

export function loadDesiredState(configDirectory, environment = process.env) {
  const directory = resolve(configDirectory);
  const manifest = readJson(resolve(directory, "manifest.json"));
  if (manifest.schemaVersion !== 1) {
    throw new Error(
      `Unsupported Scenario C manifest schema: ${manifest.schemaVersion}`,
    );
  }

  const permissions = readJson(
    resolve(directory, manifest.toolPermissionsFile),
  );
  if (!permissions.permissions) {
    throw new Error(
      "The tool-permissions document must contain a permissions object.",
    );
  }

  const subagents = manifest.subagents.map((item) => ({
    name: item.name,
    properties: {
      ...item.properties,
      instructions: readFileSync(
        resolve(directory, item.instructionsFile),
        "utf8",
      ).trim(),
    },
  }));

  const knowledge = manifest.knowledge.map((item) => ({
    ...item,
    content: readFileSync(resolve(directory, item.path)),
  }));

  const codeAccessEnabled = parseExplicitBoolean(
    environment.SRE_CODE_ACCESS_ENABLED,
    "SRE_CODE_ACCESS_ENABLED",
  );
  let codeAccess = {
    enabled: false,
    domain: manifest.codeAccess.domain,
    repositoryName: manifest.codeAccess.repositoryName,
  };
  if (codeAccessEnabled) {
    const required = {
      clientId: environment.SRE_CODE_ACCESS_GITHUB_APP_CLIENT_ID,
      privateKeySecretUri: environment.SRE_CODE_ACCESS_PRIVATE_KEY_SECRET_URI,
      keyVaultManagedIdentityId:
        environment.SRE_CODE_ACCESS_KEY_VAULT_MANAGED_IDENTITY_ID,
      repositoryUrl: environment.SRE_CODE_ACCESS_REPOSITORY_URL,
    };
    const missing = Object.entries(required)
      .filter(([, value]) => !value)
      .map(([key]) => key);
    if (missing.length > 0) {
      throw new Error(
        `Code Access is enabled but missing: ${missing.join(", ")}.`,
      );
    }
    codeAccess = {
      enabled: true,
      domain: manifest.codeAccess.domain,
      repositoryName: manifest.codeAccess.repositoryName,
      ...required,
    };
  }

  const remediationConnectorEnabled = parseExplicitBoolean(
    environment.SRE_REMEDIATION_CONNECTOR_ENABLED,
    "SRE_REMEDIATION_CONNECTOR_ENABLED",
  );
  if (remediationConnectorEnabled) {
    throw new Error(
      "Remote Streamable-HTTP MCP supports bearer/custom-header authentication, " +
        "not the required managed-identity token flow. The remediation connector fails closed.",
    );
  }

  return {
    expectedAgent: manifest.expectedAgent,
    permissions: permissions.permissions,
    subagents,
    incidentFilters: manifest.incidentFilters,
    scheduledTasks: manifest.scheduledTasks,
    knowledge,
    codeAccess,
  };
}

export function renderDesiredState(desired) {
  return {
    expectedAgent: desired.expectedAgent,
    permissions: desired.permissions,
    subagents: desired.subagents,
    incidentFilters: desired.incidentFilters,
    scheduledTasks: desired.scheduledTasks,
    knowledge: desired.knowledge.map(({ content, ...item }) => ({
      ...item,
      bytes: content.byteLength,
    })),
    codeAccess: desired.codeAccess.enabled
      ? {
          domain: desired.codeAccess.domain,
          repositoryName: desired.codeAccess.repositoryName,
          repositoryUrl: desired.codeAccess.repositoryUrl,
          authType: "GitHubApp",
          credentials: "<Key Vault references from environment>",
        }
      : { enabled: false },
    remediationConnector: {
      enabled: false,
      reason:
        "Managed identity is not supported for remote Streamable-HTTP MCP authentication.",
    },
  };
}

function az(argumentsList) {
  const result = spawnSync("az", argumentsList, {
    encoding: "utf8",
    shell: false,
    windowsHide: true,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(result.stderr.trim() || `az ${argumentsList[0]} failed.`);
  }
  return result.stdout.trim();
}

function armGet(url) {
  return JSON.parse(
    az(["rest", "--method", "GET", "--url", url, "--output", "json"]),
  );
}

function dataPlaneToken() {
  return az([
    "account",
    "get-access-token",
    "--resource",
    DATA_PLANE_RESOURCE,
    "--query",
    "accessToken",
    "--output",
    "tsv",
  ]);
}

function sleep(milliseconds) {
  return new Promise((accept) => setTimeout(accept, milliseconds));
}

async function request(url, token, options = {}) {
  const method = options.method ?? "GET";
  const allowed = new Set(options.allowedStatuses ?? []);
  for (let attempt = 1; attempt <= 8; attempt += 1) {
    const response = await fetch(url, {
      method,
      headers: {
        Authorization: `Bearer ${token}`,
        ...(options.body === undefined
          ? {}
          : { "Content-Type": "application/json" }),
        ...options.headers,
      },
      body:
        options.body === undefined ? undefined : JSON.stringify(options.body),
      signal: AbortSignal.timeout(60_000),
    });
    if (response.ok || allowed.has(response.status)) return response;
    if (RETRYABLE_STATUS.has(response.status) && attempt < 8) {
      await sleep(Math.min(attempt * 5_000, 30_000));
      continue;
    }
    const message = (await response.text()).slice(0, 500);
    throw new Error(
      `${method} ${new URL(url).pathname} failed (${response.status}): ${message}`,
    );
  }
  throw new Error(`${method} ${url} exhausted retries.`);
}

function agentArmUrl(subscription, resourceGroup, agentName, suffix = "") {
  return (
    `https://management.azure.com/subscriptions/${encodeURIComponent(subscription)}` +
    `/resourceGroups/${encodeURIComponent(resourceGroup)}` +
    `/providers/Microsoft.App/agents/${encodeURIComponent(agentName)}` +
    `${suffix}?api-version=${API_VERSION}`
  );
}

function assertAgent(agent, expected) {
  const properties = agent.properties ?? {};
  const failures = [];
  if (properties.provisioningState !== "Succeeded")
    failures.push("provisioningState");
  if (properties.actionConfiguration?.accessLevel !== expected.accessLevel)
    failures.push("accessLevel");
  if (properties.actionConfiguration?.mode !== expected.actionMode)
    failures.push("actionMode");
  if (
    properties.incidentManagementConfiguration?.type !==
    expected.incidentPlatform
  ) {
    failures.push("incidentPlatform");
  }
  if (expected.requireVnet && !properties.vnetConfiguration?.subnetResourceId)
    failures.push("vnet");
  if (!properties.agentEndpoint) failures.push("agentEndpoint");
  if (failures.length > 0) {
    throw new Error(
      `Agent control-plane verification failed: ${failures.join(", ")}.`,
    );
  }
}

async function putExtended(endpoint, token, kind, name, type, properties) {
  await request(
    `${endpoint}/api/v2/extendedAgent/${kind}/${encodeURIComponent(name)}`,
    token,
    {
      method: "PUT",
      body: buildExtendedBody(name, type, properties),
    },
  );
}

function collectionItems(payload) {
  if (Array.isArray(payload)) return payload;
  return payload.value ?? payload.items ?? payload.resources ?? [];
}

async function reconcileExtended(endpoint, token, kind, type, items) {
  const collectionUrl = `${endpoint}/api/v2/extendedAgent/${kind}`;
  const currentResponse = await request(collectionUrl, token);
  const currentItems = collectionItems(await currentResponse.json());
  const desiredNames = new Set(items.map((item) => item.name));
  for (const item of currentItems) {
    if (item.tags?.includes(MANAGED_TAG) && !desiredNames.has(item.name)) {
      await request(
        `${collectionUrl}/${encodeURIComponent(item.name)}`,
        token,
        {
          method: "DELETE",
          allowedStatuses: [404],
        },
      );
    }
  }
  for (const item of items) {
    await putExtended(endpoint, token, kind, item.name, type, item.properties);
  }
}

async function putPermissions(endpoint, token, permissions) {
  const url = `${endpoint}/api/v2/agent/settings/global`;
  const current = await request(url, token, { allowedStatuses: [404] });
  const headers =
    current.status === 404
      ? {}
      : { "If-Match": current.headers.get("etag") || "*" };
  const result = await request(url, token, {
    method: "PUT",
    headers,
    body: { permissions },
    allowedStatuses: [412],
  });
  if (result.status === 412) {
    const refreshed = await request(url, token);
    await request(url, token, {
      method: "PUT",
      headers: { "If-Match": refreshed.headers.get("etag") || "*" },
      body: { permissions },
    });
  }
}

async function uploadKnowledge(endpoint, token, item) {
  const encoded = encodeURIComponent(item.fileName);
  await request(`${endpoint}/api/v1/AgentMemory/document/${encoded}`, token, {
    method: "DELETE",
    allowedStatuses: [404],
  });
  const form = new FormData();
  form.append(
    "files",
    new Blob([item.content], { type: item.contentType }),
    item.fileName,
  );
  for (let attempt = 1; attempt <= 5; attempt += 1) {
    const response = await fetch(
      `${endpoint}/api/v1/AgentMemory/upload?triggerIndexing=true`,
      {
        method: "POST",
        headers: { Authorization: `Bearer ${token}` },
        body: form,
        signal: AbortSignal.timeout(120_000),
      },
    );
    if (response.ok) return;
    if (RETRYABLE_STATUS.has(response.status) && attempt < 5) {
      await sleep(attempt * 5_000);
      continue;
    }
    throw new Error(
      `Knowledge upload failed (${response.status}): ${(await response.text()).slice(0, 500)}`,
    );
  }
}

async function configureCodeAccess(endpoint, token, codeAccess) {
  const domain = codeAccess.domain.replaceAll(".", "_");
  if (!codeAccess.enabled) {
    await request(
      `${endpoint}/api/v2/repos/${encodeURIComponent(codeAccess.repositoryName)}`,
      token,
      {
        method: "DELETE",
        allowedStatuses: [404],
      },
    );
    await request(
      `${endpoint}/api/v2/github/domains/${encodeURIComponent(domain)}`,
      token,
      {
        method: "DELETE",
        allowedStatuses: [404],
      },
    );
    return;
  }
  await request(
    `${endpoint}/api/v2/github/domains/${encodeURIComponent(domain)}`,
    token,
    {
      method: "PUT",
      body: {
        authType: "GitHubApp",
        clientId: codeAccess.clientId,
        privateKeySecretUri: codeAccess.privateKeySecretUri,
        keyVaultManagedIdentityId: codeAccess.keyVaultManagedIdentityId,
      },
    },
  );
  await request(
    `${endpoint}/api/v2/repos/${encodeURIComponent(codeAccess.repositoryName)}`,
    token,
    {
      method: "PUT",
      body: {
        name: codeAccess.repositoryName,
        type: "CodeRepo",
        properties: {
          url: codeAccess.repositoryUrl,
          type: "GitHub",
        },
      },
    },
  );
}

async function verifyExtended(endpoint, token, kind, item) {
  const response = await request(
    `${endpoint}/api/v2/extendedAgent/${kind}/${encodeURIComponent(item.name)}`,
    token,
  );
  const actual = await response.json();
  const expected = buildExtendedBody(item.name, item.type, item.properties);
  if (!desiredSubsetMatches(actual, expected)) {
    throw new Error(
      `${kind}/${item.name} differs from declared desired state.`,
    );
  }
}

async function verifyPermissions(endpoint, token, permissions) {
  const response = await request(
    `${endpoint}/api/v2/agent/settings/global`,
    token,
  );
  const actual = (await response.json()).permissions;
  if (
    JSON.stringify(stableJson(actual)) !==
    JSON.stringify(stableJson(permissions))
  ) {
    throw new Error("Global tool permissions differ from the declared policy.");
  }
}

async function verifyCodeAccess(endpoint, token, codeAccess) {
  const domain = codeAccess.domain.replaceAll(".", "_");
  const domainResponse = await request(
    `${endpoint}/api/v2/github/domains/${encodeURIComponent(domain)}`,
    token,
    { allowedStatuses: [404] },
  );
  const repoResponse = await request(
    `${endpoint}/api/v2/repos/${encodeURIComponent(codeAccess.repositoryName)}`,
    token,
    { allowedStatuses: [404] },
  );
  if (!codeAccess.enabled) {
    if (domainResponse.status !== 404 || repoResponse.status !== 404) {
      throw new Error(
        "Code Access is disabled but GitHub domain or repository access remains.",
      );
    }
    return;
  }
  if (domainResponse.status === 404 || repoResponse.status === 404) {
    throw new Error(
      "Code Access is enabled but its GitHub domain or repository is missing.",
    );
  }
  const repository = await repoResponse.json();
  if (
    !desiredSubsetMatches(repository, {
      name: codeAccess.repositoryName,
      properties: { url: codeAccess.repositoryUrl, type: "GitHub" },
    })
  ) {
    throw new Error(
      "Code Access repository differs from declared desired state.",
    );
  }
  await request(
    `${endpoint}/api/v2/repos/${encodeURIComponent(codeAccess.repositoryName)}/test`,
    token,
    {
      method: "POST",
    },
  );
}

async function verifyKnowledge(endpoint, token, knowledge) {
  for (let attempt = 1; attempt <= 12; attempt += 1) {
    const [statusResponse, indexerResponse] = await Promise.all([
      request(`${endpoint}/api/v1/AgentMemory/status`, token),
      request(`${endpoint}/api/v1/AgentMemory/indexer-status`, token),
    ]);
    const status = await statusResponse.json();
    const indexer = await indexerResponse.json();
    const serialized = JSON.stringify({ status, indexer });
    const failed = /"status"\s*:\s*"(failed|error)"/i.test(serialized);
    const allPresent = knowledge.every((item) =>
      serialized.includes(item.fileName),
    );
    if (!failed && allPresent) return;
    if (failed) throw new Error("Knowledge indexing reported a failed state.");
    if (attempt < 12) await sleep(10_000);
  }
  throw new Error(
    "Knowledge verification timed out before all declared files were indexed.",
  );
}

function verifyConnectors(
  subscription,
  resourceGroup,
  agentName,
  expectedNames,
) {
  const result = armGet(
    agentArmUrl(subscription, resourceGroup, agentName, "/connectors"),
  );
  const connectors = result.value ?? [];
  const byName = new Map(
    connectors.map((connector) => [connector.name, connector]),
  );
  const failures = [];
  for (const name of expectedNames) {
    const connector = byName.get(name);
    if (!connector) {
      failures.push(`${name}:missing`);
      continue;
    }
    const state = connector.properties?.provisioningState;
    if (!["Succeeded", "Running"].includes(state))
      failures.push(`${name}:${state ?? "unknown"}`);
  }
  if (failures.length > 0) {
    throw new Error(`Connector verification failed: ${failures.join(", ")}.`);
  }
}

export async function reconcileAgent(options, desired) {
  const armUrl = agentArmUrl(
    options.subscription,
    options.resourceGroup,
    options.agentName,
  );
  const agent = armGet(armUrl);
  assertAgent(agent, desired.expectedAgent);
  const endpointUrl = new URL(agent.properties.agentEndpoint);
  if (
    endpointUrl.protocol !== "https:" ||
    !endpointUrl.hostname.endsWith(".azuresre.ai") ||
    endpointUrl.username ||
    endpointUrl.password
  ) {
    throw new Error(
      "ARM returned an invalid Azure SRE Agent data-plane endpoint.",
    );
  }
  const endpoint = endpointUrl.origin;
  const token = dataPlaneToken();

  if (options.mode === "apply") {
    await putPermissions(endpoint, token, desired.permissions);
    await reconcileExtended(
      endpoint,
      token,
      "agents",
      "ExtendedAgent",
      desired.subagents,
    );
    await reconcileExtended(
      endpoint,
      token,
      "incidentFilters",
      "IncidentFilter",
      desired.incidentFilters,
    );
    await reconcileExtended(
      endpoint,
      token,
      "scheduledtasks",
      "ScheduledTask",
      desired.scheduledTasks,
    );
    for (const item of desired.knowledge)
      await uploadKnowledge(endpoint, token, item);
    await configureCodeAccess(endpoint, token, desired.codeAccess);
  }

  verifyConnectors(
    options.subscription,
    options.resourceGroup,
    options.agentName,
    desired.expectedAgent.connectors,
  );
  await verifyPermissions(endpoint, token, desired.permissions);
  for (const item of desired.subagents) {
    await verifyExtended(endpoint, token, "agents", {
      ...item,
      type: "ExtendedAgent",
    });
  }
  for (const item of desired.incidentFilters) {
    await verifyExtended(endpoint, token, "incidentFilters", {
      ...item,
      type: "IncidentFilter",
    });
  }
  for (const item of desired.scheduledTasks) {
    await verifyExtended(endpoint, token, "scheduledtasks", {
      ...item,
      type: "ScheduledTask",
    });
  }
  await verifyKnowledge(endpoint, token, desired.knowledge);
  await verifyCodeAccess(endpoint, token, desired.codeAccess);

  return {
    endpoint,
    mode: options.mode,
    codeAccessEnabled: desired.codeAccess.enabled,
    remediationConnectorEnabled: false,
  };
}
