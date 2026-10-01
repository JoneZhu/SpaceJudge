import fs from 'node:fs';
import * as z from 'zod/v4';
import { gigabytes } from './sizes.js';

const id = z.string().regex(/^(0|[1-9]\d{0,19})$/).refine(v => BigInt(v) <= 18446744073709551615n);
const size = z.object({ bytes: id, gb: z.string() }).strict()
  .refine(v => gigabytes(v.bytes) === v.gb, 'GB must match exact bytes');
const node = z.object({
  nodeId: id, parentId: id.nullable().optional(), name: z.string().max(1024), nameTruncated: z.boolean(),
  kind: z.enum(['directory', 'mountPoint', 'regularFile', 'symbolicLink', 'socket', 'fifo',
    'characterDevice', 'blockDevice', 'unknown']),
  flags: z.number().int().min(0).max(4294967295), attributed: size,
  aggregateComplete: z.boolean().nullable().optional(),
}).strict();
export const analysisReportSchema = z.object({
  schemaVersion: z.literal(1), scanId: z.uuid(), revision: id,
  scanStatus: z.enum(['completed', 'cancelled', 'failed', 'interrupted']),
  capturedAt: z.iso.datetime(), scopeNodeId: id, metric: z.literal('attributedBytes'),
  nodes: z.array(node).min(1).max(2000),
  pages: z.array(z.object({ nodeId: id, totalChildren: id, childIds: z.array(id).max(50),
    truncated: z.boolean() }).strict()).max(64),
  captureTruncated: z.boolean(), scanIssueCount: id, scanInaccessibleCount: id,
}).strict();
export type AnalysisReport = z.infer<typeof analysisReportSchema>;

/** Validate connected scope and page completeness; IDs outside it are never queryable. */
export function validateReport(value: unknown): AnalysisReport {
  const report = analysisReportSchema.parse(value);
  const byId = new Map(report.nodes.map(n => [n.nodeId, n]));
  if (byId.size !== report.nodes.length || !byId.has(report.scopeNodeId)) throw new Error('Invalid report graph');
  const root = byId.get(report.scopeNodeId)!;
  if (root.parentId != null) throw new Error('Scope must be root');
  for (const n of report.nodes) {
    const seen = new Set<string>();
    let current = n;
    while (current.nodeId !== root.nodeId) {
      if (seen.has(current.nodeId) || current.parentId == null) throw new Error('Disconnected report');
      seen.add(current.nodeId);
      const parent = byId.get(current.parentId);
      if (!parent || !['directory', 'mountPoint'].includes(parent.kind)) throw new Error('Invalid parent');
      current = parent;
    }
  }
  const pageIds = new Set<string>();
  const listed = new Set<string>();
  for (const p of report.pages) {
    const parent = byId.get(p.nodeId);
    if (!parent || !['directory', 'mountPoint'].includes(parent.kind) || pageIds.has(p.nodeId)) {
      throw new Error('Invalid directory page');
    }
    pageIds.add(p.nodeId);
    if (BigInt(p.totalChildren) < BigInt(p.childIds.length)
        || p.truncated !== (BigInt(p.totalChildren) > BigInt(p.childIds.length))) throw new Error('Invalid page count');
    for (const child of p.childIds) {
      if (listed.has(child) || byId.get(child)?.parentId !== p.nodeId) throw new Error('Invalid child');
      listed.add(child);
    }
  }
  if (listed.size !== report.nodes.length - 1) throw new Error('Unlisted report node');
  const incomplete = report.pages.some(p => p.truncated)
    || report.nodes.some(n => ['directory', 'mountPoint'].includes(n.kind) && !pageIds.has(n.nodeId));
  if (incomplete && !report.captureTruncated) throw new Error('Missing capture truncation');
  return report;
}

export function loadReport(reportPath: string): AnalysisReport {
  // Open once, refusing symlinks, then bound allocation before reading.
  const fd = fs.openSync(reportPath, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.size > 4 * 1024 * 1024) throw new Error('Report too large');
    return validateReport(JSON.parse(fs.readFileSync(fd, 'utf8')));
  } finally { fs.closeSync(fd); }
}
