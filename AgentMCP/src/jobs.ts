import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  NativeCliError,
  ScanProcess,
  runCliJson,
  type ScanProgress,
  type ScanTerminal,
} from './native-client.js';
import type { AllowedRoot } from './roots.js';
import type { Redactor } from './redaction.js';

const START_TIMEOUT_MS = 30_000;
const CANCEL_TIMEOUT_MS = 10_000;
const SHUTDOWN_GRACE_MS = 2_000;

export type JobStatus = 'running' | 'cancelling' | ScanTerminal['status'];

export interface ScanJobRecord {
  readonly scanId: string;
  readonly rootId: string;
  readonly taskDir: string;
  readonly databasePath: string;
  readonly process: ScanProcess;
  status: JobStatus;
  terminal?: ScanTerminal;
}

export interface StartScanResult {
  scanId: string;
  rootNodeId: string;
  status: 'running';
}

/**
 * Owns scan jobs, their private task directories and their child processes.
 *
 * At most one scan runs at a time. Only task directories created by this
 * instance are ever removed; authorized roots are never listed or modified.
 */
export class JobManager {
  private readonly jobs = new Map<string, ScanJobRecord>();
  private readonly taskRoot: string;
  private activeScanId: string | null = null;
  private pendingStart = false;
  private pendingProcess: ScanProcess | null = null;
  private shuttingDown = false;

