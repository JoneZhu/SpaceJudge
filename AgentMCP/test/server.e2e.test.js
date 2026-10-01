import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  collectStrings,
  connectServer,
  createFixture,
  removeSymlink,
  runServerSync,
  sleep,
  waitForTerminal,
} from './helpers.js';
import { gigabytes } from '../dist/sizes.js';

const EXPECTED_TOOLS = [
  'list_allowed_roots',
  'get_volume_usage',
  'start_scan',
  'get_scan_status',
  'list_children',
  'get_hotspots',
  'get_scan_issues',
  'cancel_scan',
];

test('startup fails without a root and never echoes a path', () => {
  const result = runServerSync([]);
  assert.equal(result.status, 1);
  assert.ok(result.stderr.includes('at least one --allow-root'));
});

test('startup rejects a symlinked root', () => {
  const fixture = createFixture();
  const link = `${fixture.base}-link`;
  try {
    fs.symlinkSync(fixture.root, link);
    const result = runServerSync(['--allow-root', link]);
    assert.equal(result.status, 1);
    assert.ok(result.stderr.includes('symbolic link'));
    assert.ok(!result.stderr.includes(fixture.base));
  } finally {
    removeSymlink(link);
    fixture.cleanup();
  }
});

test('tools/list exposes exactly the eight tools with annotations', async () => {
  const fixture = createFixture();
  const server = await connectServer([fixture.root]);
  try {
    const instructions = server.client.getInstructions() ?? '';
    assert.ok(instructions.toLowerCase().includes('untrusted'));
    assert.ok(instructions.toLowerCase().includes('eight'));
    const tools = await server.client.listTools();
    assert.deepEqual(
      tools.tools.map((tool) => tool.name).sort(),
      [...EXPECTED_TOOLS].sort(),
    );
    for (const tool of tools.tools) {
      assert.equal(tool.annotations?.openWorldHint, false, `${tool.name} openWorldHint`);
      assert.equal(tool.annotations?.destructiveHint, false, `${tool.name} destructiveHint`);
    }
    const readOnly = new Set([
      'list_allowed_roots',
      'get_volume_usage',
      'get_scan_status',
      'list_children',
      'get_hotspots',
      'get_scan_issues',
    ]);
    for (const tool of tools.tools) {
      assert.equal(
        tool.annotations?.readOnlyHint,
        readOnly.has(tool.name),
        `${tool.name} readOnlyHint`,
      );
    }
  } finally {
    await server.close();
    fixture.cleanup();
  }
});

