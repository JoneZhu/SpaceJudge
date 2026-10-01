/**
 * Removes startup secrets from any diagnostic text.
 *
 * The native CLI and the tool layer already produce path-free messages, but
 * stderr from a child process or a Node.js `spawn` error can still embed a
 * path. Every diagnostic passes through this redactor before it reaches a
 * log, an error message or a tool result.
 */
export interface Redactor {
  redact(text: string): string;
}

const REPLACEMENT = '[redacted]';

export function createRedactor(secrets: string[]): Redactor {
  const unique = [...new Set(secrets.filter((secret) => secret.length >= 2))].sort(
    (left, right) => right.length - left.length,
  );
  const explicit = unique.map((secret) => new RegExp(escapeRegExp(secret), 'g'));
  const generic = [
    /\/Users\/[^/\s"'`]+/g,
    /\/home\/[^/\s"'`]+/g,
    /\/private\/var\/folders\/[^\s"'`]+/g,
    /\/var\/folders\/[^\s"'`]+/g,
    /\/private\/tmp\/[^\s"'`]+/g,
    /\/tmp\/[^\s"'`]+/g,
  ];
  return {
    redact(text: string): string {
      let result = text;
      for (const pattern of [...explicit, ...generic]) {
        result = result.replace(pattern, REPLACEMENT);
      }
      return result;
    },
  };
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** A redactor that substitutes a fixed token; used by unit tests. */
export function identityRedactor(): Redactor {
  return { redact: (text: string) => text };
}
