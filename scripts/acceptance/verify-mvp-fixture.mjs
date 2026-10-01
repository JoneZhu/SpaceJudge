#!/usr/bin/env node
// Independent POSIX fixture oracle -> real CLI -> persisted read API.
// Does not delete artifacts or scan any user directory. CLI owns the new DBs.
import assert from 'node:assert/strict';
import { lstatSync, readFileSync, realpathSync } from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';

const [cliArgument, fixtureArgument, workspaceArgument] = process.argv.slice(2);
assert(cliArgument && fixtureArgument && workspaceArgument,
  'usage: node verify-mvp-fixture.mjs ABSOLUTE_CLI FIXTURE_PARENT OWNED_WORKSPACE');
for (const value of [cliArgument, fixtureArgument, workspaceArgument]) {
  assert(path.isAbsolute(value), 'all arguments must be absolute');
}
const cli = realpathSync(cliArgument);
const fixture = realpathSync(fixtureArgument);
const workspace = realpathSync(workspaceArgument);
assert(fixture.startsWith('/private/tmp/spacejudge-mvp-acceptance.'),
  'only the synthetic acceptance fixture is allowed');
const workspaceStat = lstatSync(workspaceArgument);
assert(workspaceStat.isDirectory() && !workspaceStat.isSymbolicLink());
assert.equal(workspaceStat.uid, process.getuid());
assert.equal(workspaceStat.mode & 0o077, 0, 'workspace must be owner-only');
assert.equal(lstatSync(fixture).uid, process.getuid());
assert(!workspace.startsWith(`${fixture}/`), 'workspace must be outside fixture');

function command(args) {
  const processResult = spawnSync(cli, args, {
    encoding: 'utf8', maxBuffer: 8 * 1024 * 1024, timeout: 30_000,
  });
  assert.equal(processResult.status, 0,
    `CLI ${args[0]} failed: ${processResult.error?.message ?? processResult.stderr ?? ''} ${processResult.stdout}`);
  return processResult.stdout.trim().split('\n').filter(Boolean).map(JSON.parse);
}

function verifyUnits(record) {
  for (const key of Object.keys(record).filter(key => key.endsWith('Bytes'))) {
    const gbKey = key.replace(/Bytes$/, 'GB');
    if (!(gbKey in record)) continue;
    if (record[key] === null) assert.equal(record[gbKey], null);
    else {
      assert.equal(typeof record[key], 'string', `${key} must be exact decimal string`);
      assert.equal(record[gbKey], (Number(BigInt(record[key])) / 1e9).toFixed(2), gbKey);
    }
  }
}

const expected = JSON.parse(readFileSync(path.join(fixture, 'expected.json'), 'utf8'));
assert.equal(expected.version, 1);
const results = [];
for (const oracle of expected.roots) {
  assert(!oracle.rootName.includes('/') && oracle.rootName !== '..');
  const root = path.join(fixture, oracle.rootName);
  assert(lstatSync(root).isDirectory() && !lstatSync(root).isSymbolicLink());
  const database = path.join(workspace, `acceptance-${randomUUID()}.sqlite`);
  const events = command(['scan', '--root', root, '--database', database, '--workspace', workspace]);
  const started = events.find(event => event.type === 'started');
  const completed = events.find(event => event.type === 'completed');
  assert(started && completed, 'one successful scan lifecycle is required');
  assert.equal(events.filter(event => event.type === 'completed').length, 1);
  assert.equal(completed.status, 'completed');
  assert.equal(BigInt(completed.rootAttributedBytes), BigInt(oracle.attributedBytes));
  assert.equal(BigInt(completed.fileCount), BigInt(oracle.fileCount));
  assert.equal(BigInt(completed.directoryCount), BigInt(oracle.directoryCount));
  assert.equal(completed.inaccessibleCount, '0');
  assert.equal(completed.issueCount, '0');
  verifyUnits(completed);
  const scanID = started.scanId;
  const state = command(['status', '--database', database, '--scan-id', scanID])[0];
  assert.equal(state.status, 'completed');
  assert.equal(state.rootAttributedBytes, completed.rootAttributedBytes);
  verifyUnits(state);
  const files = new Map();
  const pending = [{ id: started.rootNodeId, components: [] }];
  let directoryCount = 0;
  while (pending.length) {
    const current = pending.pop();
    ++directoryCount;
    assert(directoryCount <= oracle.directoryCount, 'no extra directory traversal');
    const page = command(['children', '--database', database, '--scan-id', scanID,
      '--node-id', current.id, '--limit', '100'])[0];
    assert.equal(BigInt(page.totalCount), BigInt(page.items.length), 'fixture page must not truncate');
    let previousWeight = null;
    for (const item of page.items) {
      assert(!item.name.includes('/') && item.name !== '..', 'names are components, not commands');
      const components = [...current.components, item.name];
      const relative = components.join('/');
      verifyUnits(item);
      const weight = BigInt(item.effectiveAttributedBytes);
      if (previousWeight !== null) assert(weight <= previousWeight, 'children sorted by weight');
      previousWeight = weight;
      if (item.kind === 'directory') pending.push({ id: item.nodeId, components });
      else {
        assert(!files.has(relative));
        files.set(relative, item);
      }
    }
  }
  assert.equal(directoryCount, oracle.directoryCount);
  assert.equal(files.size, oracle.fileCount);
  let attributed = 0n;
  const hardLinks = new Map();
  for (const expectedFile of oracle.files) {
    const actual = files.get(expectedFile.relativePath);
    assert(actual, `missing synthetic file ${expectedFile.relativePath}`);
    assert.equal(actual.kind, expectedFile.kind);
    assert.equal(BigInt(actual.logicalBytes), BigInt(expectedFile.logicalBytes));
    assert.equal(BigInt(actual.allocatedBytes), BigInt(expectedFile.allocatedBytes));
    attributed += BigInt(actual.attributedBytes);
    const stat = lstatSync(path.join(root, expectedFile.relativePath), { bigint: true });
    if (stat.isFile()) {
      const identity = `${stat.dev}:${stat.ino}`;
      const group = hardLinks.get(identity) ?? { sum: 0n, allocated: stat.blocks * 512n };
      group.sum += BigInt(actual.attributedBytes);
      hardLinks.set(identity, group);
    } else {
      assert(stat.isSymbolicLink(), 'fixture contains only ordinary files/directories/links');
      assert.equal(actual.attributedBytes, '0');
    }
  }
  for (const group of hardLinks.values()) assert.equal(group.sum, group.allocated,
    'regular file identity attributed exactly once, regardless of hard-link owner order');
  assert.equal(attributed, BigInt(oracle.attributedBytes));
  assert(![...files.keys()].some(name => name.includes('不能进入地图的文件')),
    'outside symbolic-link target must not be followed');
  results.push({ rootName: oracle.rootName, scanID, database, status: state.status,
    attributedBytes: completed.rootAttributedBytes, directoryCount, fileCount: files.size,
    hardLinksDeduplicated: true, symbolicLinksNotFollowed: true, dualUnitsConsistent: true });
}
console.log(JSON.stringify({ passed: true, results }, null, 2));