test('published output schemas carry the contract constraints', async () => {
  const fixture = createFixture();
  const server = await connectServer([fixture.root]);
  try {
    const tools = await server.client.listTools();
    const byName = new Map(tools.tools.map((tool) => [tool.name, tool]));
    const output = (name) => byName.get(name).outputSchema;
    const objectBranch = (schema) =>
      schema.anyOf ? schema.anyOf.find((branch) => branch.type === 'object') : schema;
    const stringBranch = (schema) =>
      schema.anyOf ? schema.anyOf.find((branch) => branch.type === 'string') : schema;
    const integerBranch = (schema) =>
      schema.anyOf ? schema.anyOf.find((branch) => branch.type === 'integer') : schema;
    const nullable = (schema) =>
      Array.isArray(schema.anyOf) && schema.anyOf.some((branch) => branch.type === 'null');
    for (const name of EXPECTED_TOOLS) {
      assert.equal(
        output(name).additionalProperties,
        false,
        `${name} output additionalProperties`,
      );
    }

    const roots = output('list_allowed_roots');
    assert.equal(roots.properties.roots.maxItems, 64);
    assert.match(roots.properties.roots.items.properties.rootId.pattern, /\^root-/);
    assert.equal(roots.properties.roots.items.additionalProperties, false);

    const volume = output('get_volume_usage');
    assert.ok(nullable(volume.properties.capacityBytes));
    assert.ok(stringBranch(volume.properties.capacityBytes).pattern !== undefined);
    assert.ok(nullable(volume.properties.capacityGB));
    assert.ok(stringBranch(volume.properties.capacityGB).pattern !== undefined);
    assert.ok(nullable(volume.properties.availableGB));
    assert.ok(nullable(volume.properties.usedGB));

    const started = output('start_scan');
    assert.ok(started.properties.scanId.pattern.includes('0-9a-fA-F'));
    assert.ok(started.properties.rootNodeId.pattern.includes('\\d'));

    const status = output('get_scan_status');
    assert.ok(status.properties.status.enum.includes('completed'));
    const statusProgress = objectBranch(status.properties.progress);
    assert.equal(statusProgress.additionalProperties, false);
    assert.ok(nullable(statusProgress.properties.attributedGB) === false);
    assert.ok(stringBranch(statusProgress.properties.attributedGB).pattern !== undefined);
    const terminal = objectBranch(status.properties.terminal);
    assert.equal(terminal.additionalProperties, false);
    assert.ok(terminal.properties.status.enum.includes('cancelled'));
    assert.ok(nullable(terminal.properties.rootAttributedGB));

    const children = output('list_children');
    assert.equal(children.properties.items.maxItems, 100);
    assert.equal(children.properties.limit.maximum, 100);
    const childItem = children.properties.items.items;
    assert.ok(childItem.properties.nodeId.pattern.includes('\\d'));
    assert.equal(childItem.properties.name.maxLength, 1024);
    assert.equal(childItem.properties.nameBase64.maxLength, 2048);
    assert.equal(childItem.properties.flags.maxItems, 11);
    assert.ok(nullable(childItem.properties.parentId));
    assert.ok(nullable(childItem.properties.logicalGB));
    assert.ok(nullable(childItem.properties.allocatedGB));
    assert.ok(stringBranch(childItem.properties.attributedGB).pattern !== undefined);
    assert.ok(
      stringBranch(childItem.properties.effectiveAttributedGB).pattern !== undefined,
    );

    const hotspots = output('get_hotspots');
    assert.equal(hotspots.properties.items.maxItems, 50);
    assert.equal(hotspots.properties.limit.maximum, 50);
    assert.equal(hotspots.properties.limit.minimum, 1);
    assert.equal(hotspots.properties.overlapSemantics.const, 'ancestorInclusive');
    assert.ok(nullable(hotspots.properties.snapshotComplete) === false);
    assert.equal(hotspots.properties.snapshotComplete.type, 'boolean');
    assert.equal(hotspots.properties.truncated.type, 'boolean');
    assert.ok(stringBranch(hotspots.properties.minimumGB).pattern !== undefined);
    const hotspotItem = hotspots.properties.items.items;
    assert.equal(hotspotItem.additionalProperties, false);
    assert.equal(hotspotItem.properties.depth.type, 'integer');
    assert.equal(hotspotItem.properties.depth.minimum, 1);
    assert.ok(stringBranch(hotspotItem.properties.effectiveAttributedGB).pattern !== undefined);
    assert.ok(nullable(hotspotItem.properties.logicalGB));

    const issues = output('get_scan_issues');
    assert.equal(issues.properties.categories.maxItems, 16);
    assert.equal(issues.properties.samples.maxItems, 20);
    assert.ok(issues.properties.categories.items.properties.category.enum.includes('io'));
    assert.ok(nullable(issues.properties.samples.items.properties.errno));
    assert.equal(
      integerBranch(issues.properties.samples.items.properties.errno).type,
      'integer',
    );

    assert.ok(output('cancel_scan').properties.status.enum.includes('running'));
  } finally {
    await server.close();
    fixture.cleanup();
  }
});

