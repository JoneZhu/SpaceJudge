import { spawn, type ChildProcess } from 'node:child_process';
import type { Redactor } from './redaction.js';

/** Stable native CLI error codes. */
export type NativeErrorCode =
  | 'INVALID_ARGUMENT'
  | 'NOT_FOUND'
  | 'CONFLICT'
  | 'ACCESS_DENIED'
  | 'INSUFFICIENT_SPACE'
  | 'INTERNAL';

/** A path-free native CLI failure. */
export class NativeCliError extends Error {
  readonly code: NativeErrorCode;

  constructor(code: NativeErrorCode, message?: string) {
    super(message ?? defaultMessage(code));
    this.name = 'NativeCliError';
    this.code = code;
  }
}

function defaultMessage(code: NativeErrorCode): string {
  switch (code) {
    case 'INVALID_ARGUMENT':
      return 'The request is invalid.';
    case 'NOT_FOUND':
      return 'The requested item was not found.';
    case 'CONFLICT':
      return 'The request conflicts with the current state.';
    case 'ACCESS_DENIED':
      return 'Access was denied.';
    case 'INSUFFICIENT_SPACE':
      return 'There is not enough storage space.';
    case 'INTERNAL':
      return 'An internal error occurred.';
  }
}

/** One `progress` NDJSON event. Counters are decimal strings. */
export interface ScanProgress {
  visitedEntries: string;
  persistedNodes: string;
  attributedBytes: string;
}

/** A persisted terminal state. */
export interface ScanTerminal {
  status: 'completed' | 'cancelled' | 'failed';
  scanId?: string;
  code?: NativeErrorCode;
  startedAt?: string | null;
  finishedAt?: string | null;
  fileCount?: string;
  directoryCount?: string;
  inaccessibleCount?: string;
  issueCount?: string;
  rootAttributedBytes?: string;
}

export interface ScanStarted {
  scanId: string;
  rootNodeId: string;
}

interface Deferred<T> {
  promise: Promise<T>;
  resolve: (value: T) => void;
  reject: (error: unknown) => void;
}

