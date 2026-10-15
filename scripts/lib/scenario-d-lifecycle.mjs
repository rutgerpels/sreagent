import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

export const API = {
  groups: '2025-04-01', deployments: '2025-04-01', network: '2024-05-01',
  dns: '2024-06-01', roles: '2022-04-01', agents: '2025-05-01-preview',
};
const ARM = 'https://management.azure.com';
const MC = '749f88d5-cbae-40b8-bcfc-e573ddc772fa';
const services = ['frontend', 'checkout-api', 'payment-service'];
const same = (a, b) => typeof a === 'string' && typeof b === 'string' && a.toLowerCase() === b.toLowerCase();
function requireThat(value, message) { if (!value) throw new Error(message); }
export function armGuid(...parts) {
  const ns = Buffer.from('11fb06fb712d4ddd98c7e71bbd588830', 'hex');
  const hash = createHash('sha1').update(ns).update(parts.join('-')).digest().subarray(0, 16);
  hash[6] = (hash[6] & 15) | 80; hash[8] = (hash[8] & 63) | 128;
  const s = hash.toString('hex');
  return `${s.slice(0,8)}-${s.slice(8,12)}-${s.slice(12,16)}-${s.slice(16,20)}-${s.slice(20)}`;
}
export function optionsFromEnv(env) {
  const options = {
    action: env.D_ACTION ?? 'deploy', prefix: env.D_PREFIX ?? 'payd',
    environment: env.D_ENVIRONMENT ?? 'demo', generation: env.D_GENERATION ?? 'bicep1',
    subscriptionId: env.AZURE_SUBSCRIPTION_ID, tenantId: env.AZURE_TENANT_ID,
    workloadLocation: env.D_WORKLOAD_LOCATION ?? 'swedencentral',
    observabilityLocation: env.D_OBSERVABILITY_LOCATION ?? 'westeurope',
    keyVaultZoneId: env.D_KEY_VAULT_ZONE_ID ?? '', acrZoneId: env.D_ACR_ZONE_ID ?? '',
    confirmation: env.D_CONFIRM_DESTROY ?? '', sha: env.GITHUB_SHA,
  };
  requireThat(['deploy', 'destroy'].includes(options.action), 'Action must be deploy or destroy.');
  requireThat(/^[a-z][a-z0-9]{1,7}$/.test(options.prefix), 'Prefix must be 2-8 lowercase alphanumeric characters.');
  for (const key of ['environment', 'generation']) requireThat(/^[a-z][a-z0-9-]{0,15}$/.test(options[key]), `Invalid ${key}.`);
  for (const key of ['subscriptionId', 'tenantId']) requireThat(/^[0-9a-f-]{36}$/i.test(options[key] ?? ''), `Missing/invalid ${key}.`);
  requireThat(options.workloadLocation === 'swedencentral' && options.observabilityLocation === 'westeurope', 'Approved D region profile is Sweden Central workloads/SRE and West Europe OBA+AMW.');
  options.profile = `${options.prefix}-${options.environment}-d`;
  options.deploymentName = `scenario-d-${options.profile}-${options.generation}`;
  if (options.action === 'destroy') requireThat(options.confirmation === options.deploymentName, `Destroy requires confirmation ${options.deploymentName}.`);
  else requireThat(/^[0-9a-f]{40}$/.test(options.sha ?? ''), 'Deploy requires full checkout commit SHA.');
  return options;
}
export function validateOwnership(o, options) {
  const sub = `/subscriptions/${options.subscriptionId}`;
  requireThat(o?.version === 1 && same(o.subscriptionId, options.subscriptionId), 'Ownership subscription/version mismatch.');
  requireThat(o.deploymentName === options.deploymentName && o.profile === options.profile && o.generation === options.generation, 'Ownership profile mismatch.');
  requireThat(/^d-[a-z0-9]{8}$/.test(o.stem), 'Invalid ownership stem.');
  const suffix = o.stem.slice(2);
  requireThat(o.resourceGroupName === `rg-${options.profile}-${suffix}`, 'Unexpected application RG.');
  const rg = `${sub}/resourceGroups/${o.resourceGroupName}`;
  requireThat(same(o.resourceGroupId, rg) && same(o.appVnetId, `${rg}/providers/Microsoft.Network/virtualNetworks/vnet-${o.stem}`), 'Unexpected owned resource paths.');
  requireThat(o.infrastructureResourceGroupName === `rg-${options.profile}-infra-${suffix}`, 'Unexpected infrastructure RG.');
  const runner = `${sub}/resourceGroups/agentrg-d/providers/Microsoft.Network/virtualNetworks/agent-vnet-d`;
  requireThat(same(o.runnerVnetId, runner) && same(o.runnerPeeringId, `${runner}/virtualNetworkPeerings/peer-runner-to-app-${o.stem}`), 'Unexpected retained runner/peering path.');
  requireThat(o.tags?.scenario === 'D' && o.tags?.managed_by === 'bicep' && o.tags?.lifecycle_owner === o.deploymentName && o.tags?.lifecycle_generation === o.generation, 'Ownership tags mismatch.');
  requireThat(o.workloadLocation === options.workloadLocation && o.observabilityLocation === options.observabilityLocation, 'Ownership location mismatch.');
  const identityIds = [`${rg}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-sre-${o.stem}`, `${rg}/providers/Microsoft.App/agents/sre-${options.prefix}-${o.stem}`];
  const roleDef = `${sub}/providers/Microsoft.Authorization/roleDefinitions/${MC}`;
  requireThat(o.externalRoles?.length === 2, 'Unexpected external grant count.');
  o.externalRoles.forEach((r, i) => requireThat(
    same(r.identityResourceId, identityIds[i]) && same(r.roleDefinitionId, roleDef) && same(r.scope, sub) &&
    same(r.id, `${sub}/providers/Microsoft.Authorization/roleAssignments/${armGuid(sub, identityIds[i], MC)}`) &&
    r.identityApiVersion === (i === 0 ? '2023-01-31' : API.agents), 'Unexpected external role assignment.'));
  const expectedLinks = [];
  for (const [key, zone, kind] of [['keyVaultZoneId', 'privatelink.vaultcore.azure.net', 'kv'], ['acrZoneId', 'privatelink.azurecr.io', 'acr']]) {
    requireThat(new RegExp(`^/subscriptions/${options.subscriptionId}/resourceGroups/[^/]+/providers/Microsoft.Network/privateDnsZones/${zone.replaceAll('.', '\\.')}$`, 'i').test(o[key]), 'Unexpected private DNS zone path.');
    if (!same(o[key].split('/')[4], o.resourceGroupName)) expectedLinks.push({ id: `${o[key]}/virtualNetworkLinks/app-${kind}-${o.stem}`, virtualNetworkId: o.appVnetId });
  }
  requireThat(JSON.stringify(o.sharedDnsLinks) === JSON.stringify(expectedLinks), 'Shared DNS link ownership mismatch.');
  const expectedDeployments = [
    { id: `${sub}/providers/Microsoft.Resources/deployments/${o.deploymentName}-roles` },
    { id: `${sub}/resourceGroups/agentrg-d/providers/Microsoft.Resources/deployments/runner-peering-${o.stem}` },
    ...expectedLinks.map(l => ({ id: `${sub}/resourceGroups/${l.id.split('/')[4]}/providers/Microsoft.Resources/deployments/dns-${l.id.includes('/app-kv-') ? 'kv' : 'acr'}-${o.stem}` })),
  ];
  requireThat(JSON.stringify(o.auxiliaryDeployments) === JSON.stringify(expectedDeployments), 'External deployment metadata ownership mismatch.');
  return o;
}
export function createIO(executeCommand) {
  const execute = executeCommand ?? ((program, args, json = false) => {
    const r = spawnSync(program, args, { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, timeout: 60 * 60 * 1000 });
    if (r.status !== 0 || r.error) {
      // Never log full CLI argv or stdout: they can contain telemetry credentials.
      const error = new Error(`${program} ${args[0]} ${args[1] ?? ''} failed: ${r.error?.message ?? r.stderr?.trim() ?? r.status}`);
      error.stderr = r.stderr ?? ''; throw error;
    }
    return json ? JSON.parse(r.stdout || 'null') : r.stdout.trim();
  });
  const az = (args) => execute('az', [...args, '--only-show-errors', '--output', 'json'], true);
  const previewThenCreate = (scope, args) => {
    const preview = az(['deployment', scope, 'what-if', ...args, '--no-pretty-print']);
    requireThat(preview && preview.status === 'Succeeded' && !preview.error && !(preview.errors?.length), 'Deployment what-if did not succeed; create is forbidden.');
    // Print only resource IDs and change types, never resource properties or
    // values (even previews must not leak credentials into workflow logs).
    console.log(JSON.stringify({ preview: args[args.indexOf('--name') + 1], changes: (preview.changes ?? []).map(({ resourceId, changeType }) => ({ resourceId, changeType })) }));
    return az(['deployment', scope, 'create', ...args]);
  };
  return {
    az, execute, sleep: delay,
    async get(id, api) {
      try { return az(['rest', '--method', 'GET', '--url', `${ARM}${id}?api-version=${api}`]); }
      catch (e) { if (/\((ResourceNotFound|ResourceGroupNotFound|ParentResourceNotFound|RoleAssignmentDoesNotExist|NotFound|DeploymentNotFound)\)|"code"\s*:\s*"(ResourceNotFound|ResourceGroupNotFound|ParentResourceNotFound|RoleAssignmentDoesNotExist|NotFound|DeploymentNotFound)"/.test(e.stderr)) return null; throw e; }
    },
    async remove(id, api) { az(['rest', '--method', 'DELETE', '--url', `${ARM}${id}?api-version=${api}`]); },
    async deploy(scope, name, template, parameters, location) {
      return withTemp((dir) => {
        const file = join(dir, 'parameters.json');
        writeFileSync(file, JSON.stringify({ parameters: Object.fromEntries(Object.entries(parameters).map(([k,v]) => [k, { value: v }])) }), { mode: 0o600 });
        return previewThenCreate(scope === 'subscription' ? 'sub' : 'group', ['--name', name,
          ...(scope === 'subscription' ? ['--location', location] : ['--resource-group', scope]),
          '--template-file', resolve(template), '--parameters', `@${file}`]).properties.outputs;
      });
    },
    async ledger(o, cleanup) {
      return withTemp((dir) => {
        const file = join(dir, 'ledger.json');
        writeFileSync(file, JSON.stringify({ '$schema': 'https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#', contentVersion: '1.0.0.0', resources: [], outputs: { ownership: { type: 'object', value: o }, cleanup: { type: 'object', value: cleanup } } }), { mode: 0o600 });
        return previewThenCreate('sub', ['--name', o.deploymentName, '--location', o.workloadLocation, '--template-file', file]).properties.outputs;
      });
    },
    async checkout(url) {
      const r = await fetch(`${url}/api/checkout`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ amount: 42, currency: 'EUR' }), signal: AbortSignal.timeout(30000) });
      requireThat(r.ok, `Checkout health verification returned HTTP ${r.status}.`);
      const body = await r.json(); requireThat(body.status === 'confirmed' && body.amount === 42 && body.currency === 'EUR' && body.payment?.status === 'approved', 'Checkout did not report success.');
    },
  };
}
async function withTemp(callback) { const dir = mkdtempSync(join(tmpdir(), 'scenario-d-')); try { return await callback(dir); } finally { rmSync(dir, { recursive: true, force: true }); } }
export async function retry(io, description, action, attempts = 20, milliseconds = 15000) {
  for (let i = 1; i <= attempts; i++) {
    try { return await action(); } catch (e) {
      if (i === attempts) throw new Error(`${description} failed after ${attempts} bounded attempts: ${e.message}`);
      (io.log ?? console.log)(`${description}: waiting for propagation (${i}/${attempts}).`);
      await io.sleep(milliseconds);
    }
  }
}
async function listAll(io, url) {
  const items = [];
  while (url) { const page = io.az(['rest', '--method', 'GET', '--url', url]); items.push(...page.value); url = page.nextLink; }
  return items;
}
async function findZone(io, options, runnerId, name, supplied) {
  const sub = `/subscriptions/${options.subscriptionId}`;
  const zones = await listAll(io, `${ARM}${sub}/providers/Microsoft.Network/privateDnsZones?api-version=${API.dns}`);
  const matches = [];
  for (const zone of zones.filter(z => z.name === name)) {
    const links = await listAll(io, `${ARM}${zone.id}/virtualNetworkLinks?api-version=${API.dns}`);
    if (links.some(l => same(l.properties.virtualNetwork.id, runnerId))) matches.push(zone.id);
  }
  requireThat(matches.length <= 1, `Ambiguous runner DNS namespace ${name}.`);
  if (supplied) requireThat(matches.length === 1 && same(matches[0], supplied), `Supplied ${name} zone must already be linked to retained runner.`);
  return matches[0] ?? '';
}
export async function validateResumeDns(io, o, key, kind, discoveredZoneId) {
  const zoneId = o[key];
  const owned = same(zoneId.split('/')[4], o.resourceGroupName);
  if (!owned) {
    requireThat(same(discoveredZoneId, zoneId), 'Reused external runner private DNS association is missing or changed.');
    return;
  }
  // The ledger/RG can exist before foundations creates either zone or link.
  // Missing OWNED associations are resumable; an association to another zone
  // must never be replaced. Existing owned objects must still be ours.
  requireThat(!discoveredZoneId || same(discoveredZoneId, zoneId), 'Foreign runner private DNS association changed.');
  const zone = await io.get(zoneId, API.dns);
  if (!zone) {
    requireThat(!discoveredZoneId, 'Discovered owned DNS association has no verifiable zone.');
    return;
  }
  const checkTags = (resource) => {
    for (const tag of ['scenario', 'managed_by', 'lifecycle_owner', 'lifecycle_generation']) {
      requireThat(resource.tags?.[tag] === o.tags[tag], 'Owned private DNS zone/link tags mismatch.');
    }
  };
  checkTags(zone);
  const links = await listAll(io, `${ARM}${zoneId}/virtualNetworkLinks?api-version=${API.dns}`);
  for (const link of links) {
    const runner = same(link.id, `${zoneId}/virtualNetworkLinks/runner-${kind}-${o.stem}`);
    const app = same(link.id, `${zoneId}/virtualNetworkLinks/app-${kind}-${o.stem}`);
    requireThat(runner || app, 'Unexpected foreign link in owned private DNS zone.');
    checkTags(link);
    requireThat(same(link.properties?.virtualNetwork?.id, runner ? o.runnerVnetId : o.appVnetId), 'Owned private DNS link target mismatch.');
  }
}
function outputValue(outputs, name) { requireThat(outputs?.[name]?.value !== undefined, `Missing deployment output ${name}.`); return outputs[name].value; }
async function verifyTags(io, o) {
  const group = await io.get(o.resourceGroupId, API.groups);
  if (group) for (const key of ['scenario', 'managed_by', 'lifecycle_owner', 'lifecycle_generation']) requireThat(group.tags?.[key] === o.tags[key], `Application RG ${key} ownership mismatch.`);
  return group;
}
export async function destroy(io, o, priorCleanup = null) {
  const group = await verifyTags(io, o);
  const principals = {};
  // Read all fresh principals and external resources before making ANY delete.
  for (const r of o.externalRoles) {
    const identity = await io.get(r.identityResourceId, r.identityApiVersion);
    const fresh = identity?.identity?.principalId ?? identity?.properties?.principalId;
    const role = await io.get(r.id, API.roles);
    const saved = priorCleanup?.principals?.[r.id];
    if (fresh && saved) requireThat(same(fresh, saved), 'Fresh principal disagrees with cleanup ledger.');
    const principal = fresh ?? saved;
    if (role) {
      requireThat(principal, 'External grant remains but principal cannot be verified. Stop for manual review.');
      requireThat(same(role.properties.principalId, principal) && same(role.properties.roleDefinitionId, r.roleDefinitionId) && same(role.properties.scope, r.scope), 'External role ownership mismatch.');
    }
    if (principal) principals[r.id] = principal;
  }
  const peering = await io.get(o.runnerPeeringId, API.network);
  if (peering) requireThat(same(peering.properties.remoteVirtualNetwork.id, o.appVnetId), 'Runner peering target mismatch.');
  const links = [];
  for (const l of o.sharedDnsLinks) {
    const link = await io.get(l.id, API.dns);
    if (link) {
      requireThat(same(link.properties.virtualNetwork.id, o.appVnetId) && link.tags?.lifecycle_owner === o.deploymentName, 'Shared DNS link ownership mismatch.'); links.push(l);
    }
  }
  // Save a verified snapshot in Azure deployment history, not runner-local state.
  // Restart after identities/RG disappear can still validate exact stale grants.
  await io.ledger(o, { principals });
  for (const r of o.externalRoles) await deleteAndVerify(io, r.id, API.roles);
  if (peering) await deleteAndVerify(io, o.runnerPeeringId, API.network);
  // Delete workload RG first; private endpoint zone groups clean their A records.
  // Never delete shared private DNS zones or retained runner/state resources.
  if (group) io.az(['group', 'delete', '--name', o.resourceGroupName, '--yes', '--no-wait']);
  await waitAbsent(io, o.resourceGroupId, API.groups, 120);
  for (const l of links) await deleteAndVerify(io, l.id, API.dns);
  await waitAbsent(io, `/subscriptions/${o.subscriptionId}/resourceGroups/${o.infrastructureResourceGroupName}`, API.groups, 40);
  for (const r of o.externalRoles) requireThat(!(await io.get(r.id, API.roles)), 'Grant still present after destroy.');
  requireThat(!(await io.get(o.runnerPeeringId, API.network)), 'Runner peering still present.');
  for (const l of o.sharedDnsLinks) requireThat(!(await io.get(l.id, API.dns)), 'Shared DNS app link still present.');
  for (const d of o.auxiliaryDeployments) await deleteAndVerify(io, d.id, API.deployments);
  // Ledger is removed LAST, only after verified actual absence, never on timeout.
  await deleteAndVerify(io, `/subscriptions/${o.subscriptionId}/providers/Microsoft.Resources/deployments/${o.deploymentName}`, API.deployments);
  console.log('Scenario D workload and exact external grants/links removed. Runner, DNS zones, and shared state retained.');
}
async function waitAbsent(io, id, api, attempts = 20) {
  await retry(io, 'Deletion verification', async () => requireThat(!(await io.get(id, api)), `Resource still exists: ${id}`), attempts);
}
async function deleteAndVerify(io, id, api) { if (await io.get(id, api)) await io.remove(id, api); await waitAbsent(io, id, api); }
export async function deploy(io, options, existing) {
  requireThat(io.execute('git', ['rev-parse', 'HEAD']) === options.sha, 'Checkout HEAD does not match immutable image SHA.');
  requireThat(io.execute('git', ['status', '--porcelain']).length === 0, 'Dirty checkout cannot be published under a commit SHA.');
  const sub = `/subscriptions/${options.subscriptionId}`;
  const runnerId = `${sub}/resourceGroups/agentrg-d/providers/Microsoft.Network/virtualNetworks/agent-vnet-d`;
  const kvZone = await findZone(io, options, runnerId, 'privatelink.vaultcore.azure.net', options.keyVaultZoneId);
  const acrZone = await findZone(io, options, runnerId, 'privatelink.azurecr.io', options.acrZoneId);
  let o;
  if (existing) {
    o = validateOwnership(outputValue(existing.properties.outputs, 'ownership'), options);
    requireThat(!existing.properties.outputs.cleanup, 'A cleanup snapshot exists; finish destroy before redeploy.');
    requireThat(await verifyTags(io, o), 'Owned RG is absent; complete destroy ledger cleanup first.');
    await validateResumeDns(io, o, 'keyVaultZoneId', 'kv', kvZone);
    await validateResumeDns(io, o, 'acrZoneId', 'acr', acrZone);
  } else {
    const groups = io.az(['group', 'list']);
    requireThat(!groups.some(g => (g.tags?.scenario === 'D' && g.name !== 'agentrg-d') || g.name.startsWith(`rg-${options.profile}-`)), 'Another Scenario D workload exists; finish its owner lifecycle first.');
    const outputs = await io.deploy('subscription', options.deploymentName, 'infra/scenario-d/main.bicep', {
      prefix: options.prefix, environment: options.environment, generation: options.generation,
      workloadLocation: options.workloadLocation, observabilityLocation: options.observabilityLocation,
      keyVaultZoneId: kvZone, acrZoneId: acrZone,
    }, options.workloadLocation);
    o = validateOwnership(outputValue(outputs, 'ownership'), options);
  }
  const access = io.az(['account', 'get-access-token', '--resource', ARM]);
  const claims = JSON.parse(Buffer.from(access.accessToken.split('.')[1], 'base64url').toString());
  requireThat(claims.oid && same(claims.tid, options.tenantId), 'Cannot identify deployment service principal.');
  const deployerPrincipalId = claims.oid;
  console.log('Deploying private foundations.');
  const f = outputValue(await io.deploy(o.resourceGroupName, 'scenario-d-foundations', 'infra/scenario-d/foundations.bicep', { ownership: o, deployerPrincipalId }), 'foundations');
  // RBAC and private DNS may converge independently. Probe the actual endpoints;
  // no public-network toggles or authentication fallbacks are permitted.
  await retry(io, 'Private ACR login', async () => { io.execute('az', ['acr', 'login', '--name', f.acrName, '--only-show-errors']); });
  const ai = await io.get(f.appInsightsId, '2020-02-02');
  requireThat(ai.properties.DisableLocalAuth === true, 'Application Insights local auth must stay disabled.');
  await withTemp((dir) => {
    const file = join(dir, 'connection-string');
    writeFileSync(file, ai.properties.ConnectionString, { mode: 0o600 });
    return retry(io, 'Private Key Vault secret write', async () => io.az(['keyvault', 'secret', 'set', '--vault-name', f.keyVaultName, '--name', 'appinsights-connection-string', '--file', file]));
  });
  // Build from CURRENT checked out source and reuse only locked SHA manifests.
  console.log('Building and publishing immutable checkout images on the private runner.');
  const digests = await withTemp(async (dir) => {
    const file = join(dir, 'digests.json');
    io.execute('bash', ['scripts/publish-immutable-images.sh', f.acrName, f.acrLoginServer, options.sha, file, ...services]);
    const { readFileSync } = await import('node:fs'); return JSON.parse(readFileSync(file, 'utf8'));
  });
  for (const s of services) requireThat(/^sha256:[0-9a-f]{64}$/.test(digests[s] ?? ''), `Invalid image digest for ${s}.`);
  console.log('Smoke-testing all three checkout containers before Azure app deployment.');
  io.execute('bash', ['scripts/tests/scenario-d-container-smoke.sh', f.acrLoginServer, options.sha]);
  // A bounded pause covers the three app-identity role assignments (app revision
  // deployment itself must fail, not relax auth, if convergence is unsuccessful).
  await io.sleep(60000);
  console.log('Deploying healthy app revisions by digest.');
  const appOutputs = await io.deploy(o.resourceGroupName, 'scenario-d-apps', 'infra/scenario-d/apps.bicep', { ownership: o, foundations: f, imageDigests: digests });
  const frontendUrl = outputValue(appOutputs, 'frontendUrl');
  await retry(io, 'Real checkout health', async () => io.checkout(frontendUrl));
  console.log('Deploying Review-mode SRE and paused Observability Agent.');
  const agents = outputValue(await io.deploy(o.resourceGroupName, 'scenario-d-agents', 'infra/scenario-d/agents.bicep', { ownership: o, foundations: f, deployerPrincipalId,
    modelProvider: process.env.SRE_AGENT_MODEL_PROVIDER || 'MicrosoftFoundry', modelName: process.env.SRE_AGENT_MODEL_NAME || 'Automatic' }), 'agents');
  await io.deploy('subscription', `${o.deploymentName}-roles`, 'infra/scenario-d/external-roles.bicep', { ownership: o, actionPrincipalId: f.actionPrincipalId, systemPrincipalId: agents.systemPrincipalId }, o.workloadLocation);
  await io.sleep(60000);
  const alertOutputs = await io.deploy(o.resourceGroupName, 'scenario-d-connectors-alerts', 'infra/scenario-d/connectors-alerts.bicep', { ownership: o, foundations: f, sreName: agents.sreName });
  const paymentFailureAlertName = outputValue(alertOutputs, 'paymentFailureAlertName');
  requireThat(paymentFailureAlertName === `alert-payment-failures-${o.stem}`, 'Unexpected deployed payment alert name; refusing broad incident-filter reconciliation.');
  const reconcileArgs = ['scripts/reconcile-sre-agent.mjs', '--payment-failure-alert-name', paymentFailureAlertName, '--subscription', options.subscriptionId, '--resource-group', o.resourceGroupName, '--agent', agents.sreName, '--config', 'agent/scenario-d'];
  await retry(io, 'SRE data-plane reconciliation', async () => io.execute('node', [...reconcileArgs, '--mode', 'apply']), 12, 30000);
  io.execute('node', [...reconcileArgs, '--mode', 'verify']);
  await io.checkout(frontendUrl);
  console.log(JSON.stringify({ ownershipDeployment: o.deploymentName, resourceGroup: o.resourceGroupName, frontendUrl, ...agents, status: 'Healthy checkout; manual paired-agent dry-run ready. Autonomous OBA remains paused/unproven.' }, null, 2));
  return { ownership: o, frontendUrl, agents };
}
export async function run(options, io = createIO()) {
  const account = io.az(['account', 'show']);
  requireThat(same(account.id, options.subscriptionId) && same(account.tenantId, options.tenantId), 'Logged-in Azure account subscription/tenant mismatch.');
  const id = `/subscriptions/${options.subscriptionId}/providers/Microsoft.Resources/deployments/${options.deploymentName}`;
  const existing = await io.get(id, API.deployments);
  if (options.action === 'destroy') {
    if (!existing) {
      // No ledger is not success if this profile still has a tagged workload.
      requireThat(!io.az(['group', 'list']).some(g => g.tags?.lifecycle_owner === options.deploymentName || g.name.startsWith(`rg-${options.profile}-`)), 'Owned RG exists without durable ledger. Stop for manual review.');
      console.log('Ownership ledger absent; no owned workload RG remains. No mutation performed.'); return;
    }
    const o = validateOwnership(outputValue(existing.properties.outputs, 'ownership'), options);
    await destroy(io, o, existing.properties.outputs.cleanup?.value);
  } else await deploy(io, options, existing);
}
