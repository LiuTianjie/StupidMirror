import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const EXPECTED_PUBLISHABLE_KEY_SHA256 =
  "dacb3ab5514cf7a6b75006d11f975a10090a2d885e0a37256f79111e32fae6db";
const MAX_BODY_BYTES = 8 * 1024;
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CODE_PATTERN = /^SM(?:-[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{4}){6}$/;

type LicenseRequest = {
  action?: unknown;
  installation_id?: unknown;
  code?: unknown;
  receipt?: unknown;
  app_version?: unknown;
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

async function hmacSHA256(value: string, secret: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = await crypto.subtle.sign("HMAC", key, encoder.encode(value));
  return bytesToHex(new Uint8Array(digest));
}

function constantTimeEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return difference === 0;
}

function normalizeCode(value: string): string {
  const compact = value.toUpperCase().replace(/[\s-]+/g, "");
  if (!compact.startsWith("SM")) return "";
  const payload = compact.slice(2);
  if (payload.length !== 24) return "";
  return `SM-${payload.match(/.{4}/g)?.join("-") ?? ""}`;
}

function trustedClientAddress(request: Request): string {
  // Cloudflare rejects caller attempts to forge this header before the Edge
  // Function runs. Do not fall back to X-Forwarded-For: a desktop caller can
  // supply arbitrary hops. Missing metadata intentionally shares one bucket,
  // while a separate project-wide bucket remains the final load-shedder.
  const connectingIP = request.headers.get("cf-connecting-ip")?.trim() ?? "";
  if (connectingIP && connectingIP.length <= 128) return connectingIP;
  return "unknown";
}

function statusFor(code: unknown): number {
  switch (code) {
    case "malformed_request":
      return 400;
    case "invalid_receipt":
    case "license_revoked":
      return 403;
    case "rate_limited":
      return 429;
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

  const rpcResponse = await fetch(`${supabaseURL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: secretKey,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(8_000),
  });

  if (!rpcResponse.ok) {
    throw new Error(`License RPC failed with status ${rpcResponse.status}.`);
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

  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (contentLength > MAX_BODY_BYTES) {
    return json(413, { ok: false, code: "request_too_large" });
  }

  let rawBody: string;
  let body: LicenseRequest;
  try {
    rawBody = await request.text();
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
    body = parsedBody as LicenseRequest;
  } catch {
    return json(400, { ok: false, code: "malformed_request" });
  }

  const installationID = typeof body.installation_id === "string"
    ? body.installation_id.toLowerCase()
    : "";
  const appVersion = typeof body.app_version === "string" ? body.app_version : "";
  if (!UUID_PATTERN.test(installationID) || appVersion.length > 64) {
    return json(400, { ok: false, code: "malformed_request" });
  }

  try {
    const installationHash = await sha256(installationID);
    // This subject is independent of the caller-controlled installation UUID.
    // The RPC also enforces a project-wide bucket as a final load-shedder.
    const rateSubjectHash = await hmacSHA256(
      `ip\u0000${trustedClientAddress(request)}`,
      internalSecretKey(),
    );
    let result: Record<string, unknown>;

    if (body.action === "activate") {
      const code = normalizeCode(typeof body.code === "string" ? body.code : "");
      if (!CODE_PATTERN.test(code)) {
        return json(422, {
          ok: false,
          code: "invalid_or_unavailable",
          message: "The activation code is invalid or has already been used.",
        });
      }
      result = await callRPC("stupidmirror_activate_license", {
        p_code_hash: await sha256(code.replaceAll("-", "")),
        p_installation_hash: installationHash,
        p_rate_subject_hash: rateSubjectHash,
        p_app_version: appVersion,
      });
    } else if (body.action === "validate") {
      const receipt = typeof body.receipt === "string" ? body.receipt : "";
      if (!UUID_PATTERN.test(receipt)) {
        // A receipt is an untrusted local entitlement. Treat malformed values
        // as terminal invalid receipts so clients cannot keep an arbitrary
        // non-empty Keychain value licensed forever.
        return json(403, {
          ok: false,
          code: "invalid_receipt",
          message: "This activation receipt is not valid for this installation.",
        });
      }
      result = await callRPC("stupidmirror_validate_license", {
        p_receipt: receipt,
        p_installation_hash: installationHash,
        p_rate_subject_hash: rateSubjectHash,
        p_app_version: appVersion,
      });
    } else {
      return json(400, { ok: false, code: "malformed_request" });
    }

    return json(result.ok === true ? 200 : statusFor(result.code), result);
  } catch {
    // Never include request bodies, activation codes, or internal RPC errors.
    return json(503, {
      ok: false,
      code: "temporarily_unavailable",
      message: "The licensing service is temporarily unavailable.",
    });
  }
});
