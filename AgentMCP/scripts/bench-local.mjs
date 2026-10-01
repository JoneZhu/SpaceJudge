/**
 * Local engineering benchmark for the SpaceJudge stdio MCP adapter.
 *
 * Creates its own temporary fixture, exercises the official MCP client over
 * stdio, and prints one JSON object with the fixture shape, scan time, adapter
 * RSS, `list_children` latency (P50/P95/max) and task-root cleanup, plus
 * pass/fail against the documented budgets. It is intentionally not part of
 * `npm test`.
 *
 * Run with: npm run bench:local
 */
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport, getDefaultEnvironment } from '@modelcontextprotocol/client/stdio';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { resolveCliPath } from '../dist/server.js';

const DIRECTORY_COUNT = 200;
const FILES_PER_DIRECTORY = 100;
const QUERY_SAMPLES = 100;
const RSS_BUDGET_MIB = 150;
const P95_BUDGET_MS = 100;
const LEAKED_TASK_ROOTS_BUDGET = 0;

const serverEntry = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  '..',
  'dist',
  'server.js',
);

function createFixture() {
  const base = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'sj-bench-'));
  const root = path.join(base, 'root');
  fs.mkdirSync(root, { recursive: true });
  for (let directory = 0; directory < DIRECTORY_COUNT; directory += 1) {
    const folder = path.join(root, `d${directory}`);
    fs.mkdirSync(folder, { recursive: true });
    for (let file = 0; file < FILES_PER_DIRECTORY; file += 1) {
      fs.writeFileSync(path.join(folder, `f${file}.bin`), 'x'.repeat(64));
    }
  }
  return { base, root };
}

function rssMiB(pid) {
  const raw = execFileSync('/bin/ps', ['-o', 'rss=', '-p', String(pid)]).toString().trim();
  return Number(raw) / 1024;
}

function percentile(sorted, fraction) {
  if (sorted.length === 0) return 0;
  const index = Math.min(sorted.length - 1, Math.floor(fraction * sorted.length));
  return sorted[index];
}

/** Names of this task's server task roots currently under the OS temp dir. */
function listTaskRoots() {
  const base = fs.realpathSync(os.tmpdir());
  return new Set(
    fs.readdirSync(base).filter((name) => name.startsWith('spacejudge-mcp-')),
  );
}

/** Waits until `pid` no longer exists, returning whether it exited in time. */
async function waitForProcessExit(pid, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try {
      process.kill(pid, 0);
    } catch {
      return true;
    }
    if (Date.now() > deadline) return false;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
}

async function main() {
  const taskRootsBefore = listTaskRoots();
  const fixture = createFixture();
  const cliPath = resolveCliPath();
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverEntry, '--allow-root', fixture.root, '--cli-path', cliPath],
    stderr: 'pipe',
    // Pin TMPDIR so the benchmark's task-root leak check inspects the same
    // temp dir the spawned server uses.
    env: { ...getDefaultEnvironment(), TMPDIR: fs.realpathSync(os.tmpdir()) },
  });
  const client = new Client({ name: 'spacejudge-bench', version: '1.0.0' });
  let serverPid = null;
  let leakedTaskRoots = [];
  let report;
  try {
    await client.connect(transport);
    serverPid = transport.pid;
    if (serverPid === null) throw new Error('no server pid');

    const scanStart = performance.now();
    const started = await client.callTool({
      name: 'start_scan',
      arguments: { rootId: 'root-1' },
    });
    const scanId = started.structuredContent.scanId;
    const rootNodeId = started.structuredContent.rootNodeId;
    let status = 'running';
    for (;;) {
      const current = await client.callTool({
        name: 'get_scan_status',
        arguments: { scanId },
      });
      status = current.structuredContent.status;
      if (status === 'completed' || status === 'cancelled' || status === 'failed') break;
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    const scanMs = performance.now() - scanStart;
    const rssAfterScanMiB = rssMiB(serverPid);

    const latencies = [];
    for (let sample = 0; sample < QUERY_SAMPLES; sample += 1) {
      const queryStart = performance.now();
      await client.callTool({
        name: 'list_children',
        arguments: { scanId, nodeId: rootNodeId, limit: 100 },
      });
      latencies.push(performance.now() - queryStart);
    }
    latencies.sort((left, right) => left - right);
    const rssAfterQueriesMiB = rssMiB(serverPid);

    report = {
      fixture: {
        directories: DIRECTORY_COUNT,
        filesPerDirectory: FILES_PER_DIRECTORY,
        entries: DIRECTORY_COUNT * FILES_PER_DIRECTORY,
      },
      terminalStatus: status,
      scanMs: Number(scanMs.toFixed(1)),
      rssAfterScanMiB: Number(rssAfterScanMiB.toFixed(1)),
      rssAfterQueriesMiB: Number(rssAfterQueriesMiB.toFixed(1)),
      querySamples: QUERY_SAMPLES,
      queryP50Ms: Number(percentile(latencies, 0.5).toFixed(2)),
      queryP95Ms: Number(percentile(latencies, 0.95).toFixed(2)),
      queryMaxMs: Number(latencies.at(-1).toFixed(2)),
    };
  } finally {
    try {
      await client.close();
    } catch {
      // Best effort.
    }
    if (serverPid !== null) {
      await waitForProcessExit(serverPid);
    }
    leakedTaskRoots = [...listTaskRoots()].filter((name) => !taskRootsBefore.has(name));
    fs.rmSync(fixture.base, { recursive: true, force: true });
  }

  if (report === undefined) {
    report = { passed: false };
  }
  report.leakedTaskRoots = leakedTaskRoots;
  report.budgets = {
    terminalStatus: 'completed',
    rssMiB: RSS_BUDGET_MIB,
    queryP95Ms: P95_BUDGET_MS,
    leakedTaskRoots: LEAKED_TASK_ROOTS_BUDGET,
  };
  report.passed =
    report.terminalStatus === 'completed' &&
    report.rssAfterQueriesMiB < RSS_BUDGET_MIB &&
    report.queryP95Ms < P95_BUDGET_MS &&
    report.leakedTaskRoots.length === LEAKED_TASK_ROOTS_BUDGET;

  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  if (!report.passed) {
    process.exitCode = 1;
  }
}

await main();