  constructor(
    private readonly cliPath: string,
    private readonly roots: ReadonlyMap<string, AllowedRoot>,
    private readonly redactor: Redactor,
  ) {
    this.taskRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'spacejudge-mcp-'));
    fs.chmodSync(this.taskRoot, 0o700);
  }

  /** Root directory holding every task-private workspace. Test hook. */
  get taskRootPath(): string {
    return this.taskRoot;
  }

  /** PIDs of non-terminal children, for orphan checks. */
  livePids(): number[] {
    return [...this.jobs.values()]
      .filter((job) => job.terminal === undefined)
      .map((job) => job.process.pid);
  }

  async startScan(rootId: string): Promise<StartScanResult> {
    if (this.shuttingDown) {
      throw new NativeCliError('CONFLICT');
    }
    const root = this.roots.get(rootId);
    if (root === undefined) {
      throw new NativeCliError('NOT_FOUND');
    }
    if (this.pendingStart || this.hasActiveScan()) {
      throw new NativeCliError('CONFLICT');
    }
    this.pendingStart = true;
    try {
      this.cleanupTerminalJobs();
      const taskDir = fs.mkdtempSync(path.join(this.taskRoot, 'task-'));
      fs.chmodSync(taskDir, 0o700);
      const databasePath = path.join(taskDir, 'scan.sqlite');
      const process = new ScanProcess(
        this.cliPath,
        [
          'scan',
          '--root',
          root.canonicalPath,
          '--database',
          databasePath,
          '--workspace',
          taskDir,
        ],
        this.redactor,
      );
      this.pendingProcess = process;
      let started;
      try {
        started = await withTimeout(process.started, START_TIMEOUT_MS);
      } catch (error) {
        // Reap the exact child before touching its directory. If it cannot be
        // reaped within the bounded escalation window, leave the private
        // directory in place and surface INTERNAL rather than deleting under a
        // possibly live process.
        process.forceKill();
        const reaped = await withTimeout(process.done, SHUTDOWN_GRACE_MS, null);
        this.pendingProcess = null;
        if (reaped === null) {
          throw new NativeCliError('INTERNAL');
        }
        safeRemove(taskDir);
        throw error;
      }
      this.pendingProcess = null;
      const record: ScanJobRecord = {
        scanId: started.scanId,
        rootId,
        taskDir,
        databasePath,
        process,
        status: 'running',
      };
      this.jobs.set(record.scanId, record);
      this.activeScanId = record.scanId;
      void process.done.then((terminal) => {
        record.terminal = terminal;
        record.status = terminal.status;
      });
      return { scanId: started.scanId, rootNodeId: started.rootNodeId, status: 'running' };
    } finally {
      this.pendingStart = false;
    }
  }

  getStatus(scanId: string): {
    scanId: string;
    status: JobStatus;
    progress: ScanProgress | null;
    terminal: ScanTerminal | null;
  } {
    const job = this.requireJob(scanId);
    return {
      scanId,
      status: job.terminal?.status ?? job.status,
      progress: job.process.latestProgress ?? null,
      terminal: job.terminal ?? null,
    };
  }

  async listChildren(
    scanId: string,
    nodeId: string,
    limit: number,
  ): Promise<Record<string, unknown>> {
    const job = this.requireJob(scanId);
    return runCliJson(
      this.cliPath,
      [
        'children',
        '--database',
        job.databasePath,
        '--scan-id',
        scanId,
        '--node-id',
        nodeId,
        '--limit',
        String(limit),
      ],
      this.redactor,
    );
  }

  async getIssues(scanId: string): Promise<Record<string, unknown>> {
    const job = this.requireJob(scanId);
    return runCliJson(
      this.cliPath,
      ['issues', '--database', job.databasePath, '--scan-id', scanId],
      this.redactor,
    );
  }

  async getHotspots(
    scanId: string,
    scopeNodeId: string,
    limit: number,
    minimumBytes: string,
  ): Promise<Record<string, unknown>> {
    const job = this.requireJob(scanId);
    return runCliJson(
      this.cliPath,
      [
        'hotspots',
        '--database',
        job.databasePath,
        '--scan-id',
        scanId,
        '--node-id',
        scopeNodeId,
        '--limit',
        String(limit),
        '--min-bytes',
        minimumBytes,
      ],
      this.redactor,
    );
  }

  async getVolume(rootId: string): Promise<Record<string, unknown>> {
    const root = this.roots.get(rootId);
    if (root === undefined) {
      throw new NativeCliError('NOT_FOUND');
    }
    return runCliJson(
      this.cliPath,
      ['volume', '--root', root.canonicalPath],
      this.redactor,
    );
  }

  /** Idempotent cancellation: a terminal job is returned unchanged. */
  async cancel(scanId: string): Promise<JobStatus> {
    const job = this.requireJob(scanId);
    if (job.terminal !== undefined) {
      return job.terminal.status;
    }
    if (job.status === 'cancelling') {
      const settled = await withTimeout(job.process.done, CANCEL_TIMEOUT_MS, null);
      return settled?.status ?? 'cancelling';
    }
    job.status = 'cancelling';
    job.process.cancel();
    let settled = await withTimeout(job.process.done, CANCEL_TIMEOUT_MS, null);
    if (settled === null) {
      job.process.forceKill();
      settled = await withTimeout(job.process.done, SHUTDOWN_GRACE_MS, null);
    }
    if (settled !== null) {
      job.terminal = settled;
      job.status = settled.status;
      return settled.status;
    }
    return 'cancelling';
  }

  /** Cancels and reaps any live child, then removes this instance's task root. */
  async shutdown(): Promise<void> {
    this.shuttingDown = true;
    const reapTargets: ScanProcess[] = [];
    if (this.pendingProcess !== null) {
      reapTargets.push(this.pendingProcess);
    }
    for (const job of this.jobs.values()) {
      if (job.terminal === undefined) {
        reapTargets.push(job.process);
      }
    }
    let allReaped = true;
    for (const process of reapTargets) {
      process.cancel();
      let settled = await withTimeout(process.done, SHUTDOWN_GRACE_MS, null);
      if (settled === null) {
        process.forceKill();
        settled = await withTimeout(process.done, SHUTDOWN_GRACE_MS, null);
      }
      if (settled === null) {
        allReaped = false;
      }
    }
    // Never delete a private directory that a child might still be using.
    if (allReaped) {
      safeRemove(this.taskRoot);
    }
  }

  private requireJob(scanId: string): ScanJobRecord {
    const job = this.jobs.get(scanId);
    if (job === undefined) {
      throw new NativeCliError('NOT_FOUND');
    }
    return job;
  }

  private hasActiveScan(): boolean {
    if (this.activeScanId === null) {
      return false;
    }
    const job = this.jobs.get(this.activeScanId);
    if (job === undefined) {
      this.activeScanId = null;
      return false;
    }
    if (job.terminal !== undefined) {
      this.activeScanId = null;
      return false;
    }
    return true;
  }

  private cleanupTerminalJobs(): void {
    for (const [scanId, job] of this.jobs) {
      if (job.terminal !== undefined) {
        safeRemove(job.taskDir);
        this.jobs.delete(scanId);
      }
    }
    this.activeScanId = null;
  }
}

function withTimeout<T>(promise: Promise<T>, ms: number, fallback?: T): Promise<T>;
function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T>;
function withTimeout<T>(promise: Promise<T>, ms: number, fallback?: T): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      if (fallback !== undefined) {
        resolve(fallback);
      } else {
        reject(new NativeCliError('INTERNAL'));
      }
    }, ms);
    timer.unref();
    promise.then(
      (value) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(value);
      },
      (error: unknown) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}

function safeRemove(target: string): void {
  try {
    fs.rmSync(target, { recursive: true, force: true });
  } catch {
    // Task-private cleanup is best effort; a failure never touches a root.
  }
}