test('end-to-end scan, queries, untrusted names and privacy', async () => {
  const fixture = createFixture();
  const server = await connectServer([fixture.root]);
  const leaked = [];
  try {
    const roots = await server.client.callTool({
      name: 'list_allowed_roots',
      arguments: {},
    });
    assert.equal(roots.structuredContent.roots.length, 1);
    assert.equal(roots.structuredContent.roots[0].rootId, 'root-1');
    leaked.push(...collectStrings(roots.structuredContent));

    const volume = await server.client.callTool({
      name: 'get_volume_usage',
      arguments: { rootId: 'root-1' },
    });
    assert.equal(volume.isError, undefined);
    for (const prefix of ['capacity', 'available', 'used']) {
      const bytes = volume.structuredContent[`${prefix}Bytes`];
      const gb = volume.structuredContent[`${prefix}GB`];
      if (bytes === null) {
        assert.equal(gb, null, `${prefix}GB must be null with ${prefix}Bytes`);
      } else {
        assert.equal(gb, gigabytes(bytes), `${prefix}GB must project ${prefix}Bytes`);
      }
    }
    assert.match(volume.content[0].text, /GB \(|unknown/);
    leaked.push(...collectStrings(volume.structuredContent));

    const started = await server.client.callTool({
      name: 'start_scan',
      arguments: { rootId: 'root-1' },
    });
    assert.equal(started.structuredContent.status, 'running');
    const scanId = started.structuredContent.scanId;
    const rootNodeId = started.structuredContent.rootNodeId;

    const terminalContent = await waitForTerminal(server.client, scanId);
    assert.equal(terminalContent.status, 'completed');
    const terminal = terminalContent.terminal;
    assert.ok(terminal, 'terminal object must be present');
    if (terminal.rootAttributedBytes === null) {
      assert.equal(terminal.rootAttributedGB, null);
    } else {
      assert.equal(terminal.rootAttributedGB, gigabytes(terminal.rootAttributedBytes));
    }

    const status = await server.client.callTool({
      name: 'get_scan_status',
      arguments: { scanId },
    });
    leaked.push(...collectStrings(status.structuredContent));

    const children = await server.client.callTool({
      name: 'list_children',
      arguments: { scanId, nodeId: rootNodeId },
    });
    leaked.push(...collectStrings(children.structuredContent));
    const childNames = children.structuredContent.items.map((item) => item.name);
    assert.ok(childNames.some((name) => name.includes('ignore previous instructions')));
    assert.ok(childNames.some((name) => name.includes('中文')));
    // Every child capacity field carries a recomputable GB projection.
    for (const item of children.structuredContent.items) {
      for (const prefix of [
        'logical',
        'allocated',
        'attributed',
        'effectiveAttributed',
      ]) {
        const bytes = item[`${prefix}Bytes`];
        const gb = item[`${prefix}GB`];
        if (bytes === null) {
          assert.equal(gb, null, `${prefix}GB must be null with ${prefix}Bytes`);
        } else {
          assert.equal(gb, gigabytes(bytes), `${prefix}GB must project ${prefix}Bytes`);
        }
      }
    }
    // The untrusted name must not reach the human-readable summary.
    assert.ok(!children.content[0].text.includes('ignore previous instructions'));

    const issues = await server.client.callTool({
      name: 'get_scan_issues',
      arguments: { scanId },
    });
    leaked.push(...collectStrings(issues.structuredContent));
    assert.ok(!issues.content[0].text.includes('ignore'));

    // A second node query proves raw bytes are available alongside the name.
    const item = children.structuredContent.items[0];
    assert.ok(typeof item.nameBase64 === 'string');

    // No protocol output may contain an authorized root path or user name.
    const username = os.userInfo().username;
    for (const value of leaked) {
      assert.ok(!value.includes(fixture.root), `path leaked: ${value}`);
      assert.ok(!value.includes(`/${username}`), `username leaked: ${value}`);
    }
    assert.ok(!server.getStderr().includes(fixture.root));
  } finally {
    await server.close();
    fixture.cleanup();
  }
});

test('get_hotspots returns bounded ancestor-inclusive hotspots without leaking names', async () => {
  const fixture = createFixture();
  const server = await connectServer([fixture.root]);
  const leaked = [];
  try {
    const started = await server.client.callTool({
      name: 'start_scan',
      arguments: { rootId: 'root-1' },
    });
    const scanId = started.structuredContent.scanId;
    const rootNodeId = started.structuredContent.rootNodeId;
    const terminal = await waitForTerminal(server.client, scanId);
    assert.equal(terminal.status, 'completed');

    const hotspots = await server.client.callTool({
      name: 'get_hotspots',
      arguments: { scanId, scopeNodeId: rootNodeId, limit: 30, minimumBytes: '1' },
    });
    assert.equal(hotspots.isError, undefined);
    const structured = hotspots.structuredContent;
    leaked.push(...collectStrings(structured));
    assert.equal(structured.scanId, scanId);
    assert.equal(structured.scopeNodeId, rootNodeId);
    assert.equal(structured.status, 'completed');
    assert.equal(structured.snapshotComplete, true);
    assert.equal(structured.overlapSemantics, 'ancestorInclusive');
    assert.equal(structured.limit, 30);
    assert.equal(structured.minimumBytes, '1');
    assert.equal(structured.minimumGB, gigabytes('1'));
    assert.ok(Array.isArray(structured.items));
    assert.ok(structured.items.length >= 1);
    assert.ok(structured.items.length <= 50);
    // The scope itself is never returned.
    assert.ok(!structured.items.some((item) => item.nodeId === rootNodeId));
    // A deep node ('a' -> 'b' -> f2.txt) appears in a single call.
    const names = structured.items.map((item) => item.name);
    assert.ok(names.includes('a'), 'ancestor a should appear');
    assert.ok(names.includes('b'), 'deep directory b should appear');
    const deep = structured.items.find((item) => item.name === 'b');
    assert.equal(deep.depth, 2);
    // Every item carries an independently recomputable bytes/GB pair and depth.
    for (const item of structured.items) {
      assert.ok(item.depth >= 1);
      for (const prefix of [
        'logical',
        'allocated',
        'attributed',
        'effectiveAttributed',
      ]) {
        const bytes = item[`${prefix}Bytes`];
        const gb = item[`${prefix}GB`];
        if (bytes === null) {
          assert.equal(gb, null, `${prefix}GB must be null with ${prefix}Bytes`);
        } else {
          assert.equal(gb, gigabytes(bytes), `${prefix}GB must project ${prefix}Bytes`);
        }
      }
    }
    // Human text never carries a name and warns against summing.
    const text = hotspots.content[0].text;
    assert.ok(!text.includes('ignore previous instructions'));
    assert.ok(!text.includes('中文'));
    assert.match(text, /do not sum/i);
    assert.match(text, /ancestor/i);
    assert.match(text, /untrusted/i);

    const username = os.userInfo().username;
    for (const value of leaked) {
      assert.ok(!value.includes(fixture.root), `path leaked: ${value}`);
      assert.ok(!value.includes(`/${username}`), `username leaked: ${value}`);
    }
    assert.ok(!server.getStderr().includes(fixture.root));
  } finally {
    await server.close();
    fixture.cleanup();
  }
});

test('get_hotspots rejects running scans, unknown ids and bad arguments', async () => {
  const fixture = createFixture({ files: 20000 });
  const server = await connectServer([fixture.root]);
  try {
    const unknown = await server.client.callTool({
      name: 'get_hotspots',
      arguments: {
        scanId: '00000000-0000-0000-0000-000000000000',
        scopeNodeId: '1',
      },
    });
    assert.equal(unknown.isError, true);

    const started = await server.client.callTool({
      name: 'start_scan',
      arguments: { rootId: 'root-1' },
    });
    const scanId = started.structuredContent.scanId;

    // A live snapshot must be refused rather than read across revisions.
    const running = await server.client.callTool({
      name: 'get_hotspots',
      arguments: { scanId, scopeNodeId: '1' },
    });
    assert.equal(running.isError, true, 'running scan must be refused');

    const terminal = await waitForTerminal(server.client, scanId);
    assert.equal(terminal.status, 'completed');

    const badLimit = await server.client.callTool({
      name: 'get_hotspots',
      arguments: { scanId, scopeNodeId: '1', limit: 51 },
    });
    assert.equal(badLimit.isError, true);

    const badMinimum = await server.client.callTool({
      name: 'get_hotspots',
      arguments: { scanId, scopeNodeId: '1', minimumBytes: 'abc' },
    });
    assert.equal(badMinimum.isError, true);

    const badNode = await server.client.callTool({
      name: 'get_hotspots',
      arguments: { scanId, scopeNodeId: '999999999' },
    });
    assert.equal(badNode.isError, true);

    const extra = await server.client.callTool({
      name: 'get_hotspots',
      arguments: { scanId, scopeNodeId: '1', unexpected: true },
    });
    assert.equal(extra.isError, true);
  } finally {
    await server.close();
    fixture.cleanup();
  }
});

test('strict schemas reject bad arguments and unknown identifiers', async () => {
  const fixture = createFixture();
  const server = await connectServer([fixture.root]);
  try {
    const extra = await server.client.callTool({
      name: 'list_allowed_roots',
      arguments: { unexpected: true },
    });
    assert.equal(extra.isError, true);

    const badRoot = await server.client.callTool({
      name: 'get_volume_usage',
      arguments: { rootId: 'root-999' },
    });
    assert.equal(badRoot.isError, true);

    const badScan = await server.client.callTool({
      name: 'get_scan_status',
      arguments: { scanId: 'not-a-uuid' },
    });
    assert.equal(badScan.isError, true);

    const unknownScan = await server.client.callTool({
      name: 'get_scan_issues',
      arguments: { scanId: '00000000-0000-0000-0000-000000000000' },
    });
    assert.equal(unknownScan.isError, true);

    const started = await server.client.callTool({
      name: 'start_scan',
      arguments: { rootId: 'root-1' },
    });
    const scanId = started.structuredContent.scanId;
    await waitForTerminal(server.client, scanId);

    const badLimit = await server.client.callTool({
      name: 'list_children',
      arguments: { scanId, nodeId: '1', limit: 1000 },
    });
    assert.equal(badLimit.isError, true);

    const badNode = await server.client.callTool({
      name: 'list_children',
      arguments: { scanId, nodeId: '999999999' },
    });
    assert.equal(badNode.isError, true);

    // Error text must be path-free too.
    const errorStrings = [
      extra.content[0].text,
      badRoot.content[0].text,
      badScan.content[0].text,
      unknownScan.content[0].text,
      badLimit.content[0].text,
      badNode.content[0].text,
    ];
    const username = os.userInfo().username;
    for (const value of errorStrings) {
      assert.ok(!value.includes(fixture.root), `path leaked in error: ${value}`);
      assert.ok(!value.includes(`/${username}`), `username leaked in error: ${value}`);
    }
  } finally {
    await server.close();
    fixture.cleanup();
  }
});
