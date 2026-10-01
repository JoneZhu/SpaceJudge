/**
 * SI gigabyte formatting shared by every MCP capacity field.
 *
 * The exact byte string stays the source of truth; `GB` is a derived,
 * human-readable projection. All arithmetic uses `BigInt`, so no UInt64 value
 * ever passes through `Number` and `2^53` is never a cliff.
 */

const UINT64_MAX = 18446744073709551615n;
/** Bytes per `0.01 GB`, so quotient truncation rounds to two decimals. */
const BYTES_PER_HUNDREDTH_GB = 10_000_000n;
/** Half of one hundredth, added before truncation for half-up rounding. */
const HALF_HUNDREDTH_GB = 5_000_000n;

/**
 * Formats a canonical decimal UInt64 byte string as a fixed two-decimal GB
 * string using SI units (`1 GB = 1_000_000_000 bytes`).
 *
 * The rounding is half-up, the digits are ASCII and locale-independent, and
 * the result is always a plain decimal string with two fraction digits.
 * `null` or a malformed value returns `null`, exactly like the byte field.
 */
export function gigabytes(bytes: string | null): string | null {
  if (bytes === null || !/^\d{1,20}$/.test(bytes)) {
    return null;
  }
  const value = BigInt(bytes);
  if (value > UINT64_MAX) {
    return null;
  }
  const hundredths = (value + HALF_HUNDREDTH_GB) / BYTES_PER_HUNDREDTH_GB;
  const whole = hundredths / 100n;
  const fraction = hundredths % 100n;
  return `${whole.toString()}.${fraction < 10n ? '0' : ''}${fraction.toString()}`;
}
