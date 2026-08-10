import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const EXPECTED_PUBLISHABLE_KEY_SHA256 =
  "dacb3ab5514cf7a6b75006d11f975a10090a2d885e0a37256f79111e32fae6db";
// SHA-256 verifiers for the active 256-bit administrator tokens. These are
// safe to deploy (the raw tokens remain only in Keychain), and let the Edge
// Function reject unauthenticated requests before reading or sorting a body.
// The database still checks is_active inside the atomic RPC, so revocation is
// authoritative even while a function version is rolling out.
const ACTIVE_ADMIN_TOKEN_SHA256 = [
  "c473bc949c5085929beee1bd3c544ff70505606a062f3a0a4933048bfe2a6520",
] as const;
const MAX_BODY_BYTES = 512 * 1024;
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const HASH_PATTERN = /^[0-9a-f]{64}$/;
const ADMIN_TOKEN_PATTERN = /^(?:[0-9a-fA-F]{64}|[A-Za-z0-9_-]{43}|[A-Za-z0-9+/]{43}=)$/;

type AdminRequest = {
  action?: unknown;
  code_hash?: unknown;
  batch_id?: unknown;
  payload_digest?: unknown;
  code_hashes?: unknown;
};

const responseHeaders = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store",
};

function json(status: number, value: Record<string, unknown>): Response {
  return new Response(JSON.stringify(value), { status, headers: responseHeaders });
}

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return bytesToHex(new Uint8Array(digest));
}

function internalSecretKey(): string {
  const encoded = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (!encoded) throw new Error("Supabase secret keys are unavailable.");
  const keys = JSON.parse(encoded) as Record<string, unknown>;
  const preferred = keys.stupidmirror_license ?? keys.default;
  const candidate = typeof preferred === "string"
    ? preferred
    : Object.values(keys).find((value) =>
      typeof value === "string" && value.startsWith("sb_secret_")
    );
  if (typeof candidate !== "string" || !candidate.startsWith("sb_secret_")) {
    throw new Error("A modern Supabase secret key is unavailable.");
  }
  return candidate;
}

function constantTimeEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return difference === 0;
}

function statusFor(code: unknown): number {
  switch (code) {
    case "unauthorized":
      return 401;
    case "malformed_request":
      return 400;
    case "batch_conflict":
    case "duplicate_code":
      return 409;
    case "invalid_or_unavailable":
      return 422;
    default:
      return 503;
  }
}

async function callRPC(
  name: string,
  body: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const supabaseURL = Deno.env.get("SUPABASE_URL");
  const secretKey = internalSecretKey();
  if (!supabaseURL) {
    throw new Error("The licensing service is not configured.");
  }

  const rpcResponse = await fetch(
    `${supabaseURL}/rest/v1/rpc/${name}`,
    {
      method: "POST",
      headers: {
        apikey: secretKey,
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(12_000),
    },
  );
  if (!rpcResponse.ok) {
    throw new Error(`License admin RPC failed with status ${rpcResponse.status}.`);
  }
  return await rpcResponse.json() as Record<string, unknown>;
}

Deno.serve(async (request: Request) => {
  if (request.method !== "POST") {
    return json(405, { ok: false, code: "method_not_allowed" });
  }

  const publishableKey = request.headers.get("apikey") ?? "";
  const publishableKeyHash = await sha256(publishableKey);
  if (!constantTimeEqual(publishableKeyHash, EXPECTED_PUBLISHABLE_KEY_SHA256)) {
    return json(401, { ok: false, code: "unauthorized" });
  }

  const authorization = request.headers.get("authorization") ?? "";
  const adminToken = authorization.startsWith("SM-Admin ")
    ? authorization.slice("SM-Admin ".length)
    : "";
  if (!ADMIN_TOKEN_PATTERN.test(adminToken)) {
    return json(401, { ok: false, code: "unauthorized" });
  }
  const adminTokenHash = await sha256(adminToken);
  if (
    !ACTIVE_ADMIN_TOKEN_SHA256.some((expected) =>
      constantTimeEqual(adminTokenHash, expected)
    )
  ) {
    return json(401, { ok: false, code: "unauthorized" });
  }

  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (contentLength > MAX_BODY_BYTES) {
    return json(413, { ok: false, code: "request_too_large" });
  }

  let body: AdminRequest;
  try {
    const rawBody = await request.text();
    if (new TextEncoder().encode(rawBody).byteLength > MAX_BODY_BYTES) {
      return json(413, { ok: false, code: "request_too_large" });
    }
    const parsedBody: unknown = JSON.parse(rawBody);
    if (
      typeof parsedBody !== "object" ||
      parsedBody === null ||
      Array.isArray(parsedBody)
    ) {
      return json(400, { ok: false, code: "malformed_request" });
    }
    body = parsedBody as AdminRequest;
  } catch {
    return json(400, { ok: false, code: "malformed_request" });
  }

  if (body.action === "reset_code") {
    const codeHash = typeof body.code_hash === "string" ? body.code_hash : "";
    if (!HASH_PATTERN.test(codeHash)) {
      return json(400, { ok: false, code: "malformed_request" });
    }

    try {
      const result = await callRPC("stupidmirror_admin_reset_license_code", {
        p_admin_token_hash: adminTokenHash,
        p_code_hash: codeHash,
      });
      return json(result.ok === true ? 200 : statusFor(result.code), result);
    } catch {
      return json(503, {
        ok: false,
        code: "temporarily_unavailable",
        message: "The license administration service is temporarily unavailable.",
      });
    }
  }

  // Existing generators omit action. Keep that request shape stable while
  // allowing newer callers to state the operation explicitly.
  if (body.action !== undefined && body.action !== "create_batch") {
    return json(400, { ok: false, code: "malformed_request" });
  }

  const batchID = typeof body.batch_id === "string" ? body.batch_id : "";
  const payloadDigest = typeof body.payload_digest === "string"
    ? body.payload_digest
    : "";
  const codeHashes = Array.isArray(body.code_hashes) ? body.code_hashes : [];
  if (
    !UUID_PATTERN.test(batchID) ||
    !HASH_PATTERN.test(payloadDigest) ||
    codeHashes.length < 1 ||
    codeHashes.length > 5000 ||
    !codeHashes.every((value) => typeof value === "string" && HASH_PATTERN.test(value))
  ) {
    return json(400, { ok: false, code: "malformed_request" });
  }

  const computedPayloadDigest = await sha256(
    [...codeHashes].sort().join("\n") + "\n",
  );
  if (!constantTimeEqual(computedPayloadDigest, payloadDigest)) {
    return json(400, { ok: false, code: "malformed_request" });
  }

  try {
    const result = await callRPC("stupidmirror_admin_create_license_batch", {
      p_admin_token_hash: adminTokenHash,
      p_batch_id: batchID,
      p_payload_digest: payloadDigest,
      p_code_hashes: codeHashes,
    });
    if (result.ok === true && typeof result.count === "number") {
      result.code_count = result.count;
    }
    return json(result.ok === true ? 200 : statusFor(result.code), result);
  } catch {
    // Never log or return the admin token, request body, or code hashes.
    return json(503, {
      ok: false,
      code: "temporarily_unavailable",
      message: "The license administration service is temporarily unavailable.",
    });
  }
});
