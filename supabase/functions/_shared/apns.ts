/**
 * Shared APNs helper — builds a JWT and sends a push notification.
 *
 * Required environment variables (set via `supabase secrets set`):
 *   APNS_KEY_P8     — raw content of the .p8 file (no header/footer lines needed,
 *                     but keeping them is fine — they are stripped automatically)
 *   APNS_KEY_ID     — 10-char Key ID from Apple Developer portal
 *   APNS_TEAM_ID    — 10-char Team ID from Apple Developer portal
 *   APNS_BUNDLE_ID  — e.g. com.hangsocial.hang
 */

const APNS_HOST = "https://api.push.apple.com";
// For sandbox / development builds use:
// const APNS_HOST = "https://api.sandbox.push.apple.com";

// ---------------------------------------------------------------------------
// JWT helpers
// ---------------------------------------------------------------------------

function base64urlEncode(buf: ArrayBuffer): string {
  const bytes = new Uint8Array(buf);
  let str = "";
  for (const b of bytes) str += String.fromCharCode(b);
  return btoa(str).replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
}

function strToBase64url(str: string): string {
  return base64urlEncode(new TextEncoder().encode(str).buffer);
}

/** Import an ES256 private key from a PKCS#8 PEM (.p8 file). */
async function importApnsKey(p8: string): Promise<CryptoKey> {
  // Strip PEM header/footer and whitespace.
  const der = atob(
    p8
      .replace(/-----[^-]+-----/g, "")
      .replace(/\s/g, ""),
  );
  const buf = Uint8Array.from(der, (c) => c.charCodeAt(0)).buffer;
  return crypto.subtle.importKey(
    "pkcs8",
    buf,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}

/** Build a short-lived APNs provider JWT (valid for up to 1 hour). */
async function buildApnsJwt(keyId: string, teamId: string): Promise<string> {
  const p8 = Deno.env.get("APNS_KEY_P8") ?? "";
  if (!p8) throw new Error("APNS_KEY_P8 env var not set");

  const key = await importApnsKey(p8);

  const header = strToBase64url(JSON.stringify({ alg: "ES256", kid: keyId }));
  const payload = strToBase64url(
    JSON.stringify({ iss: teamId, iat: Math.floor(Date.now() / 1000) }),
  );
  const sigInput = new TextEncoder().encode(`${header}.${payload}`);
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    sigInput,
  );

  return `${header}.${payload}.${base64urlEncode(sig)}`;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

export interface ApnsPayload {
  title: string;
  body: string;
  /** APNs topic — defaults to APNS_BUNDLE_ID env var. */
  topic?: string;
}

/**
 * Sends a push notification to a single APNs device token.
 * Returns the HTTP status from APNs (200 = success).
 */
export async function sendApnsPush(
  deviceToken: string,
  payload: ApnsPayload,
): Promise<{ status: number; body: string }> {
  const keyId = Deno.env.get("APNS_KEY_ID") ?? "";
  const teamId = Deno.env.get("APNS_TEAM_ID") ?? "";
  const bundleId = payload.topic ?? Deno.env.get("APNS_BUNDLE_ID") ?? "";

  if (!keyId || !teamId || !bundleId) {
    throw new Error(
      "Missing APNs env vars (APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID)",
    );
  }

  const jwt = await buildApnsJwt(keyId, teamId);

  const apnsPayload = {
    aps: {
      alert: { title: payload.title, body: payload.body },
      sound: "default",
      "interruption-level": "time-sensitive",
    },
  };

  const url = `${APNS_HOST}/3/device/${deviceToken}`;
  const resp = await fetch(url, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": bundleId,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify(apnsPayload),
  });

  const text = await resp.text();
  return { status: resp.status, body: text };
}
