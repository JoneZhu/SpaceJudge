// Local protocol smoke only: no login, user filesystem metadata, or prompt.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
const args = process.argv.slice(2);
if (args.length && (args.length !== 2 || args[0] !== '--runtime' || !path.isAbsolute(args[1]))) {
  throw new Error('Usage: check-acp.mjs [--runtime ABSOLUTE_RUNTIME_DIR]');
}
const runtime = args[1] ?? fileURLToPath(new URL('..', import.meta.url));
const { AcpPeer } = await import(pathToFileURL(path.join(runtime, 'dist/acp-peer.js')).href);
const { prepareHome, safeEnvironment } = await import(pathToFileURL(path.join(runtime, 'dist/agent-bridge.js')).href);
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sj-acp-check-'));
const state = path.join(root, 'state');
const home = prepareHome(state);
const require = createRequire(path.join(runtime, 'package.json'));
const peer = new AcpPeer(process.execPath, [require.resolve('@agentclientprotocol/codex-acp')],
  root, safeEnvironment(home), () => {});
try {
  const init = await peer.request('initialize', { protocolVersion: 1,
    clientInfo: { name: 'SpaceJudge-local-check', version: '0.5.0' },
    clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false } }, 45000);
  let session;
  try {
    const value = await peer.request('session/new', { cwd: root, mcpServers: [] }, 45000);
    session = { mode: value.modes?.currentModeId };
  } catch { session = { authenticationRequiredOrSessionRejected: true }; }
  console.log(JSON.stringify({ protocolVersion: init.protocolVersion, adapterVersion: init.agentInfo?.version,
    session, noPromptSent: true,
    generatedDirectories: ['skills', 'plugins'].map(name => ({ name,
      entries: fs.existsSync(path.join(home, name)) ? fs.readdirSync(path.join(home, name)) : [] })),
  }));
  await peer.stop();
  console.log(JSON.stringify({ reusableHome: prepareHome(state) === home }));
} finally {
  await peer.stop(); fs.rmSync(root, { recursive: true, force: true });
}
