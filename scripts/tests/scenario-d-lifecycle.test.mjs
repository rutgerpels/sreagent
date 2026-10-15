import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { optionsFromEnv, validateOwnership, armGuid, destroy, run, deploy, retry, createIO, validateResumeDns, refreshFederatedLogin, prepareObservability, verifyObservability, API } from '../lib/scenario-d-lifecycle.mjs';
import { loadDesiredState } from '../lib/sre-agent-reconciler.mjs';
import { resolve } from 'node:path';

const subId = '00000000-0000-0000-0000-000000000001';
const tenantId = '00000000-0000-0000-0000-000000000002';
const env = { AZURE_SUBSCRIPTION_ID: subId, AZURE_TENANT_ID: tenantId, GITHUB_SHA: 'a'.repeat(40) };
const options = optionsFromEnv(env);
const sub = `/subscriptions/${subId}`;
function ownership(shared = false) {
  const stem = 'd-abcdefgh'; const profile = 'payd-demo-d'; const rgName = `rg-${profile}-abcdefgh`;
  const rg = `${sub}/resourceGroups/${rgName}`;
  const appVnetId = `${rg}/providers/Microsoft.Network/virtualNetworks/vnet-${stem}`;
  const runner = `${sub}/resourceGroups/agentrg-d/providers/Microsoft.Network/virtualNetworks/agent-vnet-d`;
  const keyVaultZoneId = `${sub}/resourceGroups/${shared ? 'shared-dns' : rgName}/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net`;
  const acrZoneId = `${sub}/resourceGroups/${shared ? 'shared-dns' : rgName}/providers/Microsoft.Network/privateDnsZones/privatelink.azurecr.io`;
  const role = '749f88d5-cbae-40b8-bcfc-e573ddc772fa';
  return {
    version: 1, subscriptionId: subId, deploymentName: options.deploymentName, profile, generation: 'bicep1', stem,
    resourceGroupName: rgName, resourceGroupId: rg, infrastructureResourceGroupName: `rg-${profile}-infra-abcdefgh`,
    appVnetId, runnerVnetId: runner, runnerPeeringId: `${runner}/virtualNetworkPeerings/peer-runner-to-app-${stem}`,
    workloadLocation: 'swedencentral', observabilityLocation: 'westeurope', keyVaultZoneId, acrZoneId,
    tags: { scenario: 'D', managed_by: 'bicep', lifecycle_owner: options.deploymentName, lifecycle_generation: 'bicep1' },
    externalRoles: [`${rg}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-sre-${stem}`, `${rg}/providers/Microsoft.App/agents/sre-payd-${stem}`].map((id, i) => ({
      id: `${sub}/providers/Microsoft.Authorization/roleAssignments/${armGuid(sub, id, role)}`,
      identityResourceId: id, identityApiVersion: i === 0 ? '2023-01-31' : API.agents,
      roleDefinitionId: `${sub}/providers/Microsoft.Authorization/roleDefinitions/${role}`, scope: sub,
    })),
    sharedDnsLinks: shared ? [keyVaultZoneId, acrZoneId].map((id, i) => ({ id: `${id}/virtualNetworkLinks/app-${i ? 'acr' : 'kv'}-${stem}`, virtualNetworkId: appVnetId })) : [],
    auxiliaryDeployments: [
      { id: `${sub}/providers/Microsoft.Resources/deployments/${options.deploymentName}-roles` },
      { id: `${sub}/resourceGroups/agentrg-d/providers/Microsoft.Resources/deployments/runner-peering-${stem}` },
      ...(shared ? ['kv','acr'].map(kind => ({ id: `${sub}/resourceGroups/shared-dns/providers/Microsoft.Resources/deployments/dns-${kind}-${stem}` })) : []),
    ],
  };
}
function mock(o = ownership(true)) {
  const state = new Map(); const events = [];
  state.set(o.resourceGroupId, { tags: o.tags });
  state.set(`${sub}/providers/Microsoft.Resources/deployments/${o.deploymentName}`, {});
  o.externalRoles.forEach((r, i) => {
    const principalId = `principal-${i}`;
    state.set(r.identityResourceId, i === 1 ? { identity: { principalId } } : { properties: { principalId } });
    state.set(r.id, { properties: { principalId, roleDefinitionId: r.roleDefinitionId, scope: r.scope, principalType: 'ServicePrincipal' } });
  });
  state.set(o.runnerPeeringId, { properties: { remoteVirtualNetwork: { id: o.appVnetId } } });
  o.sharedDnsLinks.forEach(l => state.set(l.id, { tags: o.tags, properties: { virtualNetwork: { id: l.virtualNetworkId } } }));
  o.auxiliaryDeployments.forEach(d => state.set(d.id, {}));
  const io = {
    state, events, log: () => {}, sleep: async () => {},
    get: async (id, api) => { events.push(['get', id, api]); return state.get(id) ?? null; },
    remove: async (id) => { events.push(['delete', id]); state.delete(id); },
    ledger: async (owner, snapshot) => { events.push(['snapshot', snapshot]); io.snapshot = snapshot; },
    az: (args) => {
      events.push(['az', args]);
      if (args[0] === 'group' && args[1] === 'delete') {
        for (const id of state.keys()) if (id === o.resourceGroupId || id.startsWith(o.resourceGroupId + '/')) state.delete(id);
        return null;
      }
      if (args[0] === 'account' && args[1] === 'show') return { id: subId, tenantId };
      if (args[0] === 'group' && args[1] === 'list') return [];
      throw new Error(`Unexpected mock az ${args}`);
    },
  };
  return io;
}
test('request validation enforces explicit immutable D profile and destroy confirmation', () => {
  assert.equal(options.deploymentName, 'scenario-d-payd-demo-d-bicep1');
  for (const change of [{ D_PREFIX: 'contosopay' }, { D_GENERATION: '../outside' }, { D_WORKLOAD_LOCATION: 'francecentral' }, { GITHUB_SHA: 'latest' }, { D_ACTION: 'destroy' }]) {
    assert.throws(() => optionsFromEnv({ ...env, ...change }));
  }
  assert.equal(optionsFromEnv({ ...env, D_ACTION: 'destroy', D_CONFIRM_DESTROY: options.deploymentName }).action, 'destroy');
});
test('ARM guid uses deterministic UUIDv5 stable ownership, not identity lifetime', () => {
  assert.match(armGuid('scope', 'identity', 'role'), /^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  assert.equal(armGuid('scope', 'identity', 'role'), armGuid('scope', 'identity', 'role'));
  assert.notEqual(armGuid('scope', 'identity', 'role'), armGuid('other', 'identity', 'role'));
});
test('long GitHub deploy refreshes the same OIDC principal before acquiring the SRE audience', async () => {
  const environment = { GITHUB_ACTIONS: 'true', AZURE_CLIENT_ID: subId,
    ACTIONS_ID_TOKEN_REQUEST_URL: 'https://oidc.example/request?existing=value',
    ACTIONS_ID_TOKEN_REQUEST_TOKEN: 'ephemeral-request-credential' };
  const events = [];
  const io = {
    execute: (program, args) => { assert.equal(program, 'az'); events.push(['login', args]); },
    az: args => {
      events.push(['az', args]);
      return { accessToken: `header.${Buffer.from(JSON.stringify({ oid: 'deployer', tid: tenantId })).toString('base64url')}.signature` };
    },
  };
  const request = async (url, config) => {
    assert.equal(url.searchParams.get('audience'), 'api://AzureADTokenExchange');
    assert.equal(url.searchParams.get('existing'), 'value');
    assert.equal(config.headers.Authorization, 'Bearer ephemeral-request-credential');
    assert.equal(config.redirect, 'error');
    return { ok: true, json: async () => ({ value: 'fresh.claims.assertion' }) };
  };
  await refreshFederatedLogin(io, options, 'deployer', environment, request);
  assert.deepEqual(events.map(event => event[0]), ['login', 'az', 'az', 'az']);
  assert(events[0][1].includes('fresh.claims.assertion'));
  assert.equal(events.at(-1)[1].at(-1), 'https://azuresre.dev');
  events.length = 0;
  await refreshFederatedLogin(io, options, 'deployer', {}, request);
  assert.equal(events.length, 0, 'local operator authentication is not replaced');
  await assert.rejects(refreshFederatedLogin(io, options, 'other', environment, request), /changed the deployment identity/);
  await assert.rejects(refreshFederatedLogin(io, options, 'deployer', environment,
    async () => ({ ok: false, status: 403 })), /HTTP 403/);
  await assert.rejects(refreshFederatedLogin(io, options, 'deployer', { ...environment, ACTIONS_ID_TOKEN_REQUEST_TOKEN: '' }, request), /unavailable/);
});
test('durable ownership allows only exact D grants, retained runner peering and app links', () => {
  validateOwnership(ownership(), options); validateOwnership(ownership(true), options);
  for (const mutate of [o => o.subscriptionId = tenantId, o => o.resourceGroupName = 'agentrg-d', o => o.runnerPeeringId += '-other', o => o.externalRoles[0].id = o.externalRoles[1].id, o => o.sharedDnsLinks[0].id = o.keyVaultZoneId, o => o.auxiliaryDeployments[0].id = o.resourceGroupId]) {
    const o = ownership(true); mutate(o); assert.throws(() => validateOwnership(o, options));
  }
});
test('ownership tolerates CLI resourceGroup metadata but still rejects changed or additional paths', () => {
  const o = ownership(true);
  for (const item of [...o.sharedDnsLinks, ...o.auxiliaryDeployments]) {
    if (item.id.includes('/resourceGroups/')) item.resourceGroup = item.id.split('/')[4];
  }
  validateOwnership(o, options);
  for (const mutate of [
    value => value.sharedDnsLinks[0].virtualNetworkId = value.runnerVnetId,
    value => value.sharedDnsLinks.push(value.sharedDnsLinks[0]),
    value => value.auxiliaryDeployments[1].id = value.resourceGroupId,
    value => value.auxiliaryDeployments.push(value.auxiliaryDeployments[0]),
  ]) {
    const changed = structuredClone(o);
    mutate(changed);
    assert.throws(() => validateOwnership(changed, options));
  }
});
test('destroy reads fresh principals before deletion, persists snapshot and deletes ledger last', async () => {
  const o = ownership(true); const io = mock(o); await destroy(io, o);
  const firstDelete = io.events.findIndex(e => e[0] === 'delete');
  for (const r of o.externalRoles) assert(io.events.findIndex(e => e[0] === 'get' && e[1] === r.identityResourceId) < firstDelete);
  assert(io.events.findIndex(e => e[0] === 'snapshot') < firstDelete);
  const deletes = io.events.filter(e => e[0] === 'delete').map(e => e[1]);
  assert.equal(deletes.at(-1), `${sub}/providers/Microsoft.Resources/deployments/${o.deploymentName}`);
  for (const forbidden of [o.runnerVnetId, o.keyVaultZoneId, o.acrZoneId, `${sub}/resourceGroups/agentrg-d`, `${sub}/resourceGroups/rg-payd-tfstate`]) assert(!deletes.includes(forbidden));
  assert.equal(io.snapshot.principals[o.externalRoles[0].id], 'principal-0');
});
test('destroy fails closed on changed RG, role principal, peering or DNS-link ownership', async () => {
  for (const change of [
    (io,o) => io.state.set(o.resourceGroupId, { tags: { ...o.tags, managed_by: 'terraform' } }),
    (io,o) => io.state.get(o.externalRoles[0].id).properties.principalId = 'foreign',
    (io,o) => io.state.get(o.runnerPeeringId).properties.remoteVirtualNetwork.id = 'foreign',
    (io,o) => io.state.get(o.sharedDnsLinks[0].id).tags = { lifecycle_owner: 'foreign' },
  ]) {
    const o = ownership(true); const io = mock(o); change(io,o);
    await assert.rejects(destroy(io,o)); assert(!io.events.some(e => ['delete','snapshot'].includes(e[0])));
  }
});
test('restart after RG deletion uses verified Azure snapshot to clean stale exact grant', async () => {
  const o = ownership(); const io = mock(o);
  io.state.delete(o.resourceGroupId); o.externalRoles.forEach(r => io.state.delete(r.identityResourceId));
  await destroy(io, o, { principals: Object.fromEntries(o.externalRoles.map((r,i) => [r.id, `principal-${i}`])) });
  assert(!io.state.has(o.externalRoles[0].id));
});
test('unknown principal orphan is not treated as successful cleanup', async () => {
  const o = ownership(); const io = mock(o); io.state.delete(o.externalRoles[0].identityResourceId);
  await assert.rejects(destroy(io,o), /cannot be verified/); assert(!io.events.some(e => e[0] === 'delete'));
});
test('RG deletion timeout keeps ownership ledger and does not falsely succeed', async () => {
  const o = ownership(); const io = mock(o);
  io.az = args => { io.events.push(['az',args]); return null; }; // No actual RG removal.
  await assert.rejects(destroy(io,o), /bounded attempts/);
  assert(io.state.has(`${sub}/providers/Microsoft.Resources/deployments/${o.deploymentName}`));
});
test('managed infrastructure RG orphan keeps cleanup ledger', async () => {
  const o = ownership(); const io = mock(o);
  io.state.set(`${sub}/resourceGroups/${o.infrastructureResourceGroupName}`, {});
  await assert.rejects(destroy(io,o), /bounded attempts/);
  assert(io.state.has(`${sub}/providers/Microsoft.Resources/deployments/${o.deploymentName}`));
});
test('cleanup is idempotent if grants and owned links are already gone', async () => {
  const o = ownership(true); const io = mock(o);
  o.externalRoles.forEach(r => io.state.delete(r.id)); io.state.delete(o.runnerPeeringId); o.sharedDnsLinks.forEach(l => io.state.delete(l.id));
  await destroy(io,o); assert(!io.events.some(e => e[0] === 'delete' && /roleAssignments|virtualNetworkLinks|virtualNetworkPeerings/.test(e[1])));
});
test('account mismatch prevents every resource mutation', async () => {
  const io = mock(); io.az = () => ({ id: tenantId, tenantId });
  await assert.rejects(run(options, io), /subscription\/tenant mismatch/); assert.equal(io.events.length, 0);
});
test('bounded propagation retries fail visibly, never switch security policy', async () => {
  let count = 0; const io = { sleep: async () => {} };
  await assert.rejects(retry(io,'RBAC',async () => { count++; throw new Error('403'); },3,0), /3 bounded attempts/); assert.equal(count,3);
});
test('deleted role assignments are absent while authorization and transport failures remain errors', async () => {
  const roleId = `${sub}/providers/Microsoft.Authorization/roleAssignments/${subId}`;
  for (const stderr of [
    'ERROR: Not Found({"error":{"code":"RoleAssignmentNotFound","message":"The role assignment is not found."}})',
    'ERROR: (RoleAssignmentNotFound) The role assignment is not found.',
    'ERROR: (RoleAssignmentDoesNotExist) The role assignment does not exist.',
  ]) {
    const io = createIO(() => { throw Object.assign(new Error('Azure read failed'), { stderr }); });
    assert.equal(await io.get(roleId, API.roles), null);
  }
  for (const stderr of [
    'ERROR: (AuthorizationFailed) The client does not have authorization.',
    'ERROR: Connection reset while reading a role assignment.',
    'ERROR: (InvalidApiVersionParameter) Invalid API version.',
  ]) {
    const error = Object.assign(new Error('Azure read failed'), { stderr });
    const io = createIO(() => { throw error; });
    await assert.rejects(io.get(roleId, API.roles), candidate => candidate === error);
  }
});
test('checkout verification requires POST amount42 EUR and full confirmed payment chain', async () => {
  const original = globalThis.fetch;
  try {
    globalThis.fetch = async (url, request) => {
      assert.equal(url,'https://frontend.example/api/checkout'); assert.equal(request.method,'POST'); assert.deepEqual(JSON.parse(request.body), { amount:42,currency:'EUR' });
      return { ok:true, json:async () => ({status:'confirmed',amount:42,currency:'EUR',payment:{status:'approved'}}) };
    };
    await createIO().checkout('https://frontend.example');
    globalThis.fetch = async () => ({ ok:true,json:async () => ({status:'failed'}) });
    await assert.rejects(createIO().checkout('https://frontend.example'), /did not report success/);
  } finally { globalThis.fetch = original; }
});
for (const autonomous of [false, true]) test(`healthy staged deploy (autonomous=${autonomous}) publishes digests before apps, grants before connectors, reconciles and checks real checkout`, async () => {
  const o = autonomous ? autonomousOwnership() : ownership(); const io = mock(o);
  const opts = autonomous ? autonomousOptions : options;
  const fixture = autonomous ? installObservability(io, o) : null;
  if (autonomous) { io.state.delete(o.defaultSettings.id); io.state.delete(o.externalRoles[2].id); } const stages = []; let secretFile;
  const f = { acrName:'acrdabcdefgh', acrLoginServer:'acrdabcdefgh.azurecr.io', keyVaultName:'kv-d-abcdefgh', appInsightsId:o.resourceGroupId+'/providers/Microsoft.Insights/components/appi-d-abcdefgh', actionPrincipalId:'principal-0', ...(fixture?.f ?? {}) };
  io.az = args => {
    if (args[0] === 'rest') return { value: [] };
    if (args[0] === 'group') return [];
    if (args[0] === 'account') return {accessToken:`header.${Buffer.from(JSON.stringify({oid:'deployer',tid:tenantId})).toString('base64url')}.signature`};
    if (args[0] === 'keyvault') { secretFile = args[args.indexOf('--file')+1]; assert(existsSync(secretFile)); assert.equal(readFileSync(secretFile,'utf8'),'ephemeral-connection'); return {}; }
    throw new Error(`Unexpected ${args}`);
  };
  const get = io.get;
  io.get = async (id, api) => {
    if (id === f.appInsightsId) return { ...(fixture ? io.state.get(id) : {}), properties: { ...(fixture ? io.state.get(id).properties : {}), DisableLocalAuth:true, ConnectionString:'ephemeral-connection' } };
    return get(id, api);
  };
  io.deploy = async (scope,name,file,params,_location,beforeCreate) => {
    stages.push(name);
    if (beforeCreate) await beforeCreate();
    if (name.endsWith("-oba-role")) io.state.set(o.externalRoles[2].id, fixture.subscriptionRole);
    if (name.endsWith("-oba-settings")) io.state.set(o.defaultSettings.id, fixture.setting);
    if (file.endsWith('/main.bicep')) return {ownership:{value:o}};
    if (name === 'scenario-d-foundations') { assert.equal(params.notificationEmail, opts.notificationEmail); return {foundations:{value:f}}; }
    if (name === 'scenario-d-apps') { assert.match(params.imageDigests.frontend,/^sha256:/); return {frontendUrl:{value:'https://frontend.example'}}; }
    if (name === 'scenario-d-connectors-alerts') return {paymentFailureAlertName:{value:'alert-payment-failures-d-abcdefgh'}};
    if (name === 'scenario-d-agents') return {agents:{value:{sreName:'sre-payd-d-abcdefgh',systemPrincipalId:'principal-1'}}};
    return {};
  };
  io.execute = (program,args) => {
    if (program === 'git') return args[0] === 'rev-parse' ? options.sha : '';
    stages.push(program === 'bash' ? (args[0] === 'scripts/publish-immutable-images.sh' ? 'publish' : 'smoke') : args.includes('verify') ? 'verify' : program === 'node' ? 'reconcile' : 'acr-login');
    if (program === 'node') assert.deepEqual(args.slice(1,3), ['--payment-failure-alert-name', 'alert-payment-failures-d-abcdefgh']);
    if (program === 'bash' && args[0] === 'scripts/tests/scenario-d-container-smoke.sh') assert.deepEqual(args.slice(1), [f.acrLoginServer, options.sha]);
    if (program === 'bash' && args[0] === 'scripts/publish-immutable-images.sh') writeFileSync(args[4],JSON.stringify(Object.fromEntries(['frontend','checkout-api','payment-service'].map(s => [s,'sha256:'+'b'.repeat(64)]))));
  };
  io.checkout = async () => stages.push('checkout');
  io.refreshAuth = async () => stages.push('refresh-auth');
  await deploy(io,opts,null);
  if (autonomous) {
    assert(stages.indexOf(o.deploymentName) < stages.indexOf(o.deploymentName+"-oba-role"));
    assert(stages.indexOf(o.deploymentName+"-oba-settings") < stages.indexOf("scenario-d-agents"));
    assert(io.events.some(e => e[0] === "get" && e[2] === API.oba));
  }
  assert(stages.indexOf('publish') < stages.indexOf('smoke'));
  assert(stages.indexOf('smoke') < stages.indexOf('scenario-d-apps'));
  assert(stages.indexOf(options.deploymentName+'-roles') < stages.indexOf('scenario-d-connectors-alerts'));
  assert(stages.indexOf('scenario-d-connectors-alerts') < stages.indexOf('refresh-auth'));
  assert(stages.indexOf('refresh-auth') < stages.indexOf('reconcile'));
  assert(stages.indexOf('reconcile') < stages.indexOf('verify')); assert.equal(stages.at(-1),'checkout');
  assert(!existsSync(secretFile), 'ephemeral secret file removed only after awaited write');
  stages.length = 0;
  const execute = io.execute;
  io.execute = (program,args) => {
    if (program === 'bash' && args[0] === 'scripts/tests/scenario-d-container-smoke.sh') throw new Error('container smoke failed');
    return execute(program,args);
  };
  if (autonomous) io.state.delete(o.defaultSettings.id);
  await assert.rejects(deploy(io,opts,null), /container smoke failed/);
  assert(!stages.includes('scenario-d-apps'), 'failed container smoke must prevent Azure app deployment');
});
test('existing dispatch routes D to Bicep and gates Terraform jobs, preserving ABC', () => {
  for (const file of ['deploy','destroy']) {
    const text = readFileSync(`.github/workflows/${file}.yml`,'utf8').replaceAll('\r\n','\n');
    assert.match(text,/scenario-d-bicep:\s+if: \$\{\{ inputs.scenario == 'D' \}\}/);
    assert.match(text,/uses: \.\/\.github\/workflows\/scenario-d-bicep.yml/);
    assert(text.includes(`  ${file}:\n    if: \${{ inputs.scenario != 'D' }}`));
    assert(text.includes(`  ${file}:\n    if: `));
    assert.match(text,/terraform/);
  }
});
test('D security, paused OBA and narrowly scoped Review SRE defaults remain explicit', () => {
  const foundations = readFileSync('infra/scenario-d/foundations.bicep','utf8');
  const apps = readFileSync('infra/scenario-d/apps.bicep','utf8');
  const agents = readFileSync('infra/scenario-d/agents.bicep','utf8');
  for (const pattern of [/acrSku: 'Premium'/,/acrAdminUserEnabled: false/,/enableRbacAuthorization: true/,/enablePurgeProtection: true/,/DisableLocalAuth: true/,/disableLocalAuth: true/,/destination: 'azure-monitor'/,/10\.101\.0\.0\/16/]) assert.match(foundations,pattern);
  for (const pattern of [/ingressExternal: i == 0/,/ingressAllowInsecure: false/,/@\$\{imageDigests\[app\]\}/,/PAYMENT_FAILURE_MODE', value: 'off'/,/ENABLE_SLOW_LEAK', value: 'false'/,/keyVaultUrl:/,/TELEMETRY_MANAGED_IDENTITY_CLIENT_ID/]) assert.match(apps,pattern);
  assert.match(agents,/var autonomous = ownership\.\?observabilityAutonomous \?\? false/);
  assert.match(agents,/enabled: autonomous/); assert.match(agents,/isAutonomous: autonomous/); assert.match(agents,/mode: 'Review'/);
  assert.match(readFileSync('infra/scenario-d/main.bicep','utf8'), /param observabilityAutonomous bool = false/);
  assert.equal(options.observabilityAutonomous, false);
  const desired = loadDesiredState(resolve('agent/scenario-d'),{ SRE_PAYMENT_FAILURE_ALERT_NAME: 'alert-payment-failures-d-abcdefgh' });
  assert.equal(desired.incidentFilters[0].properties.isEnabled,true);
  assert.equal(desired.incidentFilters[0].properties.titleContains, 'alert-payment-failures-d-abcdefgh');
  assert.equal(desired.incidentFilters[0].properties.agentMode, 'Review'); assert.deepEqual(desired.scheduledTasks,[]);
  assert(desired.permissions.ask.includes('RunAzCliWriteCommands')); assert(!desired.permissions.allow.includes('RunAzCliWriteCommands'));
  for (const file of ['foundations','apps']) {
    const text = readFileSync(`infra/scenario-d/${file}.bicep`,'utf8');
    const refs = text.match(/br\/public:[^']+/g) ?? []; assert(refs.length);
    for (const ref of refs) assert.match(ref,/:\d+\.\d+\.\d+$/);
  }
});

test('dirty or mismatched checkout cannot publish a supposedly immutable SHA', async () => {
  for (const head of [false, true]) {
    const io = { execute: (_program,args) => args[0] === 'rev-parse' ? (head ? options.sha : 'wrong') : ' M dirty', az: () => { throw new Error('Azure must not be called'); } };
    await assert.rejects(deploy(io,options,null), /Checkout HEAD|Dirty checkout/);
  }
});


test('IO previews subscription/group Bicep with identical parameters before each create', async () => {
  for (const scope of ['subscription', 'rg-demo']) {
    const calls = []; let parameterFile;
    const io = createIO((program, args, json) => {
      assert.equal(program, 'az'); assert.equal(json, true);
      parameterFile = args[args.indexOf('--parameters') + 1].slice(1);
      assert.deepEqual(JSON.parse(readFileSync(parameterFile, 'utf8')), { parameters: { example: { value: 'same-parameter' } } });
      calls.push(args);
      return args[2] === 'what-if' ? { status: 'Succeeded', changes: [] } : { properties: { outputs: { result: { value: 'created' } } } };
    });
    const result = await io.deploy(scope, 'test-preview', 'infra/scenario-d/main.bicep', { example: 'same-parameter' }, 'swedencentral');
    assert.deepEqual(calls.map(a => a.slice(0,3)), [['deployment', scope === 'subscription' ? 'sub' : 'group', 'what-if'], ['deployment', scope === 'subscription' ? 'sub' : 'group', 'create']]);
    assert.deepEqual(calls[0].slice(3).filter(a => a !== '--no-pretty-print'), calls[1].slice(3));
    assert.equal(result.result.value, 'created'); assert(!existsSync(parameterFile));
  }
});
test('safe ledger metadata update also requires identical successful what-if before create', async () => {
  const calls = []; let templateFile;
  const o = ownership();
  const io = createIO((_program,args) => {
    templateFile = args[args.indexOf('--template-file') + 1];
    const template = JSON.parse(readFileSync(templateFile, 'utf8'));
    assert.deepEqual(template.resources, []); assert.deepEqual(template.outputs.ownership.value, o);
    assert.deepEqual(template.outputs.cleanup.value, { principals: {} });
    calls.push(args);
    return args[2] === 'what-if' ? { status:'Succeeded', changes:[] } : { properties:{ outputs:template.outputs } };
  });
  await io.ledger(o, { principals:{} });
  assert.deepEqual(calls.map(a => a[2]), ['what-if','create']);
  assert.deepEqual(calls[0].slice(3).filter(a => a !== '--no-pretty-print'), calls[1].slice(3));
  assert(!existsSync(templateFile));
});
test('what-if CLI or ARM failures forbid create and preserve cleanup resources', async () => {
  for (const failure of [null, { status:'Failed' }, { status:'Succeeded', error:{code:'Forbidden'} }, { status:'Succeeded', errors:[{code:'Denied'}] }, 'throw']) {
    for (const ledger of [false,true]) {
      const calls = []; let file;
      const previewIO = createIO((_program,args) => {
        calls.push(args); file = args[args.indexOf(ledger ? '--template-file' : '--parameters')+1].replace(/^@/,'');
        if (failure === 'throw') throw new Error('what-if CLI failed');
        return failure;
      });
      if (ledger) {
        const io = mock(); io.ledger = (o,snapshot) => previewIO.ledger(o,snapshot);
        await assert.rejects(destroy(io,ownership(true)), /what-if/);
        assert(!io.events.some(e => e[0] === 'delete' || (e[0] === 'az' && e[1][1] === 'delete')));
      } else await assert.rejects(previewIO.deploy('subscription','preview-failure','infra/scenario-d/main.bicep',{},'swedencentral'), /what-if/);
      assert.deepEqual(calls.map(a => a[2]), ['what-if']); assert(!existsSync(file));
    }
  }
});
test('enabled D SRE filter fails closed without exact payment alert and excludes unrelated Sev2', () => {
  const config = resolve('agent/scenario-d');
  for (const value of [undefined,'Sev2','alert-checkout-failures-d-abcdefgh','alert-payment-failures','alert-payment-failures-d-other']) {
    assert.throws(() => loadDesiredState(config,{SRE_PAYMENT_FAILURE_ALERT_NAME:value}), /exact deployed/);
  }
  const { incidentFilters } = loadDesiredState(config,{SRE_PAYMENT_FAILURE_ALERT_NAME:'alert-payment-failures-d-abcdefgh'});
  assert.equal(incidentFilters.length,1);
  const filter = incidentFilters[0].properties;
  assert.equal(filter.isEnabled,true); assert.equal(filter.agentMode,'Review'); assert.deepEqual(filter.priorities,['Sev2']);
  assert.equal(filter.titleContains,'alert-payment-failures-d-abcdefgh');
  for (const title of ['alert-checkout-failures-d-abcdefgh','alert-payment-failures-d-ijklmnop','Unrelated Sev2 incident']) assert(!title.includes(filter.titleContains));
  assert('Fired: alert-payment-failures-d-abcdefgh'.includes(filter.titleContains));
  assert(!('titleContainsEnvironmentVariable' in incidentFilters[0]), 'helper metadata never reaches service API');
});


function resumeMock(o, linkedKinds = [], existingZones = true) {
  const io = mock(o); io.foundationReached = false;
  io.execute = (_program,args) => args[0] === 'rev-parse' ? options.sha : '';
  for (const [key,kind] of [['keyVaultZoneId','kv'],['acrZoneId','acr']]) {
    if (existingZones) io.state.set(o[key], { id:o[key], name:o[key].split('/').at(-1), tags:{...o.tags} });
    if (linkedKinds.includes(kind)) io.state.set(`${o[key]}/virtualNetworkLinks/runner-${kind}-${o.stem}`, {
      id:`${o[key]}/virtualNetworkLinks/runner-${kind}-${o.stem}`, tags:{...o.tags}, properties:{virtualNetwork:{id:o.runnerVnetId}},
    });
  }
  io.az = args => {
    if (args[0] === 'rest') {
      const url = args[args.indexOf('--url')+1];
      if (url.includes('/virtualNetworkLinks?')) {
        const id = url.replace('https://management.azure.com','').split('?')[0];
        return {value:[...io.state.values()].filter(v => v.id?.startsWith(id+'/'))};
      }
      return {value:[o.keyVaultZoneId,o.acrZoneId].map(id => io.state.get(id)).filter(Boolean)};
    }
    if (args[0] === 'account') return {accessToken:`header.${Buffer.from(JSON.stringify({oid:'deployer',tid:tenantId})).toString('base64url')}.signature`};
    throw new Error(`Unexpected resume mock ${args}`);
  };
  io.deploy = async (_scope,name) => { assert.equal(name,'scenario-d-foundations'); io.foundationReached = true; throw new Error('foundation-redeploy reached'); };
  return io;
}
test('resume after main ledger but before both DNS links/one DNS link reruns foundations', async () => {
  const o = ownership();
  for (const [linkedKinds, existingZones] of [[[],false],[[],true],[['kv'],true],[['acr'],true]]) {
    const io = resumeMock(o,linkedKinds,existingZones);
    await assert.rejects(deploy(io,options,{properties:{outputs:{ownership:{value:o}}}}), /foundation-redeploy reached/);
    assert.equal(io.foundationReached,true);
  }
});
test('resume rejects foreign runner associations and altered owned zone/link ownership', async () => {
  const o = ownership();
  for (const [key,kind] of [['keyVaultZoneId','kv'],['acrZoneId','acr']]) {
    const foreign = `${sub}/resourceGroups/foreign/providers/Microsoft.Network/privateDnsZones/${o[key].split('/').at(-1)}`;
    await assert.rejects(validateResumeDns(resumeMock(o),o,key,kind,foreign), /Foreign runner/);
    const zoneMismatch = resumeMock(o); zoneMismatch.state.get(o[key]).tags.lifecycle_owner = 'foreign';
    await assert.rejects(validateResumeDns(zoneMismatch,o,key,kind,''), /tags mismatch/);
    const targetMismatch = resumeMock(o,[kind]);
    targetMismatch.state.get(`${o[key]}/virtualNetworkLinks/runner-${kind}-${o.stem}`).properties.virtualNetwork.id = 'foreign-vnet';
    await assert.rejects(validateResumeDns(targetMismatch,o,key,kind,''), /target mismatch/);
    const linkMismatch = resumeMock(o,[kind]);
    linkMismatch.state.get(`${o[key]}/virtualNetworkLinks/runner-${kind}-${o.stem}`).tags.lifecycle_owner = 'foreign';
    await assert.rejects(validateResumeDns(linkMismatch,o,key,kind,o[key]), /tags mismatch/);
  }
});
test('resume reused external zones requires strict still-existing runner association', async () => {
  const o = ownership(true);
  for (const [key,kind] of [['keyVaultZoneId','kv'],['acrZoneId','acr']]) {
    await validateResumeDns({},o,key,kind,o[key]);
    for (const discovered of ['',`${sub}/resourceGroups/foreign/providers/Microsoft.Network/privateDnsZones/${o[key].split('/').at(-1)}`]) {
      await assert.rejects(validateResumeDns({},o,key,kind,discovered), /external runner private DNS association is missing or changed/);
    }
  }
});
test('all D profiles share a global retained-runner concurrency boundary', () => {
  const workflow = readFileSync('.github/workflows/scenario-d-bicep.yml','utf8');
  assert.match(workflow,/group: scenario-d-private-runner-agentrg-d-agent-vnet-d/);
  assert(!workflow.includes('group: scenario-d-bicep-${{ inputs.prefix }}'));
});


const recipient = 'acceptance@example.invalid';
const autonomousOptions = optionsFromEnv({ ...env, D_OBSERVABILITY_AUTONOMOUS: 'true', D_NOTIFICATION_EMAIL: recipient });
function autonomousOwnership(shared = false) {
  const o = ownership(shared); o.version = 2; o.observabilityAutonomous = true;
  const identityResourceId = `${o.resourceGroupId}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-oba-${o.stem}`;
  const role = '43d0d8ad-25c7-4714-9337-8ba259a9fe05';
  o.externalRoles.push({ id: `${sub}/providers/Microsoft.Authorization/roleAssignments/${armGuid(sub,identityResourceId,role)}`,
    identityResourceId, identityApiVersion: API.identities, scope: sub, roleDefinitionId: `${sub}/providers/Microsoft.Authorization/roleDefinitions/${role}` });
  o.defaultSettings = { id: `${sub}/providers/Microsoft.Monitor/settings/default`, defaultAzureMonitorWorkspace: `${o.resourceGroupId}/providers/Microsoft.Monitor/accounts/amw-observability-${o.stem}` };
  o.auxiliaryDeployments.splice(2,0,...['oba-role','oba-settings'].map(stage => ({id:`${sub}/providers/Microsoft.Resources/deployments/${o.deploymentName}-${stage}`})));
  return o;
}
function installObservability(io, o) {
  const obaId = `${o.resourceGroupId}/providers/Microsoft.Monitor/observabilityAgents/oba-${o.stem}`;
  const f = { obaIdentityId: o.externalRoles[2].identityResourceId, obaPrincipalId: 'principal-2', amwId: o.defaultSettings.defaultAzureMonitorWorkspace };
  const aiId = `${o.resourceGroupId}/providers/Microsoft.Insights/components/appi-${o.stem}`;
  const groupId = `${o.resourceGroupId}/providers/Microsoft.Insights/actionGroups/ag-sre-${o.stem}`;
  const targetId = `${obaId}/monitoredResources/appi-${o.stem}`;
  const resource = properties => ({location:o.observabilityLocation, tags:{...o.tags}, properties});
  const instructions = `Always create an issue for alert-payment-failures-${o.stem}. Correlate cascading alert-checkout-failures-${o.stem} into that single issue for this resource group only. Investigate the payment-to-checkout failure chain independently; do not change workloads or perform mitigations.`;
  io.state.set(obaId, {...resource({ enabled:true, monitoringAccountId:f.amwId, operations:[{type:'IssueCreation',mode:'Auto',instructions},{type:'Investigation',mode:'Auto'}] }), identity:{type:'UserAssigned',userAssignedIdentities:{[f.obaIdentityId]:{}}}});
  io.state.set(f.obaIdentityId,resource({principalId:f.obaPrincipalId}));
  io.state.set(f.amwId,resource({publicNetworkAccess:'Enabled',actions:{defaultActionGroups:[{id:groupId}]}}));
  io.state.set(aiId,{...resource({DisableLocalAuth:true,WorkspaceResourceId:`${o.resourceGroupId}/providers/Microsoft.OperationalInsights/workspaces/law-${o.stem}`}),location:o.workloadLocation});
  io.state.set(groupId,resource({enabled:true,emailReceivers:[{name:'autonomous-acceptance',emailAddress:recipient,useCommonAlertSchema:true}]}));
  io.state.set(targetId,{properties:{enabled:true,isAutonomous:true,resourceId:aiId}});
  io.state.set(`${obaId}/monitoredResources`,{value:[{id:targetId}]});
  for (const [scope,role] of [[sub,'43d0d8ad-25c7-4714-9337-8ba259a9fe05'],[f.amwId,'749f88d5-cbae-40b8-bcfc-e573ddc772fa'],[aiId,'43d0d8ad-25c7-4714-9337-8ba259a9fe05']]) {
    io.state.set(`${scope}/providers/Microsoft.Authorization/roleAssignments/${armGuid(scope,f.obaIdentityId,role)}`,{properties:{scope,principalId:f.obaPrincipalId,principalType:'ServicePrincipal',roleDefinitionId:`${sub}/providers/Microsoft.Authorization/roleDefinitions/${role}`}});
  }
  const setting = {properties:{defaultAzureMonitorWorkspace:f.amwId}};
  io.state.set(o.defaultSettings.id,setting);
  return { f, obaId, aiId, groupId, targetId, setting, subscriptionRole:io.state.get(o.externalRoles[2].id) };
}
test('autonomous flag is strict, recipient is single/valid/private, and Down never needs it', async () => {
  for (const value of ['', 'TRUE', 'False', '1', true, null]) assert.throws(() => optionsFromEnv({...env,D_OBSERVABILITY_AUTONOMOUS:value}));
  for (const value of [undefined, '', 'not-email', 'x@y', 'x@example.invalid,y@example.invalid', 'x@example.invalid\n', 'x@-example.invalid', '.x@example.invalid', 'x..y@example.invalid', 'x'.repeat(65)+'@example.invalid']) {
    assert.throws(() => optionsFromEnv({...env,D_OBSERVABILITY_AUTONOMOUS:'true',D_NOTIFICATION_EMAIL:value}), /single D_NOTIFICATION_EMAIL/);
  }
  assert.equal(autonomousOptions.notificationEmail,recipient);
  assert.equal(optionsFromEnv({...env,D_NOTIFICATION_EMAIL:recipient}).notificationEmail,'');
  for (const flag of ['true','false']) assert.equal(optionsFromEnv({...env,D_ACTION:'destroy',D_CONFIRM_DESTROY:options.deploymentName,D_OBSERVABILITY_AUTONOMOUS:flag}).notificationEmail,'');
  await assert.rejects(deploy({}, {...autonomousOptions,notificationEmail:''}, null), /single D_NOTIFICATION_EMAIL/);
  await assert.rejects(run({...autonomousOptions,notificationEmail:''}, {}), /single D_NOTIFICATION_EMAIL/);
});
test('autonomous derived deployment names accept 64 characters and reject 65 without restricting legacy deploy or Down', () => {
  const profile = { ...env, D_PREFIX: 'a'.repeat(8), D_ENVIRONMENT: 'b'.repeat(16),
    D_GENERATION: 'c'.repeat(12), D_OBSERVABILITY_AUTONOMOUS: 'true', D_NOTIFICATION_EMAIL: recipient };
  const accepted = optionsFromEnv(profile);
  assert.equal(accepted.deploymentName.length, 51);
  assert.equal(`${accepted.deploymentName}-oba-settings`.length, 64);
  const tooLong = { ...profile, D_GENERATION: 'c'.repeat(13) };
  const legacy = optionsFromEnv({ ...tooLong, D_OBSERVABILITY_AUTONOMOUS: 'false' });
  assert.equal(`${legacy.deploymentName}-oba-settings`.length, 65);
  assert.throws(() => optionsFromEnv(tooLong), /at most 51 characters.*must not exceed 64/);
  const maximum = { ...profile, D_GENERATION: 'c'.repeat(16) };
  const maximumLegacy = optionsFromEnv({ ...maximum, D_OBSERVABILITY_AUTONOMOUS: 'false' });
  assert.equal(maximumLegacy.deploymentName.length, 55, 'version-1 deploy keeps its existing textual limits');
  for (const flag of ['false', 'true']) {
    const down = optionsFromEnv({ ...maximum, D_ACTION: 'destroy', D_OBSERVABILITY_AUTONOMOUS: flag,
      D_NOTIFICATION_EMAIL: undefined, D_CONFIRM_DESTROY: maximumLegacy.deploymentName });
    assert.equal(down.deploymentName, maximumLegacy.deploymentName, 'Down keeps the exact ledger name');
    assert.equal(down.notificationEmail, '');
  }
});
test('maximum textual inputs fail autonomous deploy before any IO through every entry point', async () => {
  const maximum = { ...env, D_PREFIX: 'a'.repeat(8), D_ENVIRONMENT: 'b'.repeat(16), D_GENERATION: 'c'.repeat(16) };
  const opts = { ...optionsFromEnv(maximum), observabilityAutonomous: true, notificationEmail: recipient };
  assert.equal(`${opts.deploymentName}-oba-settings`.length, 68);
  let accesses = 0;
  const noIO = new Proxy({}, { get() { accesses++; throw new Error('IO must not be accessed'); } });
  assert.throws(() => optionsFromEnv({ ...maximum, D_OBSERVABILITY_AUTONOMOUS: 'true', D_NOTIFICATION_EMAIL: recipient }), /at most 51 characters/);
  await assert.rejects(run(opts, noIO), /at most 51 characters/);
  await assert.rejects(deploy(noIO, opts, null), /at most 51 characters/);
  assert.equal(accesses, 0, 'no Azure account/GET/mutation or other IO occurs');
});
test('v2 ledger permits only one extra OBA Reader and owned setting; v1 remains exact', () => {
  for (const shared of [true,false]) validateOwnership(autonomousOwnership(shared),autonomousOptions);
  for (const mutate of [
    o => o.version=3, o => o.observabilityAutonomous='true', o => o.observabilityAutonomous=false,
    o => o.externalRoles.push(o.externalRoles[2]), o => o.externalRoles[2].identityResourceId=o.externalRoles[0].identityResourceId,
    o => o.externalRoles[2].roleDefinitionId=o.externalRoles[0].roleDefinitionId, o => o.externalRoles[2].identityApiVersion=API.agents,
    o => o.externalRoles[2].scope=o.resourceGroupId, o => o.externalRoles[2].id+='other',
    o => o.defaultSettings.id+='other', o => o.defaultSettings.defaultAzureMonitorWorkspace+='other',
    o => o.auxiliaryDeployments.pop(), o => o.auxiliaryDeployments.push(o.auxiliaryDeployments[2]),
  ]) { const o=autonomousOwnership(); mutate(o); assert.throws(() => validateOwnership(o,autonomousOptions)); }
  for (const value of ['false', true, null]) { const o=ownership(); o.observabilityAutonomous=value; assert.throws(() => validateOwnership(o,options)); }
  const o=ownership(); o.defaultSettings=autonomousOwnership().defaultSettings; assert.throws(() => validateOwnership(o,options));
  assert(!JSON.stringify(autonomousOwnership()).includes(recipient));
});
test('existing ownership mode cannot change even with same profile/generation; Down follows either ledger', async () => {
  for (const [o,opts] of [[ownership(),autonomousOptions],[autonomousOwnership(),options]]) {
    await assert.rejects(deploy({},opts,{properties:{outputs:{ownership:{value:o}}}}), /immutable/);
    validateOwnership(o,{...options,action:'destroy'});
  }
});
test('fresh autonomous deploy rejects all preexisting default associations and read failures before writes', async () => {
  for (const value of [{properties:{defaultAzureMonitorWorkspace:'foreign'}},{properties:{defaultAzureMonitorWorkspace:autonomousOwnership().defaultSettings.defaultAzureMonitorWorkspace}},new Error('403')]) {
    let writes=0;
    const io={execute:(_p,args)=>args[0]==='rev-parse'?options.sha:'',az:args=>args[0]==='rest'?{value:[]}:[],get:async()=>{if(value instanceof Error)throw value;return value;},deploy:async()=>{writes++;}};
    await assert.rejects(deploy(io,autonomousOptions,null), /already exist|403/); assert.equal(writes,0);
  }
});
test('prerequisites use fresh OBA principal, skip verified existing grants/settings and never mask write failure', async () => {
  const o=autonomousOwnership(); const io=mock(o); const fixture=installObservability(io,o); let writes=0;
  io.deploy=async()=>{writes++;throw new Error('write failed');};
  await prepareObservability(io,o,fixture.f); assert.equal(writes,0);
  io.state.get(o.externalRoles[2].id).properties.principalId='principal-0';
  await assert.rejects(prepareObservability(io,o,fixture.f), /role identity/); assert.equal(writes,0);
  io.state.delete(o.externalRoles[2].id);
  await assert.rejects(prepareObservability(io,o,fixture.f), /write failed/); assert.equal(writes,1);
});
test('singleton absence is rechecked AFTER preview, and no create occurs if it appeared', async () => {
  const o=autonomousOwnership(); const io=mock(o); const {f}=installObservability(io,o); io.state.delete(o.defaultSettings.id);
  const calls=[];
  const guarded=createIO((_program,args)=>{
    calls.push(args[2]);
    if(args[2]==='what-if') io.state.set(o.defaultSettings.id,{properties:{defaultAzureMonitorWorkspace:'foreign'}});
    return {status:'Succeeded',changes:[]};
  });
  io.deploy=guarded.deploy;
  await assert.rejects(prepareObservability(io,o,f), /appeared during preview/); assert.deepEqual(calls,['what-if']);
});
test('v2 Down snapshots all three identities, removes exact settings first and external metadata before ledger last', async () => {
  const o=autonomousOwnership(true); const io=mock(o); installObservability(io,o);
  io.state.set(`${sub}/providers/Microsoft.Resources/deployments/${o.deploymentName}`,{properties:{outputs:{ownership:{value:o}}}});
  await run(optionsFromEnv({...env,D_ACTION:'destroy',D_CONFIRM_DESTROY:o.deploymentName}),io);
  assert.equal(Object.keys(io.snapshot.principals).length,3);
  const deletes=io.events.filter(e=>e[0]==='delete').map(e=>e[1]);
  assert.equal(deletes[0],o.defaultSettings.id);
  assert.equal(deletes.at(-1),`${sub}/providers/Microsoft.Resources/deployments/${o.deploymentName}`);
  for(const d of o.auxiliaryDeployments) assert(deletes.includes(d.id));
  assert(!deletes.includes(o.runnerVnetId));
});
test('v2 Down rejects changed settings before mutation and rechecks after cleanup snapshot', async () => {
  for(const late of [false,true]) {
    const o=autonomousOwnership(); const io=mock(o); installObservability(io,o);
    if(late) io.ledger=async()=>io.state.set(o.defaultSettings.id,{properties:{defaultAzureMonitorWorkspace:'foreign'}});
    else io.state.get(o.defaultSettings.id).properties.defaultAzureMonitorWorkspace='foreign';
    await assert.rejects(destroy(io,o), /binding changed/);
    assert(!io.events.some(e=>e[0]==='delete'));
    if(!late) assert(!io.events.some(e=>e[0]==='snapshot'));
  }
});
test('v2 settings DELETE failure or uncertain absence preserves ledger and prevents grant/RG deletion', async () => {
  for (const failure of ['delete-failed', 'readback-failed', 'still-present']) {
    const o = autonomousOwnership(); const io = mock(o); const { setting } = installObservability(io, o);
    const ledgerId = `${sub}/providers/Microsoft.Resources/deployments/${o.deploymentName}`;
    const get = io.get; const remove = io.remove;
    let deleteAttempts = 0; let deletionReturned = false;
    io.remove = async (id, api) => {
      if (id === o.defaultSettings.id) {
        deleteAttempts++;
        if (failure === 'delete-failed') throw new Error('Settings DELETE failed');
        await remove(id, api);
        deletionReturned = true;
        if (failure === 'still-present') io.state.set(id, setting);
        return;
      }
      return remove(id, api);
    };
    io.get = async (id, api) => {
      if (id === o.defaultSettings.id && deletionReturned && failure === 'readback-failed') {
        io.events.push(['get', id, api]);
        throw new Error('Settings readback unavailable');
      }
      return get(id, api);
    };
    await assert.rejects(destroy(io, o), failure === 'delete-failed' ? /Settings DELETE failed/ : /failed after 20 bounded attempts/);
    assert.equal(deleteAttempts, 1, 'never retry a settings DELETE to conceal failure');
    assert.equal(Object.keys(io.snapshot.principals).length, 3, 'verified cleanup snapshot is retained');
    assert(io.state.has(ledgerId), 'durable ownership ledger must survive uncertainty');
    assert(io.state.has(o.resourceGroupId), 'owned RG is not removed');
    for (const role of o.externalRoles) assert(io.state.has(role.id), 'external grants are not removed');
    assert(!io.events.some(e => e[0] === 'delete' && e[1] !== o.defaultSettings.id));
    assert(!io.events.some(e => e[0] === 'az' && e[1][0] === 'group' && e[1][1] === 'delete'));
  }
});
test('v2 Down resumes absent settings and identities using persisted principals, not unknown orphan adoption', async () => {
  const o=autonomousOwnership(); const io=mock(o);
  io.state.delete(o.resourceGroupId); o.externalRoles.forEach(r=>io.state.delete(r.identityResourceId));
  await destroy(io,o,{principals:Object.fromEntries(o.externalRoles.map((r,i)=>[r.id,`principal-${i}`]))});
  assert(!io.state.has(o.externalRoles[2].id));
  const unknown=mock(o); unknown.state.delete(o.externalRoles[2].identityResourceId);
  await assert.rejects(destroy(unknown,o), /cannot be verified/);
  assert(!unknown.events.some(e=>e[0]==='delete'));
});
test('independent GET verification checks configuration only, has no writes, and returns no recipient', async () => {
  const o=autonomousOwnership(); const io=mock(o); const fixture=installObservability(io,o);
  assert.deepEqual(await verifyObservability(io,o,recipient),{configurationVerified:true,runtimeProven:false,emailReceiptProven:false});
  for(const [id,api] of [[fixture.obaId,API.oba],[fixture.targetId,API.oba],[fixture.f.amwId,API.amw],[fixture.groupId,API.actionGroups],[o.defaultSettings.id,API.settings]]) assert(io.events.some(e=>e[0]==='get'&&e[1]===id&&e[2]===api));
  assert(io.events.every(e=>e[0]==='get'));
});
test('independent GET verifier fails every autonomous, identity, region, binding and notification gate', async () => {
  for(const mutate of [
    (io,x)=>io.state.get(x.obaId).properties.enabled=false,
    (io,x)=>io.state.get(x.obaId).properties.operations[0].mode='Manual',
    (io,x)=>io.state.get(x.obaId).properties.operations[0].instructions='other',
    (io,x)=>io.state.get(x.obaId).properties.operations.pop(),
    (io,x)=>io.state.get(x.obaId).identity.userAssignedIdentities.other={},
    (io,x)=>io.state.get(x.obaId).location='swedencentral',
    (io,x)=>io.state.get(x.f.amwId).location='swedencentral',
    (io,x)=>io.state.get(x.obaId).properties.monitoringAccountId='foreign',
    (io,x)=>io.state.get(x.targetId).properties.isAutonomous=false,
    (io,x)=>io.state.get(x.targetId).properties.resourceId='foreign',
    (io,x)=>io.state.get(`${x.obaId}/monitoredResources`).value.push({id:'foreign'}),
    (io,x)=>io.state.get(x.aiId).properties.WorkspaceResourceId='foreign',
    (io,x)=>io.state.get(x.f.amwId).properties.actions.defaultActionGroups[0].id='foreign',
    (io,x)=>io.state.get(x.groupId).properties.emailReceivers[0].emailAddress='other@example.invalid',
    (io,x)=>io.state.get(x.groupId).properties.emailReceivers[0].useCommonAlertSchema=false,
    (io,x)=>io.state.get(x.groupId).properties.emailReceivers[0].status='Disabled',
    (io,x)=>io.state.get(x.groupId).properties.emailReceivers.push({}),
    (io,x)=>io.state.get(x.groupId).tags.lifecycle_owner='foreign',
    (io,_x,o)=>io.state.get(o.externalRoles[2].id).properties.principalId='principal-0',
    (io,_x,o)=>io.state.delete(o.externalRoles[2].id),
    (io,_x,o)=>io.state.delete(o.defaultSettings.id),
    (io,_x,o)=>io.state.get(o.defaultSettings.id).properties.defaultAzureMonitorWorkspace='foreign',
  ]) {
    const o=autonomousOwnership(); const io=mock(o); const fixture=installObservability(io,o); mutate(io,fixture,o);
    await assert.rejects(verifyObservability(io,o,recipient)); assert(io.events.every(e=>e[0]==='get'));
  }
});
test('private recipient never enters preview logs, argv or persistent parameter files; CLI errors redact it', async () => {
  const logs=[]; const log=console.log; let file;
  console.log=value=>logs.push(value);
  try {
    const io=createIO((_program,args)=>{
      assert(!args.join(' ').includes(recipient)); file=args[args.indexOf('--parameters')+1].slice(1);
      assert.equal(JSON.parse(readFileSync(file,'utf8')).parameters.notificationEmail.value,recipient);
      if(args[2]==='what-if') return {status:'Succeeded',changes:[{resourceId:'owned-group',changeType:'Modify',after:{emailAddress:recipient}}]};
      throw Object.assign(new Error(`provider rejected ${recipient}`),{stderr:`receiver ${recipient}`});
    },[recipient]);
    await assert.rejects(io.deploy('rg-test','private-input','infra/scenario-d/foundations.bicep',{notificationEmail:recipient}),e=>!e.message.includes(recipient)&&!e.stderr.includes(recipient));
  } finally { console.log=log; }
  assert(!logs.join('').includes(recipient)); assert(!existsSync(file));
});
