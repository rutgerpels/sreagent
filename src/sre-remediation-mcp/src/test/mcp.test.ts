import assert from 'node:assert/strict';
import test from 'node:test';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { createApp } from '../app.js';
import type { BrokerConfig } from '../config.js';
import type { RemediationClient } from '../mcp.js';

const principalId = '11111111-1111-1111-1111-111111111111';
const config: BrokerConfig = {
  port: 8080,
  allowedCallerPrincipalId: principalId,
  entraTenantId: '22222222-2222-2222-2222-222222222222',
  entraTokenAudience: '33333333-3333-3333-3333-333333333333',
  privateKeyUri: 'https://example.vault.azure.net/keys/github-app-signing-key',
  githubAppId: '1234',
  githubAppInstallationId: '5678',
  githubAppBotLogin: 'example-app[bot]',
  repositoryOwner: 'example-owner',
  repositoryName: 'example-repo'
};

const remediationClient: RemediationClient = {
  async createRemediationIssue() {
    return {
      issueNumber: 42,
      issueUrl: 'https://github.com/example-owner/example-repo/issues/42',
      created: true
    };
  },
  async getRemediationStatus(issueNumber) {
    return {
      issueNumber,
      issueUrl: `https://github.com/example-owner/example-repo/issues/${issueNumber}`,
      issueState: 'open',
      remediationStatus: 'requested'
    };
  }
};

test('serves the constrained tools over stateless Streamable HTTP', async () => {
  const app = createApp(config, remediationClient, {
    async verify() {
      return { oid: principalId, tid: config.entraTenantId };
    }
  });
  const listener = app.listen(0);
  await new Promise<void>(resolve => listener.once('listening', resolve));
  const address = listener.address();
  if (!address || typeof address === 'string') {
    throw new Error('Test server did not bind to a TCP port');
  }

  const transport = new StreamableHTTPClientTransport(
    new URL(`http://127.0.0.1:${address.port}/mcp`),
    {
      requestInit: {
        headers: {
          'x-ms-token-aad-access-token': 'platform-access-token',
          'x-ms-client-principal-id': principalId
        }
      }
    }
  );
  const client = new Client({ name: 'broker-test', version: '1.0.0' });

  try {
    await client.connect(transport);
    const tools = await client.listTools();
    assert.deepEqual(
      tools.tools.map(tool => tool.name).sort(),
      [
        'create_slow_leak_remediation_issue',
        'get_slow_leak_remediation_status'
      ]
    );

    const result = await client.callTool({
      name: 'create_slow_leak_remediation_issue',
      arguments: {}
    });
    assert.equal(result.isError, undefined);
    assert.deepEqual(result.structuredContent, {
      issueNumber: 42,
      issueUrl: 'https://github.com/example-owner/example-repo/issues/42',
      created: true
    });
  } finally {
    await client.close();
    await new Promise<void>(resolve => listener.close(() => resolve()));
  }
});