function defer<T>(): Deferred<T> {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

const MAX_JSON_STDOUT_BYTES = 8 * 1024 * 1024;
const MAX_STDERR_BYTES = 16 * 1024;
const MAX_LINE_LENGTH = 1024 * 1024;

const UUID_PATTERN =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const UINT64_MAX = 18446744073709551615n;
const ISO_TIMESTAMP_PATTERN =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/;

/** Whether `value` is a canonical UUID string. */
export function isUuid(value: string): boolean {
  return UUID_PATTERN.test(value);
}

/** Whether `value` is a decimal string that fits in an unsigned 64-bit int. */
export function isUInt64String(value: string): boolean {
  if (!/^\d{1,20}$/.test(value)) {
    return false;
  }
  return BigInt(value) <= UINT64_MAX;
}

/** Whether `value` is a CLI UTC ISO-8601 timestamp with `Z`. */
export function isIsoTimestamp(value: string): boolean {
  return ISO_TIMESTAMP_PATTERN.test(value);
}

/**
 * A long-lived `spacejudge-agent-cli scan` child.
 *
 * The process is spawned with an argv array (never a shell) so a file name can
 * never become a command. Cancellation targets only the exact PID returned by
 * `spawn`; if the child has already exited, no signal is sent.
 */
export class ScanProcess {
  readonly pid: number;
  readonly started: Promise<ScanStarted>;
  readonly done: Promise<ScanTerminal>;
  latestProgress?: ScanProgress;

  private readonly child: ChildProcess;
  private readonly startedDeferred = defer<ScanStarted>();
  private readonly doneDeferred = defer<ScanTerminal>();
  private pendingTerminal?: ScanTerminal;
  private startedScanId?: string;
  private failedCode?: NativeErrorCode;
  private violatedState = false;
  private startedSettled = false;
  private stderrChunks: string[] = [];
  private stderrBytes = 0;
  private exited = false;

  constructor(
    cliPath: string,
    args: string[],
    private readonly redactor: Redactor,
    private readonly onProgress?: (progress: ScanProgress) => void,
    private readonly onTerminal?: (terminal: ScanTerminal) => void,
  ) {
    this.child = spawn(cliPath, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    if (this.child.pid === undefined) {
      throw new NativeCliError('INTERNAL');
    }
    this.pid = this.child.pid;
    this.started = this.startedDeferred.promise;
    this.done = this.doneDeferred.promise;

    const stdout = this.child.stdout;
    const stderr = this.child.stderr;
    if (stdout) {
      const scanner = new LineScanner(
        MAX_LINE_LENGTH,
        (line) => this.handleLine(line),
        () => this.handleLineOverflow(),
      );
      stdout.on('data', (chunk: Buffer) => scanner.push(chunk));
      stdout.on('end', () => scanner.flush());
      stdout.on('error', () => this.fail('INTERNAL'));
    }
    if (stderr) {
      stderr.on('data', (chunk: Buffer) => this.appendStderr(chunk.toString('utf8')));
      stderr.on('error', () => undefined);
    }
    this.child.on('error', () => this.fail('INTERNAL'));
    this.child.on('close', () => {
      this.exited = true;
      this.finishIfNeeded();
    });
  }

  /** Redacted stderr collected so far, for internal diagnostics only. */
  get diagnosticStderr(): string {
    return this.redactor.redact(this.stderrChunks.join(''));
  }

  private appendStderr(text: string): void {
    if (this.stderrBytes >= MAX_STDERR_BYTES) {
      return;
    }
    this.stderrChunks.push(text);
    this.stderrBytes += Buffer.byteLength(text, 'utf8');
    while (this.stderrBytes > MAX_STDERR_BYTES && this.stderrChunks.length > 0) {
      const removed = this.stderrChunks.shift();
      this.stderrBytes -= removed ? Buffer.byteLength(removed, 'utf8') : 0;
    }
  }

  /**
   * A single stdout line exceeded the cap. Fail closed permanently: fail the
   * scan as INTERNAL and kill the exact child so no later line can be accepted.
   */
  private handleLineOverflow(): void {
    this.protocolFailure('INTERNAL');
  }

  /**
   * Permanently fails the scan for a protocol or transport failure and kills
   * the exact child. Every later event is ignored.
   */
  private protocolFailure(code: NativeErrorCode): void {
    this.fail(code);
    this.forceKill();
  }

  /**
   * Enforces the native event state machine:
   * one valid `started` first, progress only between started and terminal,
   * exactly one terminal whose scanId matches, and no events after a terminal.
   */
  private handleLine(line: string): void {
    if (this.violatedState) {
      return;
    }
    if (line.trim().length === 0) {
      return;
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(line);
    } catch {
      this.protocolFailure('INTERNAL');
      return;
    }
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      this.protocolFailure('INTERNAL');
      return;
    }
    const event = parsed as Record<string, unknown>;
    switch (event['type']) {
      case 'started': {
        if (this.startedScanId !== undefined || this.pendingTerminal !== undefined) {
          this.protocolFailure('INTERNAL');
          return;
        }
        const scanId = event['scanId'];
        const rootNodeId = event['rootNodeId'];
        if (
          typeof scanId !== 'string' ||
          !isUuid(scanId) ||
          typeof rootNodeId !== 'string' ||
          !isUInt64String(rootNodeId)
        ) {
          this.protocolFailure('INTERNAL');
          return;
        }
        this.startedScanId = scanId;
        this.startedSettled = true;
        this.startedDeferred.resolve({ scanId, rootNodeId });
        return;
      }
      case 'progress': {
        if (this.startedScanId === undefined || this.pendingTerminal !== undefined) {
          this.protocolFailure('INTERNAL');
          return;
        }
        const visitedEntries = event['visitedEntries'];
        const persistedNodes = event['persistedNodes'];
        const attributedBytes = event['attributedBytes'];
        if (
          typeof visitedEntries !== 'string' ||
          !isUInt64String(visitedEntries) ||
          typeof persistedNodes !== 'string' ||
          !isUInt64String(persistedNodes) ||
          typeof attributedBytes !== 'string' ||
          !isUInt64String(attributedBytes)
        ) {
          this.protocolFailure('INTERNAL');
          return;
        }
        const progress: ScanProgress = {
          visitedEntries,
          persistedNodes,
          attributedBytes,
        };
        this.latestProgress = progress;
        this.onProgress?.(progress);
        return;
      }
      case 'completed':
      case 'cancelled':
      case 'failed': {
        if (this.startedScanId === undefined || this.pendingTerminal !== undefined) {
          this.protocolFailure('INTERNAL');
          return;
        }
        const scanId = event['scanId'];
        if (typeof scanId !== 'string' || scanId !== this.startedScanId) {
          this.protocolFailure('INTERNAL');
          return;
        }
        if (!this.hasValidTerminalFields(event)) {
          this.protocolFailure('INTERNAL');
          return;
        }
        this.pendingTerminal = this.toTerminal(event);
        return;
      }
      case 'error': {
        // An error before `started` is a legitimate failed start; after
        // `started` only a terminal may represent the failure.
        if (this.startedSettled) {
          this.protocolFailure('INTERNAL');
          return;
        }
        this.fail(asErrorCode(event['code']));
        return;
      }
      default:
        this.protocolFailure('INTERNAL');
        return;
    }
  }

  private hasValidTerminalFields(event: Record<string, unknown>): boolean {
    for (const key of [
      'fileCount',
      'directoryCount',
      'inaccessibleCount',
      'issueCount',
      'rootAttributedBytes',
    ]) {
      const value = event[key];
      if (value === undefined) continue;
      if (typeof value !== 'string' || !isUInt64String(value)) return false;
    }
    for (const key of ['startedAt', 'finishedAt']) {
      const value = event[key];
      if (value === undefined || value === null) continue;
      if (typeof value !== 'string' || !isIsoTimestamp(value)) return false;
    }
    const code = event['code'];
    if (code !== undefined && !isNativeErrorCode(code)) {
      return false;
    }
    return true;
  }

  private toTerminal(event: Record<string, unknown>): ScanTerminal {
    const status = event['type'] as ScanTerminal['status'];
    const terminal: ScanTerminal = { status };
    if (typeof event['scanId'] === 'string') terminal.scanId = event['scanId'];
    if (typeof event['code'] === 'string') terminal.code = asErrorCode(event['code']);
    if (typeof event['startedAt'] === 'string' || event['startedAt'] === null) {
      terminal.startedAt = event['startedAt'] as string | null;
    }
    if (typeof event['finishedAt'] === 'string' || event['finishedAt'] === null) {
      terminal.finishedAt = event['finishedAt'] as string | null;
    }
    for (const key of [
      'fileCount',
      'directoryCount',
      'inaccessibleCount',
      'issueCount',
      'rootAttributedBytes',
    ] as const) {
      const value = event[key];
      if (typeof value === 'string') {
        (terminal as unknown as Record<string, unknown>)[key] = value;
      }
    }
    return terminal;
  }

  private fail(code: NativeErrorCode): void {
    if (this.failedCode !== undefined) {
      return;
    }
    this.failedCode = code;
    this.violatedState = true;
    if (!this.startedSettled) {
      this.startedSettled = true;
      this.startedDeferred.reject(new NativeCliError(code));
      return;
    }
    this.forceKill();
  }

  /** Resolves `started`/`done` exactly once, after the child has closed. */
  private finishIfNeeded(): void {
    if (this.violatedState) {
      const code = this.failedCode ?? 'INTERNAL';
      this.doneDeferred.resolve({
        status: 'failed',
        code,
        ...(this.startedScanId !== undefined ? { scanId: this.startedScanId } : {}),
      });
      return;
    }
    if (this.pendingTerminal !== undefined) {
      this.onTerminal?.(this.pendingTerminal);
      this.doneDeferred.resolve(this.pendingTerminal);
      return;
    }
    if (!this.startedSettled) {
      this.startedSettled = true;
      this.startedDeferred.reject(new NativeCliError('INTERNAL'));
    }
    this.doneDeferred.resolve({ status: 'failed', code: 'INTERNAL' });
  }

  /** Sends SIGINT to the exact child PID, unless it has already exited. */
  cancel(): boolean {
    if (this.exited || this.child.exitCode !== null || this.child.pid !== this.pid) {
      return false;
    }
    try {
      process.kill(this.pid, 'SIGINT');
      return true;
    } catch {
      return false;
    }
  }

  /** Escalates to SIGKILL on the exact child PID. */
  forceKill(): boolean {
    if (this.exited || this.child.exitCode !== null || this.child.pid !== this.pid) {
      return false;
    }
    try {
      process.kill(this.pid, 'SIGKILL');
      return true;
    } catch {
      return false;
    }
  }
}

/**
 * Runs a one-shot JSON command (`volume`, `status`, `children`, `issues`) and
 * returns the decoded object. Throws `NativeCliError` on any non-zero exit.
 */
export function runCliJson(
  cliPath: string,
  args: string[],
  redactor: Redactor,
  timeoutMs = 30_000,
): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const child = spawn(cliPath, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    if (child.pid === undefined) {
      reject(new NativeCliError('INTERNAL'));
      return;
    }
    const pid = child.pid;
    let stdout = '';
    let stderrBytes = 0;
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      try {
        process.kill(pid, 'SIGKILL');
      } catch {
        // Already gone.
      }
      settled = true;
      reject(new NativeCliError('INTERNAL'));
    }, timeoutMs);
    timer.unref();

    child.stdout?.on('data', (chunk: Buffer) => {
      if (stdout.length < MAX_JSON_STDOUT_BYTES) {
        stdout += chunk.toString('utf8');
      }
    });
    child.stderr?.on('data', (chunk: Buffer) => {
      if (stderrBytes < MAX_STDERR_BYTES) {
        stderrBytes += chunk.length;
      }
    });
    child.on('error', () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(new NativeCliError('INTERNAL'));
    });
    child.on('close', (code: number | null) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      const line = lastNonEmptyLine(stdout);
      if (line === undefined) {
        reject(new NativeCliError('INTERNAL'));
        return;
      }
      let parsed: unknown;
      try {
        parsed = JSON.parse(line);
      } catch {
        reject(new NativeCliError('INTERNAL'));
        return;
      }
      if (typeof parsed !== 'object' || parsed === null) {
        reject(new NativeCliError('INTERNAL'));
        return;
      }
      const object = parsed as Record<string, unknown>;
      if (object['type'] === 'error') {
        reject(new NativeCliError(asErrorCode(object['code']), undefined));
        return;
      }
      if (code !== 0) {
        reject(new NativeCliError('INTERNAL'));
        return;
      }
      resolve(object);
    });
  });
}

