import assert from 'node:assert/strict';
import test from 'node:test';
import express from 'express';
import { authorizeCaller } from '../auth';

const principalId = '11111111-1111-1111-1111-111111111111';

async function startTestServer() {
  const app = express();
  app.get('/protected', authorizeCaller(principalId), (_request, response) => {
    response.status(204).send();
  });
  const listener = app.listen(0);
  await new Promise<void>(resolve => listener.once('listening', resolve));
  const address = listener.address();
  if (!address || typeof address === 'string') {
    throw new Error('Test server did not bind to a TCP port');
  }
  return {
    url: `http://127.0.0.1:${address.port}/protected`,
    close: () => new Promise<void>(resolve => listener.close(() => resolve()))
  };
}

test('rejects requests without the Container Apps principal header', async () => {
  const server = await startTestServer();
  try {
    const response = await fetch(server.url);
    assert.equal(response.status, 403);
  } finally {
    await server.close();
  }
});

test('accepts only the configured caller principal', async () => {
  const server = await startTestServer();
  try {
    const rejected = await fetch(server.url, {
      headers: {
        'x-ms-client-principal-id': '22222222-2222-2222-2222-222222222222'
      }
    });
    assert.equal(rejected.status, 403);

    const accepted = await fetch(server.url, {
      headers: { 'x-ms-client-principal-id': principalId.toUpperCase() }
    });
    assert.equal(accepted.status, 204);
  } finally {
    await server.close();
  }
});
