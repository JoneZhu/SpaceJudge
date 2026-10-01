import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { LineScanner, ScanProcess } from '../dist/native-client.js';
import { createRedactor } from '../dist/redaction.js';

test('LineScanner fails closed on an overlong line and ignores later data', () => {
  const lines = [];
  let overflows = 0;
  const scanner = new LineScanner(
    16,
    (line) => lines.push(line),
    () => {
      overflows += 1;
    },
  );
  scanner.push(Buffer.from(`${'x'.repeat(32)}\n`));
  assert.equal(overflows, 1);
  // A valid event after the overflow must never be delivered.
  scanner.push(Buffer.from('{"type":"started"}\n'));
  scanner.flush();
  assert.deepEqual(lines, []);
  assert.equal(overflows, 1);
  assert.equal(scanner.hasOverflowed, true);
});

test('LineScanner enforces the cap in bytes, not UTF-16 units', () => {
  const lines = [];
  let overflows = 0;
  // Four 3-byte emoji exceed a 10-byte cap even though their character count is 4.
  const scanner = new LineScanner(
    10,
    (line) => lines.push(line),
    () => {
      overflows += 1;
    },
  );
  scanner.push(Buffer.from('😀😀😀😀\n'));
  assert.equal(overflows, 1);
  assert.deepEqual(lines, []);
});

test('an overlong stdout line fails the scan and cannot be followed by started', async () => {
  const base = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'sj-linecap-'));
  const script = path.join(base, 'fake-cli.mjs');
  fs.writeFileSync(
    script,
    [
      "process.stdout.write('x'.repeat(2 * 1024 * 1024));",
      "process.stdout.write('\\n');",
      "process.stdout.write(JSON.stringify({ type: 'started', scanId: '11111111-1111-1111-1111-111111111111', rootNodeId: '1' }) + '\\n');",
      'setTimeout(() => {}, 5000);',
    ].join('\n'),
  );
  const scanProcess = new ScanProcess(
    process.execPath,
    [script],
    createRedactor([base]),
  );
  try {
    await assert.rejects(scanProcess.started);
    const terminal = await scanProcess.done;
    assert.equal(terminal.status, 'failed');
    assert.equal(terminal.code, 'INTERNAL');
  } finally {
    scanProcess.forceKill();
    fs.rmSync(base, { recursive: true, force: true });
  }
});
