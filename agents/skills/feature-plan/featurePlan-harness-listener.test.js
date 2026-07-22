#!/usr/bin/env node
// Unit tests for featurePlan-harness-listener.js

const { test } = require('node:test');
const assert = require('node:assert');
const { FeaturePlanListener, createServer } = require('./featurePlan-harness-listener');

test('FeaturePlanListener can be instantiated', () => {
  const listener = new FeaturePlanListener(3001);
  assert.ok(listener);
  assert.strictEqual(listener.port, 3001);
  assert.ok(typeof listener.aiAgent === 'function');
});

test('createServer creates a listener instance', () => {
  const server = createServer(3002);
  assert.ok(server instanceof FeaturePlanListener);
  assert.strictEqual(server.port, 3002);
});

test('createServer accepts aiAgent option', () => {
  const mockAI = async () => ({ response: 'test' });
  const server = createServer(3003, { aiAgent: mockAI });
  assert.strictEqual(server.aiAgent, mockAI);
});

test('defaultAIAgent returns a response', async () => {
  const listener = new FeaturePlanListener(3004);
  const result = await listener.defaultAIAgent({
    section: 'files',
    question: 'Should we add error handling?'
  });
  assert.ok(result.response);
  assert.ok(result.response.includes('No AI configured'));
});

test('FeaturePlanListener can start and stop', async () => {
  const listener = new FeaturePlanListener(3005);
  await listener.start();
  assert.ok(listener.server);
  await listener.stop();
  assert.ok(true, 'server stopped cleanly');
});
