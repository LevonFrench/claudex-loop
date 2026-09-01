import assert from 'node:assert/strict';
import test from 'node:test';
import { PLUGIN_VERSION, normalizeLabel, requireText, stripAnsi } from '../server/runtime.mjs';

test('normalizes valid labels and rejects path/control ambiguity', () => {
  assert.equal(normalizeLabel('  claude:builder  '), 'claude:builder');
  assert.throws(() => normalizeLabel('builder/other'), /path separator/);
  assert.throws(() => normalizeLabel('CON'), /reserved Windows device/);
  assert.throws(() => normalizeLabel('bad\u202ename'), /direction override/);
});

test('message size is bounded and ANSI is removed from viewer output', () => {
  assert.equal(requireText('hello'), 'hello');
  assert.throws(() => requireText('x'.repeat(65537)), /exceeds/);
  assert.equal(stripAnsi('\u001b[31mred\u001b[0m'), 'red');
});

test('every terminal control family is stripped from untrusted peer output', () => {
  assert.equal(stripAnsi('a\u001bcb'), 'ab', 'ESC c full reset');
  assert.equal(stripAnsi('a\u001bPtmux;\u001b\u001b[2J\u001b\\b'), 'ab', 'DCS passthrough string');
  assert.equal(stripAnsi('a\u001b_payload\u001b\\b'), 'ab', 'APC string');
  assert.equal(stripAnsi('a\u001b^pm\u001b\\b'), 'ab', 'PM string');
  assert.equal(stripAnsi('a\u001b]0;title\u0007b'), 'ab', 'OSC with BEL');
  assert.equal(stripAnsi('a\u009b2J\u0085bc'), 'abc', '8-bit C1 controls');
  assert.equal(stripAnsi('a\u0000\u0007\u0008\u007fb'), 'ab', 'C0 controls other than whitespace');
  assert.equal(stripAnsi('keep\ttabs\r\nand\nnewlines'), 'keep\ttabs\r\nand\nnewlines');
  assert.equal(stripAnsi('caf\u00e9 \u2014 \u2713'), 'caf\u00e9 \u2014 \u2713', 'non-ASCII text survives');
});

test('the plugin version comes from package.json', () => {
  assert.match(PLUGIN_VERSION, /^\d+\.\d+\.\d+$/);
});
