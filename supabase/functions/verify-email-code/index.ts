// Checks the 6-digit code from send-email-code and, if it matches, marks
// the signed-in Firebase account as verified (public.verified_emails),
// which public.app_uid() accepts. Called with
// sb.functions.invoke('verify-email-code', { body: { code } }).
// Each code allows 5 wrong tries and expires after 10 minutes.
// Deploy with --no-verify-jwt: this function checks the Firebase token itself.

import { createClient } from "npm:@supabase/supabase-js@2";
import { createRemoteJWKSet, jwtVerify } from "npm:jose@5.9.6";

const FIREBASE_PROJECT_ID = Deno.env.get("FIREBASE_PROJECT_ID") ?? "maldexpress";
const JWKS = createRemoteJWKSet(new URL("https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com"));
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...CORS } });

async function firebaseUser(authHeader: string): Promise<{ uid: string; email: string } | null> {
  const token = authHeader.replace(/^Bearer\s+/i, "");
  if (!token) return null;
  try {
    const { payload } = await jwtVerify(token, JWKS, {
      issuer: `https://securetoken.google.com/${FIREBASE_PROJECT_ID}`,
      audience: FIREBASE_PROJECT_ID,
    });
    if (typeof payload.sub !== "string" || !payload.sub || typeof payload.email !== "string") return null;
    return { uid: payload.sub, email: payload.email };
  } catch {
    return null;
  }
}
async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  try {
    const user = await firebaseUser(req.headers.get("Authorization") ?? "");
    if (!user) return json({ error: "Not signed in" }, 401);
    const { code } = await req.json().catch(() => ({}));
    const clean = String(code ?? "").replace(/\D/g, "");
    if (clean.length !== 6) return json({ error: "Enter the 6-digit code from the email" }, 400);

    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: row } = await admin.from("email_codes").select("*").eq("uid", user.uid).maybeSingle();
    if (!row) return json({ error: "No code found. Tap Resend code" }, 404);
    if (new Date(row.expires_at).getTime() < Date.now()) return json({ error: "That code has expired. Tap Resend code" }, 410);
    if (row.attempts >= 5) return json({ error: "Too many wrong tries. Tap Resend code for a new one" }, 429);

    if ((await sha256Hex(`${user.uid}:${clean}`)) !== row.code_hash) {
      await admin.from("email_codes").update({ attempts: row.attempts + 1 }).eq("uid", user.uid);
      const left = 4 - row.attempts;
      return json({ error: left > 0 ? `That code isn't right. ${left} ${left === 1 ? "try" : "tries"} left` : "Too many wrong tries. Tap Resend code for a new one" }, 400);
    }

    const { error: vErr } = await admin.from("verified_emails").upsert({ uid: user.uid, email: user.email, verified_at: new Date().toISOString() });
    if (vErr) {
      console.error("Marking verified failed:", vErr);
      return json({ error: "Couldn't confirm your email. Try again" }, 500);
    }
    await admin.from("email_codes").delete().eq("uid", user.uid);
    return json({ verified: true });
  } catch (e) {
    console.error(e);
    return json({ error: "Internal error" }, 500);
  }
});
