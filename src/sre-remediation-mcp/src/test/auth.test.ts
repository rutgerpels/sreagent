import assert from 'node:assert/strict';
import test from 'node:test';
import type { Request, Response } from 'express';
import {
  createLocalJWKSet,
  exportJWK,
  generateKeyPair,
  SignJWT,
  type CryptoKey,
  type JWK
} from 'jose';
import {
  authorizeCaller,
  EntraAccessTokenVerifier,
  InvalidAccessTokenError,
  type AccessTokenVerifier
} from '../auth.js';

const tenantId = '11111111-1111-4111-8111-111111111111';
const expectedPrincipalId = '22222222-2222-4222-8222-222222222222';
const audience = '33333333-3333-4333-8333-333333333333';
const issuer = `https://login.microsoftonline.com/${tenantId}/v2.0`;

async function createSigningFixture() {
  const { privateKey, publicKey } = await generateKeyPair('RS256', {
    extractable: true
  });
  const publicJwk: JWK = await exportJWK(publicKey);
  publicJwk.kid = 'test-key';
  publicJwk.alg = 'RS256';
  publicJwk.use = 'sig';
  const verifier = new EntraAccessTokenVerifier(
    tenantId,
    audience,
    createLocalJWKSet({ keys: [publicJwk] }),
    issuer
  );
  return { privateKey, verifier };
}

async function signToken(
  privateKey: CryptoKey,
  overrides: {
    audience?: string;
    expiresAt?: number;
    issuer?: string;
    principalId?: string;
    tenantId?: string;
  } = {}
): Promise<string> {
  return new SignJWT({
    oid: overrides.principalId ?? expectedPrincipalId,
    tid: overrides.tenantId ?? tenantId
  })
    .setProtectedHeader({ alg: 'RS256', kid: 'test-key' })
    .setIssuer(overrides.issuer ?? issuer)
    .setAudience(overrides.audience ?? audience)
    .setIssuedAt()
    .setExpirationTime(overrides.expiresAt ?? Math.floor(Date.now() / 1000) + 300)
    .sign(privateKey);
}

test('verifies a valid Microsoft Entra access token', async () => {
  const { privateKey, verifier } = await createSigningFixture();
  const claims = await verifier.verify(await signToken(privateKey));

  assert.equal(claims.oid, expectedPrincipalId);
  assert.equal(claims.tid, tenantId);
});

for (const [name, overrides] of [
  ['issuer', { issuer: 'https://issuer.invalid/' }],
  ['audience', { audience: 'api://wrong-audience' }],
  ['expiry', { expiresAt: 1 }],
  ['tenant', { tenantId: '44444444-4444-4444-8444-444444444444' }]
] as const) {
  test(`rejects a token with the wrong ${name}`, async () => {
    const { privateKey, verifier } = await createSigningFixture();

    await assert.rejects(
      verifier.verify(await signToken(privateKey, overrides)),
      InvalidAccessTokenError
    );
  });
}

test('rejects a token with an invalid signature', async () => {
  const { verifier } = await createSigningFixture();
  const { privateKey } = await generateKeyPair('RS256');

  await assert.rejects(
    verifier.verify(await signToken(privateKey)),
    InvalidAccessTokenError
  );
});

function createResponse() {
  let statusCode = 0;
  let body: unknown;
  const response = {
    status(code: number) {
      statusCode = code;
      return this;
    },
    json(value: unknown) {
      body = value;
      return this;
    }
  } as Response;
  return {
    response,
    statusCode: () => statusCode,
    body: () => body
  };
}

function createRequest(headers: Record<string, string>): Request {
  const normalized = Object.fromEntries(
    Object.entries(headers).map(([key, value]) => [key.toLowerCase(), value])
  );
  return {
    header(name: string) {
      return normalized[name.toLowerCase()];
    }
  } as Request;
}

const acceptedVerifier: AccessTokenVerifier = {
  async verify() {
    return { oid: expectedPrincipalId, tid: tenantId };
  }
};

test('rejects a request without the platform access token', async () => {
  const result = createResponse();
  await authorizeCaller(expectedPrincipalId, acceptedVerifier)(
    createRequest({ 'x-ms-client-principal-id': expectedPrincipalId }),
    result.response,
    () => assert.fail('next must not be called')
  );

  assert.equal(result.statusCode(), 401);
});

test('rejects an invalid platform access token', async () => {
  const result = createResponse();
  const invalidVerifier: AccessTokenVerifier = {
    async verify() {
      throw new InvalidAccessTokenError('invalid');
    }
  };
  await authorizeCaller(expectedPrincipalId, invalidVerifier)(
    createRequest({
      'x-ms-token-aad-access-token': 'invalid-token',
      'x-ms-client-principal-id': expectedPrincipalId
    }),
    result.response,
    () => assert.fail('next must not be called')
  );

  assert.equal(result.statusCode(), 401);
});

test('rejects an access token for the wrong principal', async () => {
  const result = createResponse();
  const wrongPrincipalVerifier: AccessTokenVerifier = {
    async verify() {
      return {
        oid: '55555555-5555-4555-8555-555555555555',
        tid: tenantId
      };
    }
  };
  await authorizeCaller(expectedPrincipalId, wrongPrincipalVerifier)(
    createRequest({
      'x-ms-token-aad-access-token': 'valid-token',
      'x-ms-client-principal-id': '55555555-5555-4555-8555-555555555555'
    }),
    result.response,
    () => assert.fail('next must not be called')
  );

  assert.equal(result.statusCode(), 403);
});

test('rejects a spoofed platform principal header', async () => {
  const result = createResponse();
  await authorizeCaller(expectedPrincipalId, acceptedVerifier)(
    createRequest({
      'x-ms-token-aad-access-token': 'valid-token',
      'x-ms-client-principal-id': '55555555-5555-4555-8555-555555555555'
    }),
    result.response,
    () => assert.fail('next must not be called')
  );

  assert.equal(result.statusCode(), 403);
});

test('accepts matching cryptographic and platform identities', async () => {
  const result = createResponse();
  let nextCalled = false;
  await authorizeCaller(expectedPrincipalId, acceptedVerifier)(
    createRequest({
      'x-ms-token-aad-access-token': 'valid-token',
      'x-ms-client-principal-id': expectedPrincipalId
    }),
    result.response,
    () => {
      nextCalled = true;
    }
  );

  assert.equal(result.statusCode(), 0);
  assert.equal(nextCalled, true);
});
