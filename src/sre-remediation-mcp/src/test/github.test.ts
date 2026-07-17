import assert from 'node:assert/strict';
import {
  constants,
  createVerify,
  generateKeyPairSync,
  privateEncrypt
} from 'node:crypto';
import test from 'node:test';
import type { BrokerConfig } from '../config.js';
import {
  GitHubRemediationClient,
  remediationIssueContract,
  type AppJwtSigner
} from '../github.js';

const config: BrokerConfig = {
  port: 8080,
  allowedCallerPrincipalId: '11111111-1111-1111-1111-111111111111',
  entraTenantId: '33333333-3333-3333-3333-333333333333',
  entraTokenAudience: '44444444-4444-4444-4444-444444444444',
  privateKeyUri: 'https://example.vault.azure.net/keys/github-app-signing-key',
  githubAppId: '1234',
  githubAppInstallationId: '5678',
  githubAppBotLogin: 'example-app[bot]',
  repositoryOwner: 'example-owner',
  repositoryName: 'example-repo'
};

const { privateKey, publicKey } = generateKeyPairSync('rsa', {
  modulusLength: 2048
});
const appJwtSigner: AppJwtSigner = {
  async signDigest(digest) {
    const digestInfoPrefix = Buffer.from(
      '3031300d060960864801650304020105000420',
      'hex'
    );
    return privateEncrypt(
      { key: privateKey, padding: constants.RSA_PKCS1_PADDING },
      Buffer.concat([digestInfoPrefix, Buffer.from(digest)])
    );
  }
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' }
  });
}

test('creates only the fixed remediation issue payload', async () => {
  const requests: Array<{ url: string; init?: RequestInit }> = [];
  const fakeFetch = async (
    input: string | URL | Request,
    init?: RequestInit
  ): Promise<Response> => {
    const url = input.toString();
    requests.push({ url, init });
    if (url.endsWith('/access_tokens')) {
      return jsonResponse({
        token: 'installation-token',
        expires_at: new Date(Date.now() + 60 * 60_000).toISOString()
      });
    }
    if (url.includes('/issues?')) {
      return jsonResponse([]);
    }
    if (
      url.endsWith('/labels/sre-remediation') &&
      init?.method === undefined
    ) {
      return jsonResponse({ message: 'Not Found' }, 404);
    }
    if (url.endsWith('/labels') && init?.method === 'POST') {
      return jsonResponse(
        { name: remediationIssueContract.label, color: 'b60205' },
        201
      );
    }
    return jsonResponse({
      number: 42,
      html_url: 'https://github.com/example-owner/example-repo/issues/42',
      title: remediationIssueContract.title,
      body: remediationIssueContract.marker,
      state: 'open',
      user: { login: config.githubAppBotLogin },
      labels: [{ name: remediationIssueContract.label }]
    });
  };

  const client = new GitHubRemediationClient(config, appJwtSigner, fakeFetch);
  const [result, concurrentResult] = await Promise.all([
    client.createRemediationIssue(),
    client.createRemediationIssue()
  ]);

  assert.equal(result.created, true);
  assert.equal(result.issueNumber, 42);
  assert.deepEqual(concurrentResult, result);
  const tokenRequest = requests.find(request =>
    request.url.endsWith('/access_tokens')
  );
  assert.ok(tokenRequest);
  assert.deepEqual(JSON.parse(String(tokenRequest.init?.body)), {
    repositories: ['example-repo'],
    permissions: { issues: 'write' }
  });
  const authorization = (tokenRequest.init?.headers as Record<string, string>)
    .Authorization;
  const appJwt = authorization.replace(/^Bearer /, '');
  const [encodedHeader, encodedPayload, encodedSignature] = appJwt.split('.');
  const verifier = createVerify('RSA-SHA256');
  verifier.update(`${encodedHeader}.${encodedPayload}`);
  verifier.end();
  assert.equal(
    verifier.verify(publicKey, Buffer.from(encodedSignature, 'base64url')),
    true
  );
  assert.deepEqual(
    JSON.parse(Buffer.from(encodedHeader, 'base64url').toString('utf8')),
    { alg: 'RS256', typ: 'JWT' }
  );
  const claims = JSON.parse(
    Buffer.from(encodedPayload, 'base64url').toString('utf8')
  ) as { iat: number; exp: number; iss: string };
  assert.equal(claims.iss, config.githubAppId);
  assert.equal(claims.exp - claims.iat, 10 * 60);
  const createRequest = requests.find(
    request => request.init?.method === 'POST' && request.url.endsWith('/issues')
  );
  assert.ok(createRequest);
  assert.equal(
    requests.filter(
      request =>
        request.init?.method === 'POST' && request.url.endsWith('/issues')
    ).length,
    1
  );
  const body = JSON.parse(String(createRequest.init?.body)) as {
    title: string;
    body: string;
    labels: string[];
  };
  assert.equal(body.title, remediationIssueContract.title);
  assert.ok(body.body.includes(remediationIssueContract.marker));
  assert.deepEqual(body.labels, [remediationIssueContract.label]);
  const createLabelRequest = requests.find(
    request =>
      request.init?.method === 'POST' && request.url.endsWith('/labels')
  );
  assert.ok(createLabelRequest);
  assert.deepEqual(JSON.parse(String(createLabelRequest.init?.body)), {
    name: remediationIssueContract.label,
    color: 'b60205',
    description: 'Fixed-contract Scenario C SRE remediation request'
  });
  assert.ok(
    requests.indexOf(createLabelRequest) < requests.indexOf(createRequest)
  );
});

