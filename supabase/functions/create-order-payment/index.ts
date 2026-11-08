// Creates a Swipe LINK payment for an approved Buy now order, on the STORE'S
// OWN Swipe account (credentials in business_swipe_accounts, which only the
// service role can read). Called from the client with
// sb.functions.invoke('create-order-payment', { body: { orderId } }).
//
// Unlike create-swipe-payment (Pro upgrades), this never touches the shared
// Maldexpress/SeaFare Swipe client: the customer's money goes straight into
// the store's wallet. Maldexpress's fee is recorded on the order by
// swipe-order-webhook and settled with the store separately.
//
// Each store registers this project's swipe-order-webhook URL (with
// ?business=<their store id>) as the webhook in their own Swipe Merchant
// Portal. The app shows them the exact URL when they connect Swipe.
//
// Requires these secrets (Supabase Dashboard -> Edge Functions -> Secrets):
//   SWIPE_TOKEN_URL     - OAuth2 client-credentials token endpoint
//   SWIPE_API_BASE_URL  - Swipe API base (payments endpoint is {base}/api/v1/payments)
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are auto-provided.

import { createClient } from "npm:@supabase/supabase-js@2";
import { createRemoteJWKSet, jwtVerify } from "npm:jose@5.9.6";

// Accounts live in Firebase Auth (project "maldexpress"). The caller sends
// its Firebase ID token; we verify it against Google's public keys and
// require a verified email, the same rule as public.app_uid() in SQL.
// Deploy with --no-verify-jwt: the Supabase gateway doesn't check Firebase
// tokens itself, this function does.
const FIREBASE_PROJECT_ID = Deno.env.get("FIREBASE_PROJECT_ID") ?? "maldexpress";
const FIREBASE_JWKS = createRemoteJWKSet(
  new URL("https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com"),
);
async function firebaseUid(authHeader: string): Promise<string | null> {
  const token = authHeader.replace(/^Bearer\s+/i, "");
  if (!token) return null;
  try {
    const { payload } = await jwtVerify(token, FIREBASE_JWKS, {
      issuer: `https://securetoken.google.com/${FIREBASE_PROJECT_ID}`,
      audience: FIREBASE_PROJECT_ID,
    });
    if (payload.email_verified !== true || typeof payload.sub !== "string" || !payload.sub) return null;
    return payload.sub;
  } catch {
    return null;
  }
}

const SWIPE_TOKEN_URL = Deno.env.get("SWIPE_TOKEN_URL") ?? "";
const SWIPE_API_BASE_URL = Deno.env.get("SWIPE_API_BASE_URL") ?? "";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

// One cached token per store's Swipe client.
const tokenCache = new Map<string, { value: string; expiresAt: number }>();

async function getSwipeAccessToken(clientId: string, clientSecret: string): Promise<string> {
  const cached = tokenCache.get(clientId);
  if (cached && cached.expiresAt > Date.now() + 5000) return cached.value;
  const res = await fetch(SWIPE_TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "client_credentials",
      client_id: clientId,
      client_secret: clientSecret,
    }),
  });
  if (!res.ok) {
    throw new Error(`Swipe token request failed: ${res.status} ${await res.text()}`);
  }
  const json = await res.json();
  const entry = { value: json.access_token, expiresAt: Date.now() + (json.expires_in ?? 3000) * 1000 };
  tokenCache.set(clientId, entry);
  return entry.value;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405, headers: CORS_HEADERS });
  if (!SWIPE_TOKEN_URL || !SWIPE_API_BASE_URL) {
    return jsonResponse({ error: "Missing required secret(s): SWIPE_TOKEN_URL, SWIPE_API_BASE_URL" }, 500);
  }

  try {
    const uid = await firebaseUid(req.headers.get("Authorization") ?? "");
    if (!uid) return jsonResponse({ error: "Not signed in" }, 401);

    const { orderId } = await req.json();
    if (!orderId) return jsonResponse({ error: "orderId is required" }, 400);

    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    const { data: order, error: orderErr } = await admin
      .from("orders")
      .select("id, customer_id, business_id, total, payment_method, payment_status, status, swipe_reference, swipe_payment_link")
      .eq("id", orderId)
      .maybeSingle();
    if (orderErr || !order) return jsonResponse({ error: "Order not found" }, 404);
    if (order.customer_id !== uid) return jsonResponse({ error: "Not your order" }, 403);
    if (order.payment_method !== "swipe") return jsonResponse({ error: "This order isn't paid by Swipe" }, 400);
    if (order.status === "declined") return jsonResponse({ error: "The store declined this order" }, 409);
    if (order.payment_status === "paid") return jsonResponse({ error: "This order is already paid" }, 409);
    if (order.payment_status !== "awaiting_swipe") {
      return jsonResponse({ error: "The store hasn't approved this order yet" }, 409);
    }
    // Reuse the link we already made, so tapping Pay twice doesn't create two payments.
    if (order.swipe_payment_link && order.swipe_reference) {
      return jsonResponse({ paymentLink: order.swipe_payment_link, reference: order.swipe_reference }, 200);
    }

    const { data: acct, error: acctErr } = await admin
      .from("business_swipe_accounts")
      .select("client_id, client_secret")
      .eq("business_id", order.business_id)
      .maybeSingle();
    if (acctErr || !acct) return jsonResponse({ error: "This store hasn't connected Swipe" }, 409);

    const amount = Math.round(Number(order.total) * 100) / 100;
    if (!(amount > 0)) return jsonResponse({ error: "Order total is invalid" }, 400);

    const accessToken = await getSwipeAccessToken(acct.client_id, acct.client_secret);
    const paymentRes = await fetch(`${SWIPE_API_BASE_URL}/api/v1/payments`, {
      method: "POST",
      headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        type: "LINK",
        amount,
        currency: "MVR",
        description: `Maldexpress order #${String(order.id).slice(-5).toUpperCase()}`,
      }),
    });
    if (!paymentRes.ok) {
      console.error("Swipe payment creation failed:", paymentRes.status, await paymentRes.text());
      return jsonResponse({ error: "Swipe payment creation failed" }, 502);
    }
    const payment = await paymentRes.json();
    const paymentLink = payment.payment_url ?? payment.payment_link ?? payment.link ?? payment.url;
    const reference = payment.reference ?? payment.id;
    if (!paymentLink || !reference) {
      console.error("Swipe response missing payment link and/or reference:", JSON.stringify(payment));
      return jsonResponse({ error: "Swipe response missing payment link or reference" }, 502);
    }

    // Only store the link if no other request beat us to it.
    const { data: saved, error: saveErr } = await admin
      .from("orders")
      .update({ swipe_reference: reference, swipe_payment_link: paymentLink })
      .eq("id", order.id)
      .is("swipe_reference", null)
      .select("swipe_reference, swipe_payment_link")
      .maybeSingle();
    if (saveErr) {
      console.error("Failed to save Swipe reference on order:", saveErr);
      return jsonResponse({ error: "Failed to set up payment tracking" }, 500);
    }
    if (!saved) {
      const { data: again } = await admin.from("orders").select("swipe_reference, swipe_payment_link").eq("id", order.id).single();
      return jsonResponse({ paymentLink: again?.swipe_payment_link, reference: again?.swipe_reference }, 200);
    }
    return jsonResponse({ paymentLink, reference }, 200);
  } catch (e) {
    console.error(e);
    return jsonResponse({ error: "Internal error" }, 500);
  }
});
