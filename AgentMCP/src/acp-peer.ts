import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';

/** Small bounded JSONL ACP transport. No filesystem/terminal client capabilities. */
export class AcpPeer {
  private readonly child: ChildProcessWithoutNullStreams;
  private pending = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void; timer: NodeJS.Timeout }>();
  private nextId = 1;
  private buffer = Buffer.alloc(0);
  private totalBytes = 0;
  private failed = false;
  private closed: Promise<void>;
  private stopped: Promise<void> | undefined;
  constructor(command: string, args: string[], cwd: string, env: NodeJS.ProcessEnv,
              private readonly onUpdate: (params: any) => void) {
    this.child = spawn(command, args, { cwd, env, stdio: 'pipe', detached: process.platform !== 'win32' });
    this.closed = new Promise(resolve => this.child.once('close', () => { this.fail(); resolve(); }));
    this.child.on('error', () => this.fail());
    this.child.stdin.on('error', () => this.fail());
    this.child.stderr.on('data', () => {}); // Drain, never expose adapter/auth/provider details.
    this.child.stdout.on('data', (chunk: Buffer) => {
      this.totalBytes += chunk.length;
      if (this.totalBytes > 16 * 1024 * 1024) { this.fail(); void this.stop(); return; }
      this.buffer = Buffer.concat([this.buffer, chunk]);
      for (;;) {
        const newline = this.buffer.indexOf(10);
        if (newline < 0) break;
        if (newline > 1024 * 1024) { this.fail(); void this.stop(); return; }
        const line = this.buffer.subarray(0, newline);
        this.buffer = this.buffer.subarray(newline + 1);
        try { this.receive(JSON.parse(line.toString('utf8'))); }
        catch { this.fail(); void this.stop(); return; }
      }
      if (this.buffer.length > 1024 * 1024) { this.fail(); void this.stop(); }
    });
  }
  request(method: string, params: unknown, timeoutMs = 60_000): Promise<any> {
    if (this.failed) return Promise.reject(new Error('ACP unavailable'));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id); reject(new Error('ACP timeout')); void this.stop();
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      this.send({ jsonrpc: '2.0', id, method, params });
    });
  }
  notify(method: string, params: unknown): void { this.send({ jsonrpc: '2.0', method, params }); }
  private send(value: unknown): void {
    if (!this.child.stdin.destroyed) this.child.stdin.write(JSON.stringify(value) + '\n');
  }
  private receive(message: any): void {
    if (this.failed) return;
    if (!message || message.jsonrpc !== '2.0') throw new Error('Invalid ACP message');
    if (message.method && message.id !== undefined) {
      // ALWAYS deny; no approval dialog can accidentally grant broad access.
      this.send(message.method === 'session/request_permission'
        ? { jsonrpc: '2.0', id: message.id, result: { outcome: { outcome: 'cancelled' } } }
        : { jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'Client capability disabled' } });
    } else if (message.method === 'session/update') {
      this.onUpdate(message.params);
    } else if (typeof message.id === 'number') {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id); clearTimeout(pending.timer);
      if (message.error) pending.reject(new Error('ACP request rejected; check dedicated Codex login/runtime'));
      else if (!('result' in message)) pending.reject(new Error('Malformed ACP response'));
      else pending.resolve(message.result);
    }
  }
  private fail(): void {
    this.failed = true;
    for (const p of this.pending.values()) { clearTimeout(p.timer); p.reject(new Error('ACP disconnected')); }
    this.pending.clear();
  }
  stop(): Promise<void> { return this.stopped ??= this.stopOnce(); }
  private async stopOnce(): Promise<void> {
    this.fail(); this.child.stdin.end();
    const signalGroup = (signal: NodeJS.Signals) => {
      try {
        if (this.child.pid && process.platform !== 'win32') process.kill(-this.child.pid, signal);
        else this.child.kill(signal);
      } catch { /* already reaped */ }
    };
    // Signal the owned process group even if the adapter exited but left grandchildren.
    await Promise.race([this.closed, new Promise(resolve => setTimeout(resolve, 2_200))]);
    signalGroup('SIGTERM');
    await Promise.race([this.closed, new Promise(resolve => setTimeout(resolve, 1_000))]);
    signalGroup('SIGKILL');
    await this.closed;
  }
}