function lastNonEmptyLine(text: string): string | undefined {
  const lines = text.split('\n').map((line) => line.trim()).filter((line) => line.length > 0);
  return lines.at(-1);
}

export function isNativeErrorCode(value: unknown): value is NativeErrorCode {
  switch (value) {
    case 'INVALID_ARGUMENT':
    case 'NOT_FOUND':
    case 'CONFLICT':
    case 'ACCESS_DENIED':
    case 'INSUFFICIENT_SPACE':
    case 'INTERNAL':
      return true;
    default:
      return false;
  }
}

export function asErrorCode(value: unknown): NativeErrorCode {
  switch (value) {
    case 'INVALID_ARGUMENT':
    case 'NOT_FOUND':
    case 'CONFLICT':
    case 'ACCESS_DENIED':
    case 'INSUFFICIENT_SPACE':
    case 'INTERNAL':
      return value;
    default:
      return 'INTERNAL';
  }
}

/**
 * Splits a byte stream into newline-delimited lines with a hard byte cap.
 *
 * The cap is enforced on raw bytes, so a chunk of multi-byte characters cannot
 * exceed the memory bound. Once any line exceeds the cap the scanner is
 * permanently failed: it reports the overflow once and ignores every later
 * chunk, so a compromised child cannot send an overlong line and then a valid
 * event.
 */
