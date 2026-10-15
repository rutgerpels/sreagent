const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;

export function principalFromToken(response, accountType) {
  let claims;
  try {
    claims = JSON.parse(Buffer.from(response.accessToken.split('.')[1], 'base64url').toString());
  } catch {
    throw new Error('Could not read the authenticated ARM token claims.');
  }
  if (!uuid.test(claims.oid ?? '')) throw new Error('Authenticated ARM token has no valid object ID.');
  const principalType = { user: 'User', serviceprincipal: 'ServicePrincipal' }[accountType?.toLowerCase()];
  if (!principalType) throw new Error('Azure account user.type must be user or servicePrincipal.');
  return { objectId: claims.oid, principalType };
}

export function validateDeploymentState(state, expected) {
  if (typeof state?.format_version !== 'string') throw new Error('Terraform did not return a valid state document.');
  const values = state.values;
  const modules = [];
  function collect(module) {
    if (!module) return;
    modules.push(module);
    (module.child_modules ?? []).forEach(collect);
  }
  collect(values?.root_module);
  const resources = modules.flatMap(module => module.resources ?? []);
  const outputs = values?.outputs ?? {};
  if (resources.length === 0 && Object.keys(outputs).length === 0) return { empty: true };
  const profile = outputs.deployment_profile?.value;
  const group = resources.find(resource => resource.address === 'azurerm_resource_group.this')?.values;
  const suffix = resources.find(resource => resource.address === 'random_string.suffix')?.values?.result;
  // Existing deployments predate deployment_profile. Verify their exact generated
  // resource-group name and environment tag rather than trusting a backend key.
  const matches = profile
    ? ['scenario', 'prefix', 'environment'].every(key => profile[key] === expected[key])
    : outputs.scenario?.value === expected.scenario &&
      typeof suffix === 'string' && /^[a-z0-9]{6}$/.test(suffix) &&
      group?.name === `rg-${expected.prefix}-${expected.environment}-${expected.scenario.toLowerCase()}-${suffix}` &&
      group?.tags?.env === expected.environment;
  if (!matches) {
    throw new Error('Selected state does not match the requested scenario/prefix/environment. Refusing apply; use the original deployment inputs. State migration must be an explicit, separately reviewed operation.');
  }
  return { empty: false, ...expected };
}
