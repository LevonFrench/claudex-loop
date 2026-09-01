import assert from 'node:assert/strict';
import test from 'node:test';
import { normalizeLabel, requireText, stripAnsi } from '../server/runtime.mjs';

test('normalizes valid labels and rejects path/control ambiguity', () => {
  assert.equal(normalizeLabel('  claude:builder  '), 'claude:builder');
  assert.throws(() => normalizeLabel('builder/other'), /path separator/);
  assert.throws(() => normalizeLabel('CON'), /reserved Windows device/);
  assert.throws(() => normalizeLabel(`bad\u202ename`), /direction override/);
});

test('message size is bounded and ANSI is removed from viewer output', () => {
  assert.equal(requireText('hello'), 'hello');
  assert.throws(() => requireText('x'.repeat(65537)), /exceeds/);
  assert.equal(stripAnsi('\u001b[31mred\u001b[0m'), 'red');
});