export class LineScanner {
  private pending: Buffer = Buffer.alloc(0);
  private failed = false;
  private overflowReported = false;

  constructor(
    private readonly maxBytes: number,
    private readonly onLine: (line: string) => void,
    private readonly onOverflow: () => void = () => undefined,
  ) {}

  push(chunk: Buffer): void {
    if (this.failed) {
      return;
    }
    const combined = this.pending.length === 0 ? chunk : Buffer.concat([this.pending, chunk]);
    if (combined.length > this.maxBytes && combined.indexOf(0x0a) < 0) {
      this.fail();
      return;
    }
    let start = 0;
    for (;;) {
      const newline = combined.indexOf(0x0a, start);
      if (newline < 0) {
        break;
      }
      if (newline - start > this.maxBytes) {
        this.fail();
        return;
      }
      this.onLine(combined.subarray(start, newline).toString('utf8'));
      start = newline + 1;
    }
    this.pending = combined.subarray(start);
    if (this.pending.length > this.maxBytes) {
      this.fail();
    }
  }

  flush(): void {
    if (!this.failed && this.pending.length > 0) {
      const line = this.pending.toString('utf8');
      this.pending = Buffer.alloc(0);
      if (Buffer.byteLength(line, 'utf8') > this.maxBytes) {
        this.fail();
        return;
      }
      this.onLine(line);
    }
    this.pending = Buffer.alloc(0);
  }

  get hasOverflowed(): boolean {
    return this.failed;
  }

  private fail(): void {
    this.failed = true;
    this.pending = Buffer.alloc(0);
    if (!this.overflowReported) {
      this.overflowReported = true;
      this.onOverflow();
    }
  }
}
