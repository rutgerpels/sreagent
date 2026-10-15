#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { principalFromToken, validateDeploymentState } from './lib/bootstrap-context.mjs';

try {
  const [action, ...args] = process.argv.slice(2);
  const input = JSON.parse(readFileSync(0, 'utf8'));
  let result;
  if (action === 'principal' && args.length === 1) {
    result = principalFromToken(input, args[0]);
  } else if (action === 'state' && args.length === 3) {
    const [scenario, prefix, environment] = args;
    result = validateDeploymentState(input, { scenario, prefix, environment });
  } else {
    throw new Error('Usage: bootstrap-context.mjs principal ACCOUNT_TYPE | state SCENARIO PREFIX ENVIRONMENT (JSON on stdin).');
  }
  console.log(JSON.stringify(result));
} catch (error) {
  console.error(`Bootstrap validation failed: ${error.message}`);
  process.exitCode = 1;
}
