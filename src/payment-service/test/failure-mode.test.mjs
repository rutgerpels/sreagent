import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { parseFailureMode, failureResponseFor } = require('../dist/failure-mode.js');

test('defaults to off when unset or blank', () => {
  assert.equal(parseFailureMode(undefined), 'off');
  assert.equal(parseFailureMode(''), 'off');
  assert.equal(parseFailureMode('   '), 'off');
});

test('accepts known modes case-insensitively with whitespace', () => {
  assert.equal(parseFailureMode('off'), 'off');
  assert.equal(parseFailureMode(' Unavailable '), 'unavailable');
});

test('rejects unknown values instead of silently running healthy', () => {
  assert.throws(() => parseFailureMode('broken'));
});

test('off produces no failure response', () => {
  assert.equal(failureResponseFor('off'), null);
});

test('unavailable produces a 503 declined response', () => {
  const response = failureResponseFor('unavailable');
  assert.equal(response.statusCode, 503);
  assert.equal(response.body.status, 'declined');
  assert.equal(response.body.reason, 'payment-processor-unavailable');
});
