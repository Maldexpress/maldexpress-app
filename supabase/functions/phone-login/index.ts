// Sign in / reset password with a mobile number, without exposing who owns
// which number. The browser used to look the email up itself (the public
// resolve_login_email RPC), so anyone could collect emails from phone numbers.
// Now:
//   { action:'signin', phone, password } -> { email } only if the password is
//       correct for that account (checked with Firebase); otherwise a generic
//       "incorrect mobile/email or password".
//   { action:'reset', phone } -> sends the Firebase password-reset email to the
//       account's address and always answers the same way.
// Deploy with --no-verify-jwt (callers aren't signed in yet).
import { createClient } from "npm:@supabase/supabase-js@2";

// Firebase Web API key (public, the same one the app uses).
const FIREBASE_API_KEY = Deno.env.get("FIREBASE_API_KEY") ?? "AIzaSyDH1UV0oqOW2ftAd-KqoJF2yuKeR0H6QF8";
const APP_URL = "https://maldexpress.github.io/maldexpress-app/";
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json", ...CORS } });
const fb = (ep: string, body: unknown) => fetch(`https://identitytoolkit.googleapis.com/v1/accounts:${ep}?key=${FIREBASE_API_KEY}`, {
  method: "POST",
  headers: { "Content-Type": "application/json", "Referer": "https://maldexpress.github.io/" },
  body: JSON.stringify(body),
});
const BAD = "Incorrect mobile/email or password. New here? Sign up below";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  let body: { action?: string; phone?: string; password?: string };
  try { body = await req.json(); } catch { return json({ error: "Bad request" }, 400); }
  const phone = String(body.phone ?? "").replace(/\s+/g, "");
  if (!/^[0-9+]{7,15}$/.test(phone)) return json({ error: "Enter a valid mobile number" }, 400);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: prof } = await admin.from("user_profiles").select("email").eq("phone", phone).limit(1).maybeSingle();
  const email = prof?.email as string | undefined;

  if (body.action === "reset") {
    if (email) {
      const r = await fb("sendOobCode", { requestType: "PASSWORD_RESET", email, continueUrl: APP_URL });
      if (!r.ok) await fb("sendOobCode", { requestType: "PASSWORD_RESET", email });
    }
    return json({ ok: true, message: "If that number has an account, we've sent a password reset email to its address" });
  }

  if (body.action === "signin") {
    const password = String(body.password ?? "");
    if (!email || !password) return json({ error: BAD }, 401);
    const r = await fb("signInWithPassword", { email, password, returnSecureToken: false });
    if (r.ok) return json({ email });
    const err = await r.json().catch(() => ({}));
    const code = String(err?.error?.message ?? "");
    if (code.startsWith("TOO_MANY_ATTEMPTS")) return json({ error: "Too many tries. Wait a few minutes and try again" }, 429);
    if (code.startsWith("USER_DISABLED")) return json({ error: "This account has been turned off" }, 403);
    return json({ error: BAD }, 401);
  }
  return json({ error: "Unknown action" }, 400);
});
