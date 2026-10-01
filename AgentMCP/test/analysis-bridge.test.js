import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';
import { validateReport, loadReport } from '../dist/analysis-report.js';
import { analyze, prepareHome, safeEnvironment, SAFE_CONFIG } from '../dist/agent-bridge.js';
import { AcpPeer } from '../dist/acp-peer.js';
const fixture = fileURLToPath(new URL('./fixtures/fake-acp.mjs', import.meta.url));
const server = fileURLToPath(new URL('../dist/report-server.js', import.meta.url));
const rootNode = { nodeId: '1', name: 'Docker', nameTruncated: false, kind: 'directory', flags: 0,
  attributed: { bytes: '18446744073709551615', gb: '18446744073.71' }, aggregateComplete: true };
const report = () => ({ schemaVersion: 1, scanId: '11111111-1111-4111-8111-111111111111',
  revision: '9007199254740993', scanStatus: 'completed', capturedAt: '2026-10-01T01:00:00Z',
  scopeNodeId: '1', metric: 'attributedBytes', nodes: [rootNode], pages: [],
  captureTruncated: true, scanIssueCount: '2', scanInaccessibleCount: '1' });
const temporary = () => fs.mkdtempSync(path.join(os.tmpdir(), 'sj-analysis-test-'));

test('Report rejects paths, size mismatch, active scans, disconnected graph and false coverage', () => {
  assert.equal(validateReport(report()).revision, '9007199254740993');
  assert.throws(() => validateReport({ ...report(), path: '/secret' }));
  assert.throws(() => validateReport({ ...report(), scanStatus: 'running' }));
  assert.throws(() => validateReport({ ...report(), captureTruncated: false }));
  assert.throws(() => validateReport({ ...report(), nodes: [{ ...rootNode, attributed: { bytes: '1', gb: '2.00' } }] }));
  assert.throws(() => validateReport({ ...report(), nodes: [rootNode, { ...rootNode, nodeId: '2', parentId: '3' }] }));
});

test('Report MCP advertises exactly three read-only tools and uncaptured is not zero', async () => {
  const dir = temporary(); const reportPath = path.join(dir, 'report.json');
  fs.writeFileSync(reportPath, JSON.stringify(report()));
  const transport = new StdioClientTransport({ command: process.execPath, args: [server, '--report', reportPath], stderr: 'pipe' });
  transport.stderr?.on('data', () => {});
  const client = new Client({ name: 'sj-analysis-test', version: '1' });
  try {
    await client.connect(transport);
    const tools = (await client.listTools()).tools;
    assert.equal(tools.length, 3);
    assert.ok(tools.every(t => t.annotations?.readOnlyHint && !t.annotations?.destructiveHint));
    const scope = await client.callTool({ name: 'spacejudge_scope', arguments: {} });
    assert.equal(scope.structuredContent.scope.attributed.bytes, '18446744073709551615');
    const children = await client.callTool({ name: 'spacejudge_children', arguments: { nodeId: '1' } });
    assert.equal(children.structuredContent.captured, false);
    assert.equal(children.structuredContent.items, null);
    const unknown = await client.callTool({ name: 'spacejudge_children', arguments: { nodeId: '42' } });
    assert.equal(unknown.isError, true);
    const pathInjection = await client.callTool({ name: 'spacejudge_children', arguments: { nodeId: '1', path: '/secret' } });
    assert.equal(pathInjection.isError, true);
  } finally { await client.close(); fs.rmSync(dir, { recursive: true, force: true }); }
});

