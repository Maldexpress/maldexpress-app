// Creates a Swipe LINK-type payment for a business's Pro-tier upgrade.
// Called from the client via sb.functions.invoke('create-swipe-payment', { body: { businessId, amount } }).
//
// IMPORTANT: Maldexpress shares one Swipe client with SeaFare (SeaFare Pro
// Payments, client 28279e0d-e093-4211-a2e8-295082406a9b) - no separate
// wallet/client for this app. Swipe only supports one webhook URL per
// client, and it's registered to SeaFare's endpoint
// (https://seafare.onrender.com/api/webhooks/swipe), NOT to this project's
// swipe-webhook function.
//
// Swipe generates its own opaque `reference` for each payment and returns
// it in the create-payment response - the request has no field for the
// caller to supply one (confirmed against SeaFare's real production
// request shape, which sends only { amount, currency, type, description }).
//
// Routing (registration-based, not prefix-based - Swipe-assigned
// references can't be tagged at creation time): immediately after Swipe
// returns a reference, this function (1) inserts the local
// pro_upgrade_requests row and (2) registers the reference with SeaFare's
// internal endpoint - BOTH must succeed before the payment link is ever
// handed back to the client. That ordering matters: it's what guarantees
// neither side's "do I recognize this reference" check can race a webhook
// that fires before the corresponding record exists, since the earliest
// the user could possibly complete payment is after they receive the link,
// which is after both records already exist. SeaFare's webhook then
// forwards only registered references here (server-to-server, original
// headers + body unmodified); everything unregistered stays SeaFare's own,
// exactly as before this shared-wallet arrangement existed.
//
// Requires these secrets (Supabase Dashboard -> Edge Functions -> Secrets):
//   SWIPE_TOKEN_URL        - OAuth2 client-credentials token endpoint (shared with SeaFare)
//   SWIPE_API_BASE_URL     - Swipe API base (payments endpoint is {base}/api/v1/payments)
//   SWIPE_CLIENT_ID        - 28279e0d-e093-4211-a2e8-295082406a9b (shared with SeaFare)
//   SWIPE_CLIENT_SECRET    - shared with SeaFare
//   SEAFARE_REGISTER_URL   - https://seafare.onrender.com/api/internal/register-swipe-reference
//   SEAFARE_INTERNAL_SECRET - shared secret, must be the EXACT same value SeaFare has as
//                             SEAFARE_INTERNAL_SECRET on its side (coordinated, not generated twice)
// SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY are auto-provided by the Edge Functions runtime.
//
// TODO once the Swipe OpenAPI spec is confirmed:
//   - token response field names (assumed: access_token, expires_in - standard OAuth2 names)
//   - payment amount units (assumed: MVR major units, not cents/laari)
//   - response field name for the payment link (checks payment_link, link, url)
//   - response field name for Swipe's generated reference (checks reference, id - matches SeaFare's confirmed request shape, but the response field name is still a guess)

import { createClient } from "npm:@supabase/supabase-js@2";

const SWIPE_TOKEN_URL = Deno.env.get("SWIPE_TOKEN_URL")!;
const SWIPE_API_BASE_URL = Deno.env.get("SWIPE_API_BASE_URL")!;
const SWIPE_CLIENT_ID = Deno.env.get("SWIPE_CLIENT_ID")!;
const SWIPE_CLIENT_SECRET = Deno.env.get("SWIPE_CLIENT_SECRET")!;
const SEAFARE_REGISTER_URL = Deno.env.get("SEAFARE_REGISTER_URL")!;
const SEAFARE_INTERNAL_SECRET = Deno.env.get("SEAFARE_INTERNAL_SECRET")!;

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

// Registers a Swipe-assigned reference with SeaFare's internal endpoint so
// its shared-wallet webhook handler forwards that payment's confirmation
// here. One retry after a short pause; the caller treats a final failure as
// fatal (link withheld, local row rolled back) so the user retries cleanly
// rather than paying for an upgrade neither side can confirm.
async function registerReferenceWithSeaFare(reference: string): Promise<boolean> {
  for (let attempt = 1; attempt <= 2; attempt++) {
    try {
      const res = await fetch(SEAFARE_REGISTER_URL, {
        method: "POST",
        headers: {
          "X-Internal-Secret": SEAFARE_INTERNAL_SECRET,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ reference, source: "maldexpress" }),
        signal: AbortSignal.timeout(10000),
      });
      if (res.ok) {
        const body = await res.json().catch(() => null);
        if (body?.registered === true) return true;
        console.error(`SeaFare registration: HTTP ${res.status} but unexpected body ${JSON.stringify(body)}`);
      } else {
        console.error(`SeaFare registration attempt ${attempt}: HTTP ${res.status} ${await res.text().catch(() => "")}`);
      }
    } catch (e) {
      console.error(`SeaFare registration attempt ${attempt} errored:`, e);
    }
    if (attempt === 1) await new Promise((r) => setTimeout(r, 1000));
  }
  return false;
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

    // No reference field here - Swipe generates its own and returns it
    // below. Matches SeaFare's confirmed real request shape exactly.
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
        description: "Pro upgrade",
      }),
    });

    if (!paymentRes.ok) {
      console.error("Swipe payment creation failed:", paymentRes.status, await paymentRes.text());
      return new Response(JSON.stringify({ error: "Swipe payment creation failed" }), { status: 502 });
    }

    const payment = await paymentRes.json();
    const paymentLink = payment.payment_link ?? payment.link ?? payment.url;
    const reference = payment.reference ?? payment.id;
    if (!paymentLink || !reference) {
      console.error("Swipe response missing payment link and/or reference:", JSON.stringify(payment));
      return new Response(JSON.stringify({ error: "Swipe response missing payment link or reference" }), { status: 502 });
    }

    // Record the pending upgrade and register its reference with SeaFare
    // before handing back the link - see the file header for why this
    // ordering closes the webhook race. Ownership was already checked above,
    // so both writes use the service role: it keeps the insert and the
    // rollback delete consistent and doesn't depend on the owner-delete RLS
    // policy (added to the schema alongside this change) actually being
    // applied to the database yet - an RLS delete with no matching policy
    // silently matches zero rows and leaves an orphan.
    //
    // The Swipe payment itself already exists at this point regardless of
    // what happens next. If a step below fails we withhold the link but do
    // NOT cancel the Swipe payment - it just goes unpaid/expires unseen.
    // Acceptable for now; revisit if Swipe offers a cancel/void call and
    // this proves to happen often enough to matter.
    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const requestId = `pr_${crypto.randomUUID()}`;
    const { error: insertErr } = await admin.from("pro_upgrade_requests").insert({
      id: requestId,
      business_id: businessId,
      payment_method: "swipe",
      status: "pending",
      amount,
      swipe_reference: reference,
      swipe_payment_link: paymentLink,
    });
    if (insertErr) {
      console.error("Failed to record pro_upgrade_requests row:", insertErr);
      return new Response(JSON.stringify({ error: "Failed to set up payment tracking" }), { status: 500 });
    }

    if (!(await registerReferenceWithSeaFare(reference))) {
      const { error: rollbackErr } = await admin.from("pro_upgrade_requests").delete().eq("id", requestId);
      if (rollbackErr) console.error(`Rollback of ${requestId} failed:`, rollbackErr);
      return new Response(JSON.stringify({ error: "Failed to set up payment routing" }), { status: 502 });
    }

    return new Response(JSON.stringify({ paymentLink, reference }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error(e);
    return new Response(JSON.stringify({ error: "Internal error" }), { status: 500 });
  }
});
