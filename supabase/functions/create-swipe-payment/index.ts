// Creates a Swipe LINK-type payment for a business's Pro-tier upgrade.
// Called from the client via sb.functions.invoke('create-swipe-payment', { body: { businessId, amount } }).
//
// IMPORTANT: Maldexpress shares one Swipe client with SeaFare (SeaFare Pro
// Payments, client 28279e0d-e093-4211-a2e8-295082406a9b) - no separate
// wallet/client for this app. Swipe only supports one webhook URL per
// client, and it's registered to SeaFare's endpoint
// (https://seafare.onrender.com/api/webhooks/swipe), NOT to this project's
// swipe-webhook function. SeaFare's webhook handler inspects the
// `reference` on every confirmation it receives; anything prefixed
// "maldexpress_" gets forwarded (original headers + body, unmodified) to
// this project's swipe-webhook function, which independently verifies the
// Standard Webhooks signature using the same shared secret. That's why the
// reference below is prefixed - it's the only signal SeaFare's webhook
// uses to route the event here instead of processing it as its own.
//
// Requires these secrets (Supabase Dashboard -> Edge Functions -> Secrets):
//   SWIPE_TOKEN_URL      - OAuth2 client-credentials token endpoint (shared with SeaFare)
//   SWIPE_API_BASE_URL   - Swipe API base (payments endpoint is {base}/api/v1/payments)
//   SWIPE_CLIENT_ID      - 28279e0d-e093-4211-a2e8-295082406a9b (shared with SeaFare)
//   SWIPE_CLIENT_SECRET  - shared with SeaFare
// SUPABASE_URL / SUPABASE_ANON_KEY are auto-provided by the Edge Functions runtime.
//
// TODO once the Swipe OpenAPI spec is confirmed:
//   - token response field names (assumed: access_token, expires_in - standard OAuth2 names)
//   - payment amount units (assumed: MVR major units, not cents/laari)
//   - response field name for the payment link (checks payment_link, link, url)

import { createClient } from "npm:@supabase/supabase-js@2";

const SWIPE_TOKEN_URL = Deno.env.get("SWIPE_TOKEN_URL")!;
const SWIPE_API_BASE_URL = Deno.env.get("SWIPE_API_BASE_URL")!;
const SWIPE_CLIENT_ID = Deno.env.get("SWIPE_CLIENT_ID")!;
const SWIPE_CLIENT_SECRET = Deno.env.get("SWIPE_CLIENT_SECRET")!;

let cachedToken: { value: string; expiresAt: number } | null = null;

async function getSwipeAccessToken(): Promise<string> {
  if (cachedToken && cachedToken.expiresAt > Date.now() + 5000) {
    return cachedToken.value;
  }
  const res = await fetch(SWIPE_TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "client_credentials",
      client_id: SWIPE_CLIENT_ID,
      client_secret: SWIPE_CLIENT_SECRET,
    }),
  });
  if (!res.ok) {
    throw new Error(`Swipe token request failed: ${res.status} ${await res.text()}`);
  }
  const json = await res.json();
  cachedToken = {
    value: json.access_token,
    expiresAt: Date.now() + (json.expires_in ?? 3000) * 1000,
  };
  return cachedToken.value;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );

    const { data: { user }, error: userErr } = await supabase.auth.getUser();
    if (userErr || !user) {
      return new Response(JSON.stringify({ error: "Not authenticated" }), { status: 401 });
    }

    const { businessId, amount } = await req.json();
    if (!businessId || !amount) {
      return new Response(JSON.stringify({ error: "businessId and amount are required" }), { status: 400 });
    }

    // RLS-scoped client (not service role) - this query only succeeds if the
    // caller actually owns the business, so it doubles as an ownership check.
    const { data: biz, error: bizErr } = await supabase
      .from("businesses")
      .select("id, owner_id, name")
      .eq("id", businessId)
      .single();
    if (bizErr || !biz || biz.owner_id !== user.id) {
      return new Response(JSON.stringify({ error: "Not your business" }), { status: 403 });
    }

    const accessToken = await getSwipeAccessToken();

    // Our own reference, sent to Swipe and expected to be echoed back in the
    // webhook payload - this is what we match on later, not Swipe's internal
    // id. The "maldexpress_" prefix is load-bearing: it's how SeaFare's
    // shared webhook handler knows to forward this confirmation here
    // instead of processing it as one of its own payments.
    const reference = `maldexpress_pro_${businessId}_${Date.now()}`;

    const paymentRes = await fetch(`${SWIPE_API_BASE_URL}/api/v1/payments`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        type: "LINK",
        amount,
        currency: "MVR",
        reference,
        description: `Maldexpress Pro upgrade - ${biz.name}`,
      }),
    });

    if (!paymentRes.ok) {
      console.error("Swipe payment creation failed:", paymentRes.status, await paymentRes.text());
      return new Response(JSON.stringify({ error: "Swipe payment creation failed" }), { status: 502 });
    }

    const payment = await paymentRes.json();
    const paymentLink = payment.payment_link ?? payment.link ?? payment.url;
    if (!paymentLink) {
      console.error("Swipe response had no recognizable payment link field:", JSON.stringify(payment));
      return new Response(JSON.stringify({ error: "Swipe response missing payment link" }), { status: 502 });
    }

    return new Response(JSON.stringify({ paymentLink, reference }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error(e);
    return new Response(JSON.stringify({ error: "Internal error" }), { status: 500 });
  }
});
