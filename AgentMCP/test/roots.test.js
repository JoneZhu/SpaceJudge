import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { parseAllowedRoots, sanitizeDisplayName, RootConfigError } from '../dist/roots.js';
import { createRedactor } from '../dist/redaction.js';
import { removeSymlink } from './helpers.js';

function tempDir() {
  return fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'sj-roots-'));
}

test('parseAllowedRoots assigns opaque IDs in order and dedupes', () => {
  const first = tempDir();
  const second = tempDir();
  try {
    const roots = parseAllowedRoots([first, second, first]);
    assert.equal(roots.length, 2);
    assert.equal(roots[0].rootId, 'root-1');
    assert.equal(roots[1].rootId, 'root-2');
    assert.equal(roots[0].canonicalPath, fs.realpathSync(first));
  } finally {
    fs.rmSync(first, { recursive: true, force: true });
    fs.rmSync(second, { recursive: true, force: true });
  }
});

test('parseAllowedRoots rejects a relative path without echoing it', () => {
  assert.throws(
    () => parseAllowedRoots(['relative/path']),
    (error) => error instanceof RootConfigError && !error.message.includes('relative/path'),
  );
});

test('parseAllowedRoots rejects a missing path without echoing it', () => {
  const missing = path.join(fs.realpathSync(os.tmpdir()), 'sj-missing-do-not-create');
  assert.throws(
    () => parseAllowedRoots([missing]),
    (error) => error instanceof RootConfigError && !error.message.includes('sj-missing'),
  );
});

test('parseAllowedRoots rejects a symlinked root', () => {
  const real = tempDir();
  const link = path.join(fs.realpathSync(os.tmpdir()), `sj-link-${Date.now()}`);
  fs.symlinkSync(real, link);
  try {
    assert.throws(
      () => parseAllowedRoots([link]),
      (error) => error instanceof RootConfigError && error.message.includes('symbolic link'),
    );
  } finally {
    removeSymlink(link);
    fs.rmSync(real, { recursive: true, force: true });
  }
});

test('parseAllowedRoots accepts 64 unique roots and rejects 65', () => {
  const base = tempDir();
  try {
    const dirs = [];
    for (let index = 0; index < 65; index += 1) {
      const directory = path.join(base, `r${index}`);
      fs.mkdirSync(directory);
      dirs.push(directory);
    }
    assert.equal(parseAllowedRoots(dirs.slice(0, 64)).length, 64);
    assert.throws(
      () => parseAllowedRoots(dirs),
      (error) => error instanceof RootConfigError && !error.message.includes(base),
    );
  } finally {
    fs.rmSync(base, { recursive: true, force: true });
  }
});

test('sanitizeDisplayName strips control characters and bounds length', () => {
  assert.equal(sanitizeDisplayName('bad\nname', 1), 'bad name');
  assert.equal(sanitizeDisplayName('   ', 2), 'root-2');
  assert.equal(sanitizeDisplayName('', 3), 'root-3');
  const long = 'x'.repeat(500);
  assert.ok(sanitizeDisplayName(long, 1).length <= 128);
});

test('createRedactor removes explicit secrets and generic home paths', () => {
  const redactor = createRedactor(['/private/tmp/sj-secret-dir', 'exampleuser']);
  const output = redactor.redact(
    'failed at /private/tmp/sj-secret-dir/db and /Users/exampleuser/Documents',
  );
  assert.ok(!output.includes('/private/tmp/sj-secret-dir'));
  assert.ok(!output.includes('/Users/exampleuser'));
  assert.ok(output.includes('[redacted]'));
});
