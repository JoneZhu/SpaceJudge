import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { ScanProcess } from '../dist/native-client.js';
import { createRedactor } from '../dist/redaction.js';

const SCAN_A = '11111111-1111-1111-1111-111111111111';
const SCAN_B = '22222222-2222-2222-2222-222222222222';

/** Spawns a fake CLI that writes the given NDJSON lines and then exits. */
function spawnFake(lines) {
  const base = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'sj-protocol-'));
  const script = path.join(base, 'fake-cli.mjs');
  const body = lines
    .map((line) => `process.stdout.write(${JSON.stringify(`${JSON.stringify(line)}\n`)});`)
    .join('\n');
  fs.writeFileSync(script, `${body}\n`);
  const child = new ScanProcess(process.execPath, [script], createRedactor([base]));
  return {
    process: child,
    cleanup() {
      child.forceKill();
      fs.rmSync(base, { recursive: true, force: true });
    },
  };
}

async function expectFailed(process) {
  const terminal = await process.done;
  assert.equal(terminal.status, 'failed');
  assert.equal(terminal.code, 'INTERNAL');
}

test('a valid started/progress/terminal sequence succeeds', async () => {
  const { process, cleanup } = spawnFake([
    { type: 'started', scanId: SCAN_A, rootNodeId: '1' },
    { type: 'progress', visitedEntries: '5', persistedNodes: '4', attributedBytes: '100' },
    { type: 'completed', scanId: SCAN_A, status: 'completed', fileCount: '5' },
  ]);
  try {
    const started = await process.started;
    assert.equal(started.scanId, SCAN_A);
    const terminal = await process.done;
    assert.equal(terminal.status, 'completed');
  } finally {
    cleanup();
  }
});

test('a terminal before started fails closed', async () => {
  const { process, cleanup } = spawnFake([
    { type: 'completed', scanId: SCAN_A, status: 'completed' },
  ]);
  try {
    await assert.rejects(process.started);
    await expectFailed(process);
  } finally {
    cleanup();
  }
});

test('a duplicate started fails closed', async () => {
  const { process, cleanup } = spawnFake([
    { type: 'started', scanId: SCAN_A, rootNodeId: '1' },
    { type: 'started', scanId: SCAN_A, rootNodeId: '1' },
  ]);
  try {
    assert.equal((await process.started).scanId, SCAN_A);
    await expectFailed(process);
  } finally {
    cleanup();
  }
});

test('malformed progress fails closed', async () => {
  const { process, cleanup } = spawnFake([
    { type: 'started', scanId: SCAN_A, rootNodeId: '1' },
    { type: 'progress', visitedEntries: 'not-a-number', persistedNodes: '4', attributedBytes: '100' },
  ]);
  try {
    await process.started;
    await expectFailed(process);
  } finally {
    cleanup();
  }
});

test('progress before started fails closed', async () => {
  const { process, cleanup } = spawnFake([
    { type: 'progress', visitedEntries: '1', persistedNodes: '1', attributedBytes: '1' },
    { type: 'started', scanId: SCAN_A, rootNodeId: '1' },
  ]);
  try {
    await assert.rejects(process.started);
    await expectFailed(process);
  } finally {
    cleanup();
  }
});

test('a terminal with a mismatched scanId fails closed', async () => {
  const { process, cleanup } = spawnFake([
    { type: 'started', scanId: SCAN_A, rootNodeId: '1' },
    { type: 'completed', scanId: SCAN_B, status: 'completed' },
  ]);
  try {
    await process.started;
    await expectFailed(process);
  } finally {
    cleanup();
  }
});

test('a duplicate terminal fails closed', async () => {
  const { process, cleanup } = spawnFake([
    { type: 'started', scanId: SCAN_A, rootNodeId: '1' },
    { type: 'completed', scanId: SCAN_A, status: 'completed' },
    { type: 'completed', scanId: SCAN_A, status: 'completed' },
  ]);
  try {
    await process.started;
    await expectFailed(process);
  } finally {
    cleanup();
  }
});

test('an error after started is an INTERNAL protocol failure', async () => {
  const { process, cleanup } = spawnFake([
    { type: 'started', scanId: SCAN_A, rootNodeId: '1' },
    { type: 'error', code: 'INVALID_ARGUMENT' },
  ]);
  try {
    await process.started;
    await expectFailed(process);
  } finally {
    cleanup();
  }
});
