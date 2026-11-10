// Live support: the super admin sends an archived bank slip back to the store
// (or customer) who asked for it in a ticket. Body: { ticket_id }.
// The ticket's order/booking must belong to the person who opened the ticket
// (their store's order, or their own order as a customer). The slip is attached
// to a new support message exactly as archived; if it was encrypted, only the
// store's / customer's own app can open it, so support never sees it.
// Deploy with --no-verify-jwt (Firebase tokens are checked here).
import { createClient } from "npm:@supabase/supabase-js@2";
import { createRemoteJWKSet, jwtVerify } from "npm:jose@5.9.6";

const FIREBASE_PROJECT_ID = Deno.env.get("FIREBASE_PROJECT_ID") ?? "maldexpress";
const FIREBASE_JWKS = createRemoteJWKSet(new URL("https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com"));
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json", ...CORS } });

async function firebaseUid(h: string): Promise<string | null> {
  const token = h.replace(/^Bearer\s+/i, ""); if (!token) return null;
  try {
    const { payload } = await jwtVerify(token, FIREBASE_JWKS, { issuer: `https://securetoken.google.com/${FIREBASE_PROJECT_ID}`, audience: FIREBASE_PROJECT_ID });
    return payload.email_verified === true && typeof payload.sub === "string" ? payload.sub : null;
  } catch { return null; }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  const uid = await firebaseUid(req.headers.get("Authorization") ?? "");
  if (!uid) return json({ error: "Sign in again" }, 401);
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: adm } = await db.from("admins").select("user_id").eq("user_id", uid).maybeSingle();
  if (!adm) return json({ error: "Only Maldexpress support can send slips" }, 403);

  const { ticket_id } = await req.json().catch(() => ({}));
  const { data: t } = await db.from("support_tickets").select("*").eq("id", ticket_id ?? "").maybeSingle();
  if (!t) return json({ error: "Ticket not found" }, 404);
  const table = t.order_id ? "orders" : t.booking_id ? "rental_bookings" : null;
  const ref = t.order_id || t.booking_id;
  if (!table) return json({ error: "This ticket isn't linked to an order or booking" }, 400);
  const { data: row } = await db.from(table).select("*").eq("id", ref).maybeSingle();
  if (!row) return json({ error: "Order not found" }, 404);
  const { data: biz } = await db.from("businesses").select("owner_id").eq("id", row.business_id).maybeSingle();
  if (row.customer_id !== t.user_id && biz?.owner_id !== t.user_id) return json({ error: "That order doesn't belong to whoever opened the ticket" }, 403);

  let slip: Record<string, unknown> | null = null;
  if (row.slip_url || row.slip_enc) slip = { kind: table, ref, slip_url: row.slip_url, slip_enc: row.slip_enc, slip_iv: row.slip_iv, slip_keys: row.slip_keys };
  else if (row.slip_archive_path) {
    const { data: file, error } = await db.storage.from("slip-archive").download(row.slip_archive_path);
    if (error || !file) return json({ error: "The archived slip couldn't be read" }, 500);
    slip = JSON.parse(await file.text());
  }
  if (!slip) return json({ error: "There's no slip for this order" }, 404);
  const { error } = await db.from("support_messages").insert({
    id: "sm_" + crypto.randomUUID().replace(/-/g, "").slice(0, 14), ticket_id: t.id, sender_id: uid, from_admin: true,
    body: "Here is the bank transfer slip you asked for.", attachment: slip,
  });
  if (error) { console.error(error); return json({ error: "Couldn't add the slip to the ticket" }, 500); }
  await db.from("support_tickets").update({ status: "answered" }).eq("id", t.id);
  return json({ ok: true });
});
