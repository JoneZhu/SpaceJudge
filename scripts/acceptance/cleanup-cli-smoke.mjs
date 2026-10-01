// Synthetic-only acceptance: uses argv, no shell interpolation or model call.
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';
const [cli, root] = process.argv.slice(2);
assert(cli?.startsWith('/') && root?.startsWith('/private/tmp/spacejudge-cleanup-ui-'), 'Synthetic root only');
const work = fs.mkdtempSync('/private/tmp/spacejudge-cleanup-cli.');
fs.chmodSync(work, 0o700);
const database = work + '/scan.sqlite';
const run = args => execFileSync(cli, args, { encoding: 'utf8', timeout: 60_000, maxBuffer: 1_048_576 });
const help = run(['--help']);
assert(help.includes('hotspots') && help.includes('--workspace'));
const eventsText = run(['scan', '--root', root, '--database', database, '--workspace', work]);
fs.writeFileSync(work + '/events.ndjson', eventsText, { mode: 0o600 });
const events = eventsText.trim().split('\n').map(line => JSON.parse(line));
const started = events.find(event => event.type === 'started');
const terminal = events.at(-1);
assert.equal(terminal.status, 'completed');
assert.equal(terminal.scanId, started.scanId);
const query = command => JSON.parse(run([command, '--database', database, '--scan-id', started.scanId,
  ...(['children', 'hotspots'].includes(command) ? ['--node-id', started.rootNodeId, '--limit', '20'] : [])]));
const status = query('status');
const children = query('children');
const hotspots = query('hotspots');
const issues = query('issues');
const volume = JSON.parse(run(['volume', '--root', root]));
assert(children.items.length > 0 && hotspots.items.length > 0);
assert(hotspots.items.every(item => typeof item.effectiveAttributedBytes === 'string'
  && typeof item.effectiveAttributedGB === 'string'));
console.log(JSON.stringify({ result: 'passed', cli, syntheticRoot: root, taskWorkspace: work,
  started, terminal, status, children, hotspots, issues, volume }, null, 2));
