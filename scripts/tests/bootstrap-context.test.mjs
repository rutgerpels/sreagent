import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { principalFromToken, validateDeploymentState } from '../lib/bootstrap-context.mjs';
import { optionsFromEnv } from '../lib/scenario-d-lifecycle.mjs';

const expected = { scenario: 'A', prefix: 'pay', environment: 'demo' };
const oid = '00000000-0000-0000-0000-000000000001';
function state(profile = expected) {
  return { format_version: '1.0', values: { outputs: { deployment_profile: { value: profile } } } };
}
function legacy(profile = expected) {
  return { format_version: '1.0', values: {
    outputs: { scenario: { value: profile.scenario } },
    root_module: { resources: [
      { address: 'random_string.suffix', values: { result: 'abc123' } },
      { address: 'azurerm_resource_group.this', values: {
        name: `rg-${profile.prefix}-${profile.environment}-${profile.scenario.toLowerCase()}-abc123`,
        tags: { env: profile.environment },
      } },
    ] },
  } };
}
test('selected remote state validates all immutable profile dimensions', () => {
  assert.deepEqual(validateDeploymentState({ format_version: '1.0' }, expected), { empty: true });
  for (const fixture of [state, legacy]) {
    assert.equal(validateDeploymentState(fixture(), expected).empty, false);
    for (const change of [{ scenario: 'B' }, { prefix: 'other' }, { environment: 'production' }]) {
      assert.throws(() => validateDeploymentState(fixture({ ...expected, ...change }), expected),
        /scenario\/prefix\/environment/);
    }
  }
  const existing = { scenario: 'B', prefix: 'contosopay', environment: 'existing-demo' };
  assert.equal(validateDeploymentState(legacy(existing), existing).prefix, 'contosopay');
});
test('legacy or malformed state cannot bypass the guard without verifiable profile identity', () => {
  for (const value of [{}, { error: 'backend unavailable' }, legacy()]) {
    if (value.values) delete value.values.root_module.resources[1].values.tags.env;
    assert.throws(() => validateDeploymentState(value, expected));
  }
});
test('bootstrap extracts signed-in user or UAMI oid without directory lookups or token logging', () => {
  const response = { accessToken: `header.${Buffer.from(JSON.stringify({ oid })).toString('base64url')}.signature` };
  assert.deepEqual(principalFromToken(response, 'servicePrincipal'), { objectId: oid, principalType: 'ServicePrincipal' });
  assert.deepEqual(principalFromToken(response, 'user'), { objectId: oid, principalType: 'User' });
  assert.throws(() => principalFromToken({ accessToken: 'invalid' }, 'user'), /ARM token claims/);
  assert.throws(() => principalFromToken(response, 'unknown'), /user.type/);
  const result = spawnSync(process.execPath, ['scripts/bootstrap-context.mjs', 'principal', 'servicePrincipal'],
    { input: JSON.stringify(response), encoding: 'utf8' });
  assert.equal(result.status, 0);
  assert.deepEqual(JSON.parse(result.stdout), { objectId: oid, principalType: 'ServicePrincipal' });
  assert(!result.stdout.includes(response.accessToken));
});
test('state CLI fails closed for prefix mismatch before callers can apply', () => {
  const result = spawnSync(process.execPath, ['scripts/bootstrap-context.mjs', 'state', 'A', 'other', 'demo'],
    { input: JSON.stringify(legacy()), encoding: 'utf8' });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Refusing apply/);
});
test('local wrappers only reconfigure selected state and validate it before applying', () => {
  for (const file of ['scripts/deploy.sh', 'scripts/deploy.ps1']) {
    const source = readFileSync(file, 'utf8');
    assert(!source.includes('-migrate-state'));
    assert(!source.includes('-force-copy'));
    const init = source.indexOf('init -input=false -reconfigure');
    const inspect = source.indexOf('show -json');
    const apply = source.indexOf('apply -input=false -auto-approve');
    assert(init > 0 && init < inspect && inspect < apply);
    assert(source.includes('bootstrap-context.mjs'));
    assert(!source.includes('az ad '));
  }
  const workflow = readFileSync('.github/workflows/deploy.yml', 'utf8');
  assert(!workflow.includes('az ad '));
  assert(workflow.includes('bootstrap-context.mjs principal servicePrincipal'));
});
test('public default prefix is consistently valid for A/B/C and Bicep D', () => {
  for (const name of ['deploy', 'destroy', 'apply-infra', 'deploy-apps', 'scenario-d-bicep']) {
    const source = readFileSync(`.github/workflows/${name}.yml`, 'utf8');
    const defaults = [...source.matchAll(/(?:^|\n)      prefix:[\s\S]*?\n        default: "?([a-z]+)"?/g)].map(match => match[1]);
    assert(defaults.length > 0, `${name} has a public prefix default`);
    assert(defaults.every(prefix => prefix === 'pay'), `${name} shares the default`);
  }
  const options = optionsFromEnv({
    AZURE_SUBSCRIPTION_ID: oid, AZURE_TENANT_ID: oid, GITHUB_SHA: 'a'.repeat(40),
    D_RUNNER_NETWORK_RG: 'customer-runner', D_RUNNER_VNET_NAME: 'customer-vnet',
  });
  assert.equal(options.prefix, 'pay');
  assert.equal(options.deploymentName, 'scenario-d-pay-demo-d-bicep1');
});
