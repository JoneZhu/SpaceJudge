#!/usr/bin/env node
// Legacy 0.5.0 ACP preview only. Current desktop handoff uses local-candidate.sh.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const args = process.argv.slice(2);
if (args.length !== 4 || args[0] !== '--output' || args[2] !== '--node'
    || !path.isAbsolute(args[1]) || !path.isAbsolute(args[3])) {
  throw new Error('Usage: agent-local-preview.mjs --output NEW_ABSOLUTE_DIR --node ABSOLUTE_NODE');
}
const output = args[1];
const sourceInfo = fs.readFileSync(path.join(repo, 'App/SpaceJudgeApp/Info.plist'), 'utf8');
if (!/<key>CFBundleShortVersionString<\/key>\s*<string>0\.5\.0<\/string>/.test(sourceInfo)
    || !/<key>CFBundleVersion<\/key>\s*<string>5<\/string>/.test(sourceInfo)) {
  throw new Error('Legacy 0.5.0 build 5 ACP packager is retired; use scripts/release/local-candidate.sh for desktop handoff.');
}
const node = fs.realpathSync(args[3]);
if (fs.existsSync(output)) throw new Error('Output must not already exist');
fs.accessSync(node, fs.constants.X_OK);
const npm = path.resolve(path.dirname(node), '../lib/node_modules/npm/bin/npm-cli.js');
fs.accessSync(npm);
const work = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'sj-agent-package-'));
const logs = path.join(output, 'logs');
fs.mkdirSync(logs, { recursive: true });
const cleanEnv = { ...process.env, PATH: `${path.dirname(node)}:/usr/bin:/bin:/usr/sbin:/sbin` };
delete cleanEnv.NODE_OPTIONS; delete cleanEnv.NODE_PATH;
async function run(command, arguments_, logName, cwd = repo) {
  const log = fs.openSync(path.join(logs, logName), 'w', 0o600);
  try {
    await new Promise((resolve, reject) => {
      const child = spawn(command, arguments_, { cwd, env: cleanEnv, stdio: ['ignore', log, log] });
      child.once('error', reject);
      child.once('exit', (code, signal) => code === 0 ? resolve() : reject(new Error(`${logName}: exit ${code ?? signal}`)));
    });
  } finally { fs.closeSync(log); }
}
try {
  console.log('Compiling bridge…');
  await run(node, [npm, 'run', 'build'], 'typescript.log', path.join(repo, 'AgentMCP'));
  console.log('Building host-local macOS Release…');
  const derived = path.join(work, 'DerivedData');
  await run('/usr/bin/xcodebuild', ['-quiet', '-project', 'App/SpaceJudge.xcodeproj', '-scheme', 'SpaceJudge',
    '-configuration', 'Release', '-destination', 'platform=macOS,arch=arm64', '-derivedDataPath', derived,
    'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES', 'CODE_SIGNING_ALLOWED=NO', 'build'], 'xcodebuild.log');
  const app = path.join(work, 'staging/SpaceJudge.app');
  fs.mkdirSync(path.dirname(app));
  await run('/usr/bin/ditto', ['--norsrc', '--noextattr', '--noqtn',
    path.join(derived, 'Build/Products/Release/SpaceJudge.app'), app], 'copy-app.log');
  const runtime = path.join(app, 'Contents/Resources/AgentRuntime');
  fs.mkdirSync(path.join(runtime, 'bin'), { recursive: true });
  fs.cpSync(path.join(repo, 'AgentMCP/dist'), path.join(runtime, 'dist'), { recursive: true });
  for (const file of ['package.json', 'package-lock.json']) fs.copyFileSync(path.join(repo, 'AgentMCP', file), path.join(runtime, file));
  fs.copyFileSync(node, path.join(runtime, 'bin/node'));
  fs.chmodSync(path.join(runtime, 'bin/node'), 0o755);
  console.log('Adding locked production dependencies (prefer cache, no lifecycle scripts)…');
  await run(node, [npm, 'ci', '--omit=dev', '--ignore-scripts', '--prefer-offline', '--no-audit', '--no-fund',
    '--cache', '/tmp/spacejudge-npm-cache'], 'npm-production.log', runtime);
  // Preserve Node/vendor helper signatures. Re-signing Node without its JIT
  // entitlements would make a seemingly valid bundle unable to run JavaScript.
  console.log('Signing and verifying local preview…');
  await run('/usr/bin/codesign', ['--force', '--options', 'runtime', '--timestamp=none', '--sign', '-', app], 'sign.log');
  await run('/usr/bin/codesign', ['--verify', '--deep', '--strict', '--verbose=2', app], 'verify.log');
  // Documents may be a File Provider root that adds FinderInfo to loose apps.
  // A read-only image preserves the verified staging bundle for recovery.
  const imageName = 'SpaceJudge-0.5.0-build5-HOST-LOCAL-PREVIEW.dmg';
  await run('/usr/bin/hdiutil', ['create', '-srcfolder', path.dirname(app), '-volname', 'SpaceJudge Local Preview',
    '-format', 'UDZO', '-ov', path.join(output, imageName)], 'create-image.log');
  const destination = path.join(output, 'SpaceJudge.app');
  await run('/usr/bin/ditto', ['--norsrc', '--noextattr', '--noqtn', app, destination], 'copy-preview.log');
  const roundtrip = path.join(work, 'roundtrip/SpaceJudge.app');
  await run('/usr/bin/ditto', ['--norsrc', '--noextattr', '--noqtn', destination, roundtrip], 'copy-roundtrip.log');
  await run('/usr/bin/codesign', ['--verify', '--deep', '--strict', '--verbose=2', roundtrip], 'verify-roundtrip.log');
  const lock = JSON.parse(fs.readFileSync(path.join(runtime, 'package-lock.json'), 'utf8'));
  fs.writeFileSync(path.join(output, 'manifest.json'), JSON.stringify({
    kind: 'host-local-agent-preview', distributionReady: false, notarized: false,
    image: imageName, looseAppMayHaveFileProviderAttributes: true,
    version: '0.5.0', build: '5', nativeArchitecture: 'arm64', helperArchitecture: 'x86_64',
    requiresRosettaOnAppleSilicon: true,
    node: '20.16.0', acpAdapter: lock.packages['node_modules/@agentclientprotocol/codex-acp'].version,
    codex: lock.packages['node_modules/@openai/codex'].version,
    generatedAt: new Date().toISOString(), modelPromptSent: false,
  }, null, 2) + '\n');
  console.log(`Ready: ${destination}`);
} finally {
  // Exactly this invocation's freshly created private temporary directory.
  fs.rmSync(work, { recursive: true, force: true });
}
