// Receives a store's Swipe payment-confirmation webhook for a Buy now order
// and marks the order paid, recording Maldexpress's fee.
//
// Each store registers this URL in its own Swipe Merchant Portal:
//   https://<project>.supabase.co/functions/v1/swipe-order-webhook?business=<store id>
// The ?business= value picks which store's signing secret to verify with
// (from business_swipe_accounts). The signature check is what proves the
// call came from that store's Swipe client; the query value alone grants
// nothing.
//
// Fees (keep in sync with SWIPE_FEES in index.html):
//   platform_fee     = 5% of the order total (Maldexpress's cut)
//   swipe_fee        = 1% of the total (Swipe's charge, already taken from
//                      the store's wallet), split 1:1 with Maldexpress
//   platform_fee_due = platform_fee - swipe_fee / 2  (what the store owes)
// Rates can be overridden with PLATFORM_FEE_RATE / SWIPE_FEE_RATE secrets.
//
// Deploy with JWT verification off (Swipe sends no Supabase token):
//   supabase functions deploy swipe-order-webhook --no-verify-jwt
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are auto-provided by the runtime.

import { createClient } from "npm:@supabase/supabase-js@2";

const PLATFORM_FEE_RATE = Number(Deno.env.get("PLATFORM_FEE_RATE") ?? "0.05");
const SWIPE_FEE_RATE = Number(Deno.env.get("SWIPE_FEE_RATE") ?? "0.01");

const round2 = (n: number) => Math.round(n * 100) / 100;

function base64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}
function bytesToBase64(buf: ArrayBuffer): string {
  return btoa(String.fromCharCode(...new Uint8Array(buf)));
}

// Standard Webhooks signature (https://www.standardwebhooks.com/), same
// scheme as swipe-webhook.
async function verifyStandardWebhook(secret: string, id: string, timestamp: string, body: string, signatureHeader: string): Promise<boolean> {
  const secretB64 = secret.startsWith("whsec_") ? secret.slice(6) : secret;
  const key = await crypto.subtle.importKey("raw", base64ToBytes(secretB64), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sigBuf = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${id}.${timestamp}.${body}`));
  const expected = bytesToBase64(sigBuf);
  return signatureHeader.split(" ").map((s) => s.split(",")[1]).filter(Boolean).some((sig) => sig === expected);
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  try {
    const businessId = new URL(req.url).searchParams.get("business") ?? "";
    const id = req.headers.get("webhook-id") ?? "";
    const timestamp = req.headers.get("webhook-timestamp") ?? "";
    const signature = req.headers.get("webhook-signature") ?? "";
    const body = await req.text();
    if (!businessId) return new Response("Missing ?business=", { status: 400 });
    if (!id || !timestamp || !signature) return new Response("Missing signature headers", { status: 400 });

    const tsSeconds = Number(timestamp);
    if (!Number.isFinite(tsSeconds) || Math.abs(Date.now() / 1000 - tsSeconds) > 300) {
      return new Response("Timestamp out of tolerance", { status: 400 });
    }

    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    const { data: acct } = await admin
      .from("business_swipe_accounts")
      .select("webhook_secret")
      .eq("business_id", businessId)
      .maybeSingle();
    if (!acct) return new Response("Unknown store", { status: 404 });

    if (!(await verifyStandardWebhook(acct.webhook_secret, id, timestamp, body, signature))) {
      return new Response("Invalid signature", { status: 401 });
    }

    const event = JSON.parse(body);
    // Swipe reports a completed payment as "FULFILLED" (see swipe-webhook).
    const status = String(event.data?.status ?? event.status ?? "").toUpperCase();
    const isSuccess = status === "FULFILLED" || status === "COMPLETED"
      || event.type === "payment.completed" || event.type === "payment.succeeded";
    if (!isSuccess) return new Response("ok", { status: 200 });

    const paymentRef = event.data?.reference ?? event.data?.id ?? event.reference ?? event.id;
    if (!paymentRef) return new Response("Missing payment reference in event payload", { status: 400 });

    const { data: order } = await admin
      .from("orders")
      .select("id, total, payment_status")
      .eq("swipe_reference", paymentRef)
      .eq("business_id", businessId)
      .maybeSingle();
    if (!order) {
      console.error("No matching order for reference", paymentRef, "store", businessId);
      return new Response("ok", { status: 200 }); // ack so Swipe stops retrying
    }
    if (order.payment_status === "paid") return new Response("ok", { status: 200 }); // idempotent

    const total = Number(order.total);
    const paidAmount = Number(event.data?.amount ?? event.amount ?? NaN);
    if (Number.isFinite(paidAmount) && Math.abs(paidAmount - total) > 0.01) {
      console.error(`Amount mismatch on order ${order.id}: paid ${paidAmount}, total ${total}`);
      return new Response("ok", { status: 200 }); // leave unpaid for a person to check
    }

    const swipeFee = round2(total * SWIPE_FEE_RATE);
    const platformFee = round2(total * PLATFORM_FEE_RATE);
    const platformFeeDue = round2(platformFee - swipeFee / 2);

    const { error: updErr } = await admin
      .from("orders")
      .update({
        payment_status: "paid",
        paid_at: new Date().toISOString(),
        swipe_fee: swipeFee,
        platform_fee: platformFee,
        platform_fee_due: platformFeeDue,
      })
      .eq("id", order.id)
      .eq("payment_status", "awaiting_swipe");
    if (updErr) {
      console.error("Failed to mark order paid:", updErr);
      return new Response("Internal error", { status: 500 }); // Swipe will retry
    }
    return new Response("ok", { status: 200 });
  } catch (e) {
    console.error(e);
    return new Response("Internal error", { status: 500 });
  }
});
