// Receives a Swipe payment-confirmation webhook (Standard Webhooks format:
// https://www.standardwebhooks.com/) and, once verified, auto-approves the
// matching pro_upgrade_requests row and grants Pro tier - no admin action
// needed. This is the only piece that's allowed to bypass RLS (via the
// service role key), because the signature check below is what proves the
// event genuinely originated from Swipe.
//
// NOT called by Swipe directly. Maldexpress shares one Swipe client with
// SeaFare, and Swipe only supports one webhook URL per client - it's
// registered to SeaFare's endpoint (https://seafare.onrender.com/api/webhooks/swipe).
// SeaFare's webhook handler forwards any event whose reference is prefixed
// "maldexpress_" here, server-to-server, preserving the original
// webhook-id/webhook-timestamp/webhook-signature headers and raw body
// exactly as Swipe sent them. Because it's the same shared signing secret,
// the verification below still passes on a forwarded call - SeaFare isn't
// vouching for the event, it's relaying the same signed proof Swipe gave
// it. This function has no way to tell a direct Swipe call from a
// forwarded one, and doesn't need to.
//
// Requires this secret (Supabase Dashboard -> Edge Functions -> Secrets):
//   SWIPE_WEBHOOK_SECRET  - the SAME signing secret SeaFare uses (it's one
//                           webhook registration in Swipe's Merchant
//                           Portal) - pull it from SeaFare's own Render env
//                           vars rather than regenerating anything,
//                           typically formatted like "whsec_<base64>"
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are auto-provided by the runtime.
//
// IMPORTANT deployment step: this function must have JWT verification
// disabled (the forwarded call carries no Supabase auth token) - toggle
// "Enforce JWT Verification" off for this function in the Dashboard, or
// deploy with `supabase functions deploy swipe-webhook --no-verify-jwt`
// via the CLI.
//
// TODO once the Swipe OpenAPI spec is confirmed:
//   - the success event type name(s) (assumed: "payment.completed" / "payment.succeeded")
//   - where the reference we sent at creation time is echoed back (assumed: data.reference, falls back to data.id)

import { createClient } from "npm:@supabase/supabase-js@2";

const WEBHOOK_SECRET = Deno.env.get("SWIPE_WEBHOOK_SECRET")!;

function base64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}
function bytesToBase64(buf: ArrayBuffer): string {
  return btoa(String.fromCharCode(...new Uint8Array(buf)));
}

async function verifyStandardWebhook(
  id: string,
  timestamp: string,
  body: string,
  signatureHeader: string,
): Promise<boolean> {
  const secretB64 = WEBHOOK_SECRET.startsWith("whsec_") ? WEBHOOK_SECRET.slice(6) : WEBHOOK_SECRET;
  const secretBytes = base64ToBytes(secretB64);
  const signedContent = `${id}.${timestamp}.${body}`;

  const key = await crypto.subtle.importKey(
    "raw",
    secretBytes,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sigBuf = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(signedContent));
  const expected = bytesToBase64(sigBuf);

  // Header can hold multiple space-separated "v1,<base64sig>" values (key rotation).
  const candidates = signatureHeader
    .split(" ")
    .map((s) => s.split(",")[1])
    .filter(Boolean);
  return candidates.some((sig) => sig === expected);
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  try {
    const id = req.headers.get("webhook-id") ?? "";
    const timestamp = req.headers.get("webhook-timestamp") ?? "";
    const signature = req.headers.get("webhook-signature") ?? "";
    const body = await req.text();

    if (!id || !timestamp || !signature) {
      return new Response("Missing signature headers", { status: 400 });
    }

    // Replay protection - reject anything older/newer than 5 minutes.
    const tsSeconds = Number(timestamp);
    if (!Number.isFinite(tsSeconds) || Math.abs(Date.now() / 1000 - tsSeconds) > 300) {
      return new Response("Timestamp out of tolerance", { status: 400 });
    }

    const valid = await verifyStandardWebhook(id, timestamp, body, signature);
    if (!valid) {
      return new Response("Invalid signature", { status: 401 });
    }

    const event = JSON.parse(body);
    const eventType = event.type;
    const paymentRef = event.data?.reference ?? event.data?.id;

    if (eventType !== "payment.completed" && eventType !== "payment.succeeded") {
      // Not a success event (e.g. failed/expired/pending) - ack and ignore.
      return new Response("ok", { status: 200 });
    }
    if (!paymentRef) {
      return new Response("Missing payment reference in event payload", { status: 400 });
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: request, error: reqErr } = await supabase
      .from("pro_upgrade_requests")
      .select("id, business_id, status")
      .eq("swipe_reference", paymentRef)
      .maybeSingle();

    if (reqErr || !request) {
      console.error("No matching pro_upgrade_requests row for reference:", paymentRef);
      // Ack anyway so Swipe doesn't retry forever for a request we'll never find.
      return new Response("ok", { status: 200 });
    }
    if (request.status === "approved") {
      return new Response("ok", { status: 200 }); // already processed - idempotent
    }

    const nowIso = new Date().toISOString();
    await supabase
      .from("pro_upgrade_requests")
      .update({ status: "approved", resolved_at: nowIso })
      .eq("id", request.id);
    await supabase
      .from("businesses")
      .update({ tier: "pro", paid_at: nowIso })
      .eq("id", request.business_id);

    return new Response("ok", { status: 200 });
  } catch (e) {
    console.error(e);
    return new Response("Internal error", { status: 500 });
  }
});
