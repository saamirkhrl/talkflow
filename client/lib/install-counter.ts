// The install counter's request handling, kept apart from the database so it
// can be tested on its own. The app sends one empty POST the first time a fresh
// install launches; this adds 1 to a single number and stores nothing else (see
// docs/telemetry.md).
//
// Nothing here reads the body, the IP address, the user agent or any other
// header, apart from the two that say how big a body is, so that a request
// carrying one can be refused unread. The increment takes no arguments, so no
// request data can reach the database.

export type Increment = () => Promise<void>;

export type Limits = {
  /** Increments one server instance accepts per window before answering 429. */
  perWindow: number;
  windowMs: number;
  now: () => number;
};

// Far above the real install rate, low enough that one instance can't be used
// to add thousands a minute. A refused app simply tries again on its next launch.
export const DEFAULT_LIMITS: Limits = { perWindow: 30, windowMs: 60_000, now: Date.now };

const ALLOW = "POST";

const empty = (status: number, headers?: HeadersInit) => new Response(null, { status, headers });

/** The app never sends a body, so any declared body, or a streamed one, is refused. */
function hasBody(request: Request): boolean {
  const length = request.headers.get("content-length");
  if (length !== null && length.trim() !== "0") return true;
  return request.headers.has("transfer-encoding");
}

export function createInstallRoute(increment: Increment, limits: Limits = DEFAULT_LIMITS) {
  // One number per instance, not per client: there is nothing to tell clients apart by.
  let windowStart = limits.now();
  let used = 0;

  async function POST(request: Request): Promise<Response> {
    if (hasBody(request)) return empty(413);

    const now = limits.now();
    if (now - windowStart >= limits.windowMs) {
      windowStart = now;
      used = 0;
    }
    if (used >= limits.perWindow) return empty(429, { "Retry-After": String(Math.ceil(limits.windowMs / 1000)) });
    used += 1;

    try {
      await increment();
    } catch (error) {
      // Only the driver's error code: messages can name the host or role.
      const code = error && typeof error === "object" && "code" in error ? String(error.code) : "unknown";
      console.error(`install counter: increment failed (${code})`);
      return empty(500);
    }
    return empty(204);
  }

  const notAllowed = async () => empty(405, { Allow: ALLOW });

  return {
    POST,
    GET: notAllowed,
    HEAD: notAllowed,
    PUT: notAllowed,
    PATCH: notAllowed,
    DELETE: notAllowed,
    OPTIONS: notAllowed,
  };
}
