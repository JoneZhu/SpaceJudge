// Local synthetic report smoke. Never logs in or sends a model prompt.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';
const args = process.argv.slice(2);
if (args.length !== 2 || args[0] !== '--runtime' || !path.isAbsolute(args[1])) {
  throw new Error('Usage: check-packaged-runtime.mjs --runtime ABSOLUTE_RUNTIME_DIR');
}
const runtime = args[1];
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sj-package-report-check-'));
const reportPath = path.join(root, 'report.json');
fs.writeFileSync(reportPath, JSON.stringify({
  schemaVersion: 1, scanId: '11111111-1111-4111-8111-111111111111', revision: '1',
  scanStatus: 'completed', capturedAt: '2026-10-01T01:00:00Z', scopeNodeId: '1',
  metric: 'attributedBytes', captureTruncated: false, scanIssueCount: '0', scanInaccessibleCount: '0',
  nodes: [{ nodeId: '1', name: 'Synthetic Package Check', nameTruncated: false,
    kind: 'directory', flags: 0, attributed: { bytes: '0', gb: '0.00' }, aggregateComplete: true }],
  pages: [{ nodeId: '1', totalChildren: '0', childIds: [], truncated: false }],
}), { mode: 0o600 });
const transport = new StdioClientTransport({ command: process.execPath,
  args: [path.join(runtime, 'dist/report-server.js'), '--report', reportPath], stderr: 'pipe' });
transport.stderr?.on('data', () => {});
const client = new Client({ name: 'SpaceJudge-packaged-runtime-check', version: '0.5.0' });
try {
  await client.connect(transport);
  const tools = (await client.listTools()).tools;
  assert.equal(tools.length, 3);
  assert.ok(tools.every(t => t.annotations?.readOnlyHint && !t.annotations?.destructiveHint));
  const scope = await client.callTool({ name: 'spacejudge_scope', arguments: {} });
  assert.equal(scope.structuredContent.scope.name, 'Synthetic Package Check');
  assert.equal(scope.structuredContent.scope.attributed.bytes, '0');
  const children = await client.callTool({ name: 'spacejudge_children', arguments: { nodeId: '1' } });
  assert.equal(children.structuredContent.captured, true);
  assert.deepEqual(children.structuredContent.items, []);
  console.log(JSON.stringify({ packagedMcpTools: tools.map(t => t.name), syntheticScopeVerified: true,
    node: process.version, architecture: process.arch, noPromptSent: true }));
} finally {
  await client.close();
  fs.rmSync(root, { recursive: true, force: true });
}
await import('./check-acp.mjs');
