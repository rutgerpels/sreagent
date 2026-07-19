#!/usr/bin/env node
import { resolve } from "node:path";
import {
  loadDesiredState,
  reconcileAgent,
  renderDesiredState,
} from "./lib/sre-agent-reconciler.mjs";

function parseArguments(argumentsList) {
  const options = {
    mode: "apply",
    config: resolve("agent/scenario-c"),
  };
  for (let index = 0; index < argumentsList.length; index += 1) {
    const argument = argumentsList[index];
    if (!argument.startsWith("--")) throw new Error(`Unexpected argument: ${argument}`);
    const name = argument.slice(2);
    const value = argumentsList[index + 1];
    if (!value || value.startsWith("--")) throw new Error(`Missing value for ${argument}.`);
    index += 1;
    if (name === "subscription") options.subscription = value;
    else if (name === "resource-group") options.resourceGroup = value;
    else if (name === "agent") options.agentName = value;
    else if (name === "config") options.config = resolve(value);
    else if (name === "mode" && ["apply", "verify", "render"].includes(value)) options.mode = value;
    else throw new Error(`Unsupported option: ${argument} ${value}`);
  }
  if (options.mode !== "render") {
    for (const [name, value] of Object.entries({
      subscription: options.subscription,
      "resource-group": options.resourceGroup,
      agent: options.agentName,
    })) {
      if (!value) throw new Error(`--${name} is required for ${options.mode}.`);
    }
  }
  return options;
}

try {
  const options = parseArguments(process.argv.slice(2));
  const desired = loadDesiredState(options.config);
  if (options.mode === "render") {
    process.stdout.write(`${JSON.stringify(renderDesiredState(desired), null, 2)}\n`);
  } else {
    const result = await reconcileAgent(options, desired);
    process.stdout.write(
      `SRE Agent ${result.mode} succeeded; Code Access=${result.codeAccessEnabled}, ` +
        `remediation connector=${result.remediationConnectorEnabled}.\n`,
    );
  }
} catch (error) {
  process.stderr.write(`SRE Agent reconciliation failed: ${error.message}\n`);
  process.exitCode = 1;
}
