import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { optionsFromEnv, validateOwnership, armGuid, destroy, run, deploy, retry, createIO, validateResumeDns, API } from '../lib/scenario-d-lifecycle.mjs';
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
    state.set(r.identityResourceId, i ? { identity: { principalId } } : { properties: { principalId } });
    state.set(r.id, { properties: { principalId, roleDefinitionId: r.roleDefinitionId, scope: r.scope } });
  });
  state.set(o.runnerPeeringId, { properties: { remoteVirtualNetwork: { id: o.appVnetId } } });
  o.sharedDnsLinks.forEach(l => state.set(l.id, { tags: o.tags, properties: { virtualNetwork: { id: l.virtualNetworkId } } }));
  o.auxiliaryDeployments.forEach(d => state.set(d.id, {}));
  const io = {
    state, events, log: () => {}, sleep: async () => {},
    get: async (id) => { events.push(['get', id]); return state.get(id) ?? null; },
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
test('healthy staged deploy publishes digests before apps, grants before connectors, reconciles and checks real checkout', async () => {
  const o = ownership(); const io = mock(o); const stages = []; let secretFile;
  const f = { acrName:'acrdabcdefgh', acrLoginServer:'acrdabcdefgh.azurecr.io', keyVaultName:'kv-d-abcdefgh', appInsightsId:o.resourceGroupId+'/providers/Microsoft.Insights/components/appi-d-abcdefgh', actionPrincipalId:'principal-0' };
  io.az = args => {
    if (args[0] === 'rest') return { value: [] };
    if (args[0] === 'group') return [];
    if (args[0] === 'account') return {accessToken:`header.${Buffer.from(JSON.stringify({oid:'deployer',tid:tenantId})).toString('base64url')}.signature`};
    if (args[0] === 'keyvault') { secretFile = args[args.indexOf('--file')+1]; assert(existsSync(secretFile)); assert.equal(readFileSync(secretFile,'utf8'),'ephemeral-connection'); return {}; }
    throw new Error(`Unexpected ${args}`);
  };
  io.get = async id => id === f.appInsightsId ? {properties:{DisableLocalAuth:true,ConnectionString:'ephemeral-connection'}} : null;
  io.deploy = async (scope,name,file,params) => {
    stages.push(name);
    if (file.endsWith('/main.bicep')) return {ownership:{value:o}};
    if (name === 'scenario-d-foundations') return {foundations:{value:f}};
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
  await deploy(io,options,null);
  assert(stages.indexOf('publish') < stages.indexOf('smoke'));
  assert(stages.indexOf('smoke') < stages.indexOf('scenario-d-apps'));
  assert(stages.indexOf(options.deploymentName+'-roles') < stages.indexOf('scenario-d-connectors-alerts'));
  assert(stages.indexOf('reconcile') < stages.indexOf('verify')); assert.equal(stages.at(-1),'checkout');
  assert(!existsSync(secretFile), 'ephemeral secret file removed only after awaited write');
  stages.length = 0;
  const execute = io.execute;
  io.execute = (program,args) => {
    if (program === 'bash' && args[0] === 'scripts/tests/scenario-d-container-smoke.sh') throw new Error('container smoke failed');
    return execute(program,args);
  };
  await assert.rejects(deploy(io,options,null), /container smoke failed/);
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
  assert.match(agents,/enabled: false/); assert.match(agents,/isAutonomous: false/); assert.match(agents,/mode: 'Review'/);
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
