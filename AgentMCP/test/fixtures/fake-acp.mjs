import readline from 'node:readline';
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';
const send = value => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...value }) + '\n');
let promptId;
let mcp;
let mcpClient;
for await (const line of readline.createInterface({ input: process.stdin })) {
  const message = JSON.parse(line);
  if (message.method === 'initialize') send({ id: message.id, result: { protocolVersion: 1 } });
  else if (message.method === 'session/new') {
    mcp = message.params.mcpServers?.[0];
    send({ id: message.id, result: { sessionId: 'fixture', modes: {
      currentModeId: process.argv.includes('--write') ? 'workspace-write' : 'read-only',
    } } });
  }
  else if (message.method === 'session/prompt') {
    promptId = message.id;
    send({ id: 900, method: 'session/request_permission', params: {} });
  } else if (message.id === 900) {
    if (message.result?.outcome?.outcome !== 'cancelled') process.exit(2);
    send({ id: 901, method: 'fs/read_text_file', params: { path: '/not-authorized' } });
  } else if (message.id === 901) {
    if (message.error?.code !== -32601) process.exit(3);
    let text = 'fixture result';
    if (process.argv.includes('--mcp')) {
      if (!mcp) process.exit(5);
      mcpClient = new Client({ name: 'fixture-agent', version: '1' });
      const transport = new StdioClientTransport({ command: mcp.command, args: mcp.args, stderr: 'pipe' });
      transport.stderr?.on('data', () => {});
      await mcpClient.connect(transport);
      const result = await mcpClient.callTool({ name: 'spacejudge_scope', arguments: {} });
      text = JSON.stringify(result.structuredContent);
      await mcpClient.close();
    }
    send({ method: 'session/update', params: { sessionId: 'fixture', update: {
      sessionUpdate: 'agent_message_chunk', content: { type: 'text', text },
    } } });
    send({ id: promptId, result: { stopReason: 'end_turn' } });
  } else if (message.method === 'oversized') process.stdout.write('x'.repeat(1_100_000));
  else if (message.method === 'malformed') process.stdout.write('not-json\n');
  else if (message.method === 'crash') process.exit(4);
  // 'hang' intentionally ignores the request.
}
