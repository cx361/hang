/**
 * push-friendship-event
 *
 * Triggered by a Supabase Database Webhook on INSERT and UPDATE to `friendships`.
 *
 * INSERT (status = 'pending') → push to addressee_id: "X wants to be your friend!"
 * UPDATE (status = 'accepted') → push to requester_id: "X accepted your friend request!"
 *
 * Required secrets: same as push-proximity-ping.
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

  const record = (payload.record ?? payload.new ?? payload) as Record<
    string,
    unknown
  >;
  // For UPDATE events Supabase also sends the old row.
  const oldRecord = (payload.old_record ?? payload.old ?? {}) as Record<
    string,
    unknown
  >;

  const requesterId = record["requester_id"] as string | null;
  const addresseeId = record["addressee_id"] as string | null;
  const status = record["status"] as string | null;
  const oldStatus = oldRecord["status"] as string | null;

  if (!requesterId || !addresseeId || !status) {
    return new Response("Missing fields in payload", { status: 400 });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  let recipientId: string;
  let senderId: string;
  let messageBody: string;

  if (status === "pending" && oldStatus !== "pending") {
    // New friend request: notify the addressee.
    recipientId = addresseeId;
    senderId = requesterId;
    const { data } = await supabase
      .from("profiles")
      .select("handle")
      .eq("id", senderId)
      .maybeSingle();
    const handle = (data?.handle as string | null) ?? "Someone";
    messageBody = `${handle} wants to be your friend! 🤝`;
  } else if (status === "accepted" && oldStatus !== "accepted") {
    // Request accepted: notify the original requester.
    recipientId = requesterId;
    senderId = addresseeId;
    const { data } = await supabase
      .from("profiles")
      .select("handle")
      .eq("id", senderId)
      .maybeSingle();
    const handle = (data?.handle as string | null) ?? "Someone";
    messageBody = `${handle} accepted your friend request! 🎉`;
  } else {
    // Not an event we care about (e.g. status = 'rejected', or duplicate).
    return new Response(JSON.stringify({ skipped: true }), {
      headers: { "content-type": "application/json" },
    });
  }

  const { data: profile, error } = await supabase
    .from("profiles")
    .select("apns_token")
    .eq("id", recipientId)
    .maybeSingle();

  if (error || !profile?.apns_token) {
    console.log(`[push-friendship-event] No token for ${recipientId}`);
    return new Response(JSON.stringify({ skipped: true, reason: "no token" }), {
      headers: { "content-type": "application/json" },
    });
  }

  const { status: apnsStatus, body } = await sendApnsPush(
    profile.apns_token,
    { title: "hang.", body: messageBody },
  );

  console.log(
    `[push-friendship-event] ${recipientId}: APNs ${apnsStatus} ${body}`,
  );

  return new Response(
    JSON.stringify({ apnsStatus, apnsBody: body }),
    { headers: { "content-type": "application/json" } },
  );
});
