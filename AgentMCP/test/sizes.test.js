import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { CLI_PATH } from './helpers.js';
import { gigabytes } from '../dist/sizes.js';

// The frozen boundary table from docs/29-phase-6-dual-size-output.md. The
// Swift formatter is asserted against the exact same table.
const TABLE = [
  ['0', '0.00'],
  ['4999999', '0.00'],
  ['5000000', '0.01'],
  ['999999999', '1.00'],
  ['1000000000', '1.00'],
  ['1005000000', '1.01'],
  ['18446744073709551615', '18446744073.71'],
];

test('gigabytes matches the frozen boundary table', () => {
  for (const [bytes, expected] of TABLE) {
    assert.equal(gigabytes(bytes), expected, `${bytes} -> ${expected}`);
  }
});

test('gigabytes handles the null and malformed contract', () => {
  assert.equal(gigabytes(null), null);
  assert.equal(gigabytes(''), null);
  assert.equal(gigabytes('not-a-number'), null);
  assert.equal(gigabytes('-1'), null);
  assert.equal(gigabytes('18446744073709551616'), null, 'above UInt64');
});

test('gigabytes never uses floating point and stays locale independent', () => {
  // A value that would lose precision as a JS Number still rounds exactly.
  assert.equal(gigabytes('9007199254740993'), '9007199.25');
  assert.match(gigabytes('18446744073709551615'), /^\d+\.\d{2}$/);
});

test('the Swift CLI and the MCP formatter agree on real volume facts', () => {
  const root = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'sj-size-check-'));
  try {
    const result = spawnSync(CLI_PATH, ['volume', '--root', root], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    const parsed = JSON.parse(result.stdout.trim());
    for (const prefix of ['capacity', 'available', 'used']) {
      const bytes = parsed[`${prefix}Bytes`];
      const gb = parsed[`${prefix}GB`];
      if (bytes === null) {
        assert.equal(gb, null);
      } else {
        assert.equal(gb, gigabytes(bytes), `${prefix}GB must project ${prefix}Bytes`);
        assert.match(gb, /^\d+\.\d{2}$/);
      }
    }
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