test('Report loader rejects symlinks and oversized files', () => {
  const dir = temporary();
  try {
    const file = path.join(dir, 'report.json'); fs.writeFileSync(file, JSON.stringify(report()));
    const link = path.join(dir, 'link'); fs.symlinkSync(file, link);
    assert.throws(() => loadReport(link));
    fs.truncateSync(file, 4 * 1024 * 1024 + 1); assert.throws(() => loadReport(file));
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('Dedicated config is immutable and environment drops inherited credentials/config', () => {
  const dir = temporary();
  try {
    const home = prepareHome(dir); const env = safeEnvironment(home);
    assert.equal(env.INITIAL_AGENT_MODE, 'read-only');
    assert.equal(env.CODEX_HOME, home);
    assert.equal(env.CODEX_CONFIG, undefined); assert.equal(env.CODEX_PATH, undefined);
    assert.equal(env.OPENAI_API_KEY, undefined); assert.equal(env.CODEX_API_KEY, undefined);
    fs.mkdirSync(path.join(home, 'skills', '.system'), { recursive: true });
    fs.mkdirSync(path.join(home, 'plugins'));
    assert.equal(prepareHome(dir), home); // Codex-generated resources are reusable.
    fs.mkdirSync(path.join(home, 'skills', 'custom-pack'));
    assert.throws(() => prepareHome(dir));
    fs.rmdirSync(path.join(home, 'skills', 'custom-pack'));
    fs.writeFileSync(path.join(home, 'plugins', 'unexpected'), 'fixture');
    assert.throws(() => prepareHome(dir));
    fs.unlinkSync(path.join(home, 'plugins', 'unexpected'));
    fs.writeFileSync(path.join(home, 'config.toml'), SAFE_CONFIG + '\n# changed');
    assert.throws(() => prepareHome(dir));
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('ACP streams messages, always denies permission and refuses filesystem methods', async () => {
  const updates = []; const peer = new AcpPeer(process.execPath, [fixture], os.tmpdir(), {}, p => updates.push(p));
  try {
    assert.equal((await peer.request('initialize', {})).protocolVersion, 1);
    assert.equal((await peer.request('session/new', {})).modes.currentModeId, 'read-only');
    assert.equal((await peer.request('session/prompt', {})).stopReason, 'end_turn');
    assert.equal(updates[0].update.content.text, 'fixture result');
  } finally { await peer.stop(); }
});

for (const method of ['oversized', 'malformed', 'crash', 'hang']) {
  test(`ACP fails closed on ${method} and tears down`, async () => {
    const peer = new AcpPeer(process.execPath, [fixture], os.tmpdir(), {}, () => {});
    try { await assert.rejects(peer.request(method, {}, 500)); }
    finally { await peer.stop(); }
  });
}

test('Bridge runs ACP → real report MCP → streaming answer, then deletes frozen report', async () => {
  const dir = temporary(); const events = []; let jobDir;
  const file = path.join(dir, 'report.json'); fs.writeFileSync(file, JSON.stringify(report()));
  try {
    await analyze(file, path.join(dir, 'state'), {
      makePeer(command, args, cwd, env, update) {
        jobDir = cwd;
        assert.equal(env.INITIAL_AGENT_MODE, 'read-only');
        assert.equal(fs.statSync(cwd).mode & 0o777, 0o700);
        assert.equal(fs.statSync(path.join(cwd, 'report.json')).mode & 0o777, 0o600);
        return new AcpPeer(command, [fixture, '--mcp'], cwd, env, update);
      },
      onEvent(type, text) { events.push({ type, text }); },
    });
    const scope = JSON.parse(events.find(e => e.type === 'delta').text);
    assert.equal(scope.revision, report().revision);
    assert.equal(scope.scope.name, 'Docker');
    assert.ok(events.some(e => e.type === 'done'));
    assert.equal(fs.existsSync(jobDir), false);
    assert.equal(fs.existsSync(file), true); // caller's input is preserved
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('Bridge refuses a non-read-only agent before any prompt, cleans its job', async () => {
  const dir = temporary(); let jobDir; const methods = [];
  const file = path.join(dir, 'report.json'); fs.writeFileSync(file, JSON.stringify(report()));
  try {
    await assert.rejects(analyze(file, path.join(dir, 'state'), {
      makePeer(command, args, cwd, env, update) {
        jobDir = cwd;
        const peer = new AcpPeer(command, [fixture, '--write'], cwd, env, update);
        const request = peer.request.bind(peer);
        peer.request = (...args) => { methods.push(args[0]); return request(...args); };
        return peer;
      }, onEvent() {},
    }), /read-only/);
    assert.ok(!methods.includes('session/prompt'));
    assert.equal(fs.existsSync(jobDir), false);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('Bridge cleans frozen report even if spawning fails synchronously', async () => {
  const dir = temporary(); let jobDir;
  const file = path.join(dir, 'report.json'); fs.writeFileSync(file, JSON.stringify(report()));
  try {
    await assert.rejects(analyze(file, path.join(dir, 'state'), {
      makePeer(command, args, cwd) { jobDir = cwd; throw new Error('fixture spawn failure'); }, onEvent() {},
    }), /spawn failure/);
    assert.equal(fs.existsSync(jobDir), false);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
