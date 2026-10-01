import assert from 'node:assert/strict';
import test from 'node:test';
import {
  connectServer,
  createFixture,
  processesMentioning,
  waitForTerminal,
} from './helpers.js';

test('ten sequential scans leave no orphan processes', async () => {
  const fixture = createFixture();
  const server = await connectServer([fixture.root]);
  try {
    const scanIds = [];
    for (let index = 0; index < 10; index += 1) {
      const started = await server.client.callTool({
        name: 'start_scan',
        arguments: { rootId: 'root-1' },
      });
      assert.equal(started.isError, undefined, `start ${index}`);
      const scanId = started.structuredContent.scanId;
      scanIds.push(scanId);
      const terminal = await waitForTerminal(server.client, scanId);
      assert.equal(terminal.status, 'completed', `scan ${index}`);
    }
    assert.equal(new Set(scanIds).size, 10);
  } finally {
    await server.close();
  }
  try {
    // The fixture path appears in the CLI argv; nothing should still mention it.
    assert.deepEqual(processesMentioning(fixture.root), []);
  } finally {
    fixture.cleanup();
  }
});

test('a second concurrent scan conflicts and cancellation is idempotent', async () => {
  const fixture = createFixture({ files: 4000 });
  const server = await connectServer([fixture.root]);
  try {
    const first = await server.client.callTool({
      name: 'start_scan',
      arguments: { rootId: 'root-1' },
    });
    assert.equal(first.isError, undefined);
    const scanId = first.structuredContent.scanId;

    const second = await server.client.callTool({
      name: 'start_scan',
      arguments: { rootId: 'root-1' },
    });
    assert.equal(second.isError, true, 'concurrent start must conflict');

    const cancelled = await server.client.callTool({
      name: 'cancel_scan',
      arguments: { scanId },
    });
    assert.ok(['cancelling', 'cancelled', 'completed'].includes(cancelled.structuredContent.status));

    // Repeating cancel is safe and returns the same terminal status.
    const again = await server.client.callTool({
      name: 'cancel_scan',
      arguments: { scanId },
    });
    assert.equal(again.isError, undefined);

    const terminal = await waitForTerminal(server.client, scanId);
    assert.ok(['cancelled', 'completed'].includes(terminal.status));

    const third = await server.client.callTool({
      name: 'cancel_scan',
      arguments: { scanId },
    });
    assert.equal(third.structuredContent.status, terminal.status);
  } finally {
    await server.close();
    fixture.cleanup();
  }
});

test('a new scan can start after the previous terminal', async () => {
  const fixture = createFixture({ files: 2000 });
  const server = await connectServer([fixture.root]);
  try {
    const first = await server.client.callTool({
      name: 'start_scan',
      arguments: { rootId: 'root-1' },
    });
    const firstId = first.structuredContent.scanId;
    await server.client.callTool({ name: 'cancel_scan', arguments: { scanId: firstId } });
    await waitForTerminal(server.client, firstId);

    const second = await server.client.callTool({
      name: 'start_scan',
      arguments: { rootId: 'root-1' },
    });
    assert.equal(second.isError, undefined);
    const secondId = second.structuredContent.scanId;
    await waitForTerminal(server.client, secondId);

    // The previous terminal job was cleaned when the new scan started.
    const oldStatus = await server.client.callTool({
      name: 'get_scan_status',
      arguments: { scanId: firstId },
    });
    assert.equal(oldStatus.isError, true);
  } finally {
    await server.close();
    fixture.cleanup();
  }
});
