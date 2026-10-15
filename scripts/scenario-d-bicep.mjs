#!/usr/bin/env node
import { optionsFromEnv, run } from './lib/scenario-d-lifecycle.mjs';
try {
  if (process.platform !== 'linux' || process.env.SCENARIO_D_PRIVATE_RUNNER !== 'true') throw new Error('Run only through the Scenario D private Linux runner workflow.');
  await run(optionsFromEnv(process.env));
} catch (error) {
  console.error(`Scenario D lifecycle failed: ${error.message}`);
  process.exitCode = 1;
}
