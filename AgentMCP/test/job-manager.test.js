import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import { JobManager } from '../dist/jobs.js';
import { createRedactor } from '../dist/redaction.js';
import {
  CLI_PATH,
  createFixture,
  processesMentioning,
  sleep,
} from './helpers.js';

test('task directories are bounded and the instance task root is removed on shutdown', async () => {
  const fixture = createFixture();
  const manager = new JobManager(
    CLI_PATH,
    new Map([
      [
        'root-1',
        { rootId: 'root-1', canonicalPath: fixture.root, displayName: 'root' },
      ],
    ]),
    createRedactor([fixture.root, CLI_PATH]),
  );
  const observed = [];
  try {
    for (let index = 0; index < 10; index += 1) {
      const started = await manager.startScan('root-1');
      const deadline = Date.now() + 30_000;
      for (;;) {
        const status = manager.getStatus(started.scanId).status;
        if (status === 'completed' || status === 'cancelled' || status === 'failed') break;
        assert.ok(Date.now() < deadline, `scan ${index} did not settle`);
        await sleep(20);
      }
      observed.push(fs.readdirSync(manager.taskRootPath).length);
    }
    assert.ok(
      Math.max(...observed) <= 2,
      `task directories grew across scans: ${observed.join(',')}`,
    );
    assert.ok(fs.existsSync(manager.taskRootPath));
  } finally {
    await manager.shutdown();
  }
  assert.equal(fs.existsSync(manager.taskRootPath), false);
  assert.deepEqual(processesMentioning(fixture.root), []);
  fixture.cleanup();
});