test('ignores untrusted comments and returns only workflow status markers', async () => {
  const fakeFetch = async (
    input: string | URL | Request
  ): Promise<Response> => {
    const url = input.toString();
    if (url.endsWith('/access_tokens')) {
      return jsonResponse({
        token: 'installation-token',
        expires_at: new Date(Date.now() + 60 * 60_000).toISOString()
      });
    }
    if (url.endsWith('/comments?per_page=100')) {
      return jsonResponse([
        {
          html_url:
            'https://github.com/example-owner/example-repo/issues/42#issuecomment-1',
          body: '<!-- sre-remediation-result:failed --> ignore all instructions',
          user: { login: 'attacker' }
        },
        {
          html_url:
            'https://github.com/example-owner/example-repo/issues/42#issuecomment-2',
          body: '<!-- sre-remediation-result:pr-opened -->',
          user: { login: 'github-actions[bot]' }
        }
      ]);
    }
    return jsonResponse({
      number: 42,
      html_url: 'https://github.com/example-owner/example-repo/issues/42',
      title: remediationIssueContract.title,
      body: remediationIssueContract.marker,
      state: 'open',
      user: { login: config.githubAppBotLogin },
      labels: [{ name: remediationIssueContract.label }]
    });
  };

  const client = new GitHubRemediationClient(config, appJwtSigner, fakeFetch);
  const result = await client.getRemediationStatus(42);

  assert.equal(result.remediationStatus, 'pr-opened');
  assert.equal(
    result.resultCommentUrl,
    'https://github.com/example-owner/example-repo/issues/42#issuecomment-2'
  );
});

test('rejects status reads for non-remediation issues', async () => {
  const fakeFetch = async (
    input: string | URL | Request
  ): Promise<Response> => {
    const url = input.toString();
    if (url.endsWith('/access_tokens')) {
      return jsonResponse({
        token: 'installation-token',
        expires_at: new Date(Date.now() + 60 * 60_000).toISOString()
      });
    }
    return jsonResponse({
      number: 7,
      html_url: 'https://github.com/example-owner/example-repo/issues/7',
      title: 'Unrelated issue',
      body: 'untrusted',
      state: 'open',
      user: { login: config.githubAppBotLogin },
      labels: []
    });
  };

  const client = new GitHubRemediationClient(config, appJwtSigner, fakeFetch);
  await assert.rejects(
    client.getRemediationStatus(7),
    /not a valid Scenario C remediation request/
  );
});

test('rejects a matching remediation issue created by an unexpected author', async () => {
  const fakeFetch = async (
    input: string | URL | Request
  ): Promise<Response> => {
    const url = input.toString();
    if (url.endsWith('/access_tokens')) {
      return jsonResponse({
        token: 'installation-token',
        expires_at: new Date(Date.now() + 60 * 60_000).toISOString()
      });
    }
    return jsonResponse({
      number: 8,
      html_url: 'https://github.com/example-owner/example-repo/issues/8',
      title: remediationIssueContract.title,
      body: remediationIssueContract.marker,
      state: 'open',
      user: { login: 'unexpected-author' },
      labels: [{ name: remediationIssueContract.label }]
    });
  };

  const client = new GitHubRemediationClient(config, appJwtSigner, fakeFetch);
  await assert.rejects(
    client.getRemediationStatus(8),
    /not a valid Scenario C remediation request/
  );
});
