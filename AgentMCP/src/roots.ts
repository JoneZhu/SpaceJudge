import fs from 'node:fs';
import path from 'node:path';

/**
 * A startup-authorized directory.
 *
 * `canonicalPath` is a runtime secret: it is used only to spawn the native CLI
 * and is never placed in a tool result, log or error message. `displayName` is
 * a sanitized last path component.
 */
export interface AllowedRoot {
  readonly rootId: string;
  readonly canonicalPath: string;
  readonly displayName: string;
}

/** A startup-configuration failure. `message` never contains a path. */
export class RootConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'RootConfigError';
  }
}

const MAX_DISPLAY_LENGTH = 128;

/** Hard upper bound matching the public `list_allowed_roots` output schema. */
export const MAX_ALLOWED_ROOTS = 64;

/**
 * Validates repeated `--allow-root` arguments in command-line order.
 *
 * Each candidate must be absolute, exist, be a directory and not be a symbolic
 * link; it is then canonicalized and deduplicated by real path. The returned
 * roots expose only `root-1`, `root-2` IDs and a sanitized display name.
 */
export function parseAllowedRoots(candidates: string[]): AllowedRoot[] {
  const roots: AllowedRoot[] = [];
  const seen = new Set<string>();
  candidates.forEach((candidate, index) => {
    const friendlyIndex = index + 1;
    if (!path.isAbsolute(candidate)) {
      throw new RootConfigError(`--allow-root #${friendlyIndex} is not an absolute path`);
    }
    let stats: fs.Stats;
    try {
      stats = fs.lstatSync(candidate);
    } catch {
      throw new RootConfigError(`--allow-root #${friendlyIndex} does not exist`);
    }
    if (stats.isSymbolicLink()) {
      throw new RootConfigError(`--allow-root #${friendlyIndex} is a symbolic link`);
    }
    if (!stats.isDirectory()) {
      throw new RootConfigError(`--allow-root #${friendlyIndex} is not a directory`);
    }
    let canonical: string;
    try {
      canonical = fs.realpathSync(candidate);
    } catch {
      throw new RootConfigError(`--allow-root #${friendlyIndex} cannot be resolved`);
    }
    if (seen.has(canonical)) {
      return;
    }
    seen.add(canonical);
    if (roots.length >= MAX_ALLOWED_ROOTS) {
      throw new RootConfigError(
        `too many --allow-root values (maximum ${MAX_ALLOWED_ROOTS} unique roots)`,
      );
    }
    roots.push({
      rootId: `root-${roots.length + 1}`,
      canonicalPath: canonical,
      displayName: sanitizeDisplayName(path.basename(canonical), roots.length + 1),
    });
  });
  return roots;
}

/**
 * Strips control characters (including newlines), path separators and trims to
 * a bounded label. A name is untrusted metadata; it is never interpreted.
 */
export function sanitizeDisplayName(name: string, ordinal: number): string {
  const cleaned = name
    .normalize('NFC')
    .replace(/[\u0000-\u001f\u007f/\\]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  if (cleaned.length === 0) {
    return `root-${ordinal}`;
  }
  return cleaned.length > MAX_DISPLAY_LENGTH
    ? `${cleaned.slice(0, MAX_DISPLAY_LENGTH - 1)}…`
    : cleaned;
}
