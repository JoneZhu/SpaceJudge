import assert from 'node:assert/strict';
import test from 'node:test';
import {
  connectServer,
  createFixture,
  listTaskRoots,
  waitForProcessExit,
  waitForTerminal,
} from './helpers.js';

/**
 * Real-server lifecycle: an official client over stdio, a completed or
 * cancelled scan, then `client.close()` (stdin EOF). The server process must
 * exit and remove its `spacejudge-mcp-*` task root without any signal.
 */

test('stdio EOF after a completed scan reaps the server task root', async () => {
  const fixture = createFixture();
  const before = listTaskRoots();
  const server = await connectServer([fixture.root]);
  const pid = server.transport.pid;
  let createdDuringRun = false;
  try {
    const started = await server.client.callTool({
      name: 'start_scan',
      arguments: { rootId: 'root-1' },
    });
    const scanId = started.structuredContent.scanId;
    const terminal = await waitForTerminal(server.client, scanId);
    assert.equal(terminal.status, 'completed');
    createdDuringRun = [...listTaskRoots()].some((name) => !before.has(name));
  } finally {
    await server.close();
  }
  assert.equal(await waitForProcessExit(pid), true, 'server process did not exit');
  assert.equal(createdDuringRun, true, 'server never created a task root');
  const leaked = [...listTaskRoots()].filter((name) => !before.has(name));
  assert.deepEqual(leaked, [], `leaked task roots: ${leaked.join(',')}`);
  fixture.cleanup();
});

test('stdio EOF after a cancelled scan reaps the server task root', async () => {
  const fixture = createFixture({ files: 4000 });
  const before = listTaskRoots();
  const server = await connectServer([fixture.root]);
  const pid = server.transport.pid;
  let createdDuringRun = false;
  try {
    const started = await server.client.callTool({
      name: 'start_scan',
      arguments: { rootId: 'root-1' },
    });
    const scanId = started.structuredContent.scanId;
    createdDuringRun = [...listTaskRoots()].some((name) => !before.has(name));
    const cancelled = await server.client.callTool({
      name: 'cancel_scan',
      arguments: { scanId },
    });
    assert.ok(['cancelling', 'cancelled', 'completed'].includes(cancelled.structuredContent.status));
    await waitForTerminal(server.client, scanId);
  } finally {
    await server.close();
  }
  assert.equal(await waitForProcessExit(pid), true, 'server process did not exit');
  assert.equal(createdDuringRun, true, 'server never created a task root');
  const leaked = [...listTaskRoots()].filter((name) => !before.has(name));
  assert.deepEqual(leaked, [], `leaked task roots: ${leaked.join(',')}`);
  fixture.cleanup();
});

test('SIGTERM reaps the server task root through the same cleanup path', async () => {
  const fixture = createFixture({ files: 4000 });
  const before = listTaskRoots();
  const server = await connectServer([fixture.root]);
  const pid = server.transport.pid;
  let createdDuringRun = false;
  try {
    const started = await server.client.callTool({
      name: 'start_scan',
      arguments: { rootId: 'root-1' },
    });
    assert.equal(started.isError, undefined);
    createdDuringRun = [...listTaskRoots()].some((name) => !before.has(name));
    process.kill(pid, 'SIGTERM');
    assert.equal(await waitForProcessExit(pid), true, 'server did not exit on SIGTERM');
  } finally {
    await server.close().catch(() => {});
  }
  assert.equal(createdDuringRun, true, 'server never created a task root');
  const leaked = [...listTaskRoots()].filter((name) => !before.has(name));
  assert.deepEqual(leaked, [], `leaked task roots: ${leaked.join(',')}`);
  fixture.cleanup();
});
