/**
 * push-proximity-ping
 *
 * Triggered by a Supabase Database Webhook on INSERT to `proximity_pings`.
 * Sends an APNs push to the *recipient* — the user who did NOT trigger the ping.
 *
 * Required secrets (set via Supabase dashboard → Edge Functions → Secrets):
 *   WEBHOOK_SECRET  — shared secret that the DB webhook sends in the
 *                     Authorization header to authenticate the request
 *   APNS_KEY_P8, APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID — see _shared/apns.ts
 *   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY — auto-injected by Supabase
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { sendApnsPush } from "../_shared/apns.ts";

Deno.serve(async (req: Request) => {
  // ── Auth ──────────────────────────────────────────────────────────────────
  const secret = Deno.env.get("WEBHOOK_SECRET") ?? "";
  if (secret && req.headers.get("authorization") !== `Bearer ${secret}`) {
    return new Response("Unauthorized", { status: 401 });
  }

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return new Response("Bad JSON", { status: 400 });
  }

  // Supabase DB webhooks nest the new row under `record`.
  const record = (payload.record ?? payload.new ?? payload) as Record<
    string,
    unknown
  >;

  const triggeredBy = record["triggered_by_user_id"] as string | null;
  const userAId = record["user_a_id"] as string | null;
  const userBId = record["user_b_id"] as string | null;

  if (!userAId || !userBId) {
    return new Response("Missing user IDs in payload", { status: 400 });
  }

  // Determine recipient: whoever did NOT trigger the ping.
  // If triggered_by is missing (legacy row), notify both users.
  const recipientIds: string[] = triggeredBy
    ? [userAId, userBId].filter((id) => id !== triggeredBy)
    : [userAId, userBId];

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // Fetch recipient(s) apns_token and sender handle in parallel.
  const senderHandle: string = await (async () => {
    if (!triggeredBy) return "A friend";
    const { data } = await supabase
      .from("profiles")
      .select("handle")
      .eq("id", triggeredBy)
      .maybeSingle();
    return (data?.handle as string | null) ?? "A friend";
  })();

  const results: string[] = [];

  for (const recipientId of recipientIds) {
    const { data: profile, error } = await supabase
      .from("profiles")
      .select("apns_token")
      .eq("id", recipientId)
      .maybeSingle();

    if (error || !profile?.apns_token) {
      results.push(`${recipientId}: no token`);
      continue;
    }

    try {
      const { status, body } = await sendApnsPush(profile.apns_token, {
        title: "hang.",
        body: `${senderHandle} is nearby! 👋`,
      });
      results.push(`${recipientId}: APNs ${status} ${body}`);
    } catch (err) {
      results.push(`${recipientId}: error ${err}`);
    }
  }

  console.log("[push-proximity-ping]", results.join(" | "));
  return new Response(JSON.stringify({ results }), {
    headers: { "content-type": "application/json" },
  });
});
