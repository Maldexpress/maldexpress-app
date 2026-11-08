// Emails a 6-digit verification code to the signed-in Firebase user.
// Called from the app with sb.functions.invoke('send-email-code').
//
// Firebase itself only verifies email addresses with a link, so Maldexpress
// sends its own code. The code is stored hashed in public.email_codes
// (10-minute expiry) and checked by verify-email-code.
//
// Limits: one email per 60 seconds, at most 5 per hour per account.
//
// Requires these secrets (Supabase Dashboard -> Edge Functions -> Secrets):
//   BREVO_API_KEY       - Brevo (brevo.com) API key, SMTP & API -> API keys
//   BREVO_SENDER_EMAIL  - a sender address verified in Brevo
// Deploy with --no-verify-jwt: this function checks the Firebase token itself.

import { createClient } from "npm:@supabase/supabase-js@2";
import { createRemoteJWKSet, jwtVerify } from "npm:jose@5.9.6";

const FIREBASE_PROJECT_ID = Deno.env.get("FIREBASE_PROJECT_ID") ?? "maldexpress";
const BREVO_API_KEY = Deno.env.get("BREVO_API_KEY") ?? "";
const BREVO_SENDER_EMAIL = Deno.env.get("BREVO_SENDER_EMAIL") ?? "";
const JWKS = createRemoteJWKSet(new URL("https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com"));

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...CORS } });

async function firebaseUser(authHeader: string): Promise<{ uid: string; email: string; verified: boolean } | null> {
  const token = authHeader.replace(/^Bearer\s+/i, "");
  if (!token) return null;
  try {
    const { payload } = await jwtVerify(token, JWKS, {
      issuer: `https://securetoken.google.com/${FIREBASE_PROJECT_ID}`,
      audience: FIREBASE_PROJECT_ID,
    });
    if (typeof payload.sub !== "string" || !payload.sub || typeof payload.email !== "string") return null;
    return { uid: payload.sub, email: payload.email, verified: payload.email_verified === true };
  } catch {
    return null;
  }
}

async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function sixDigitCode(): string {
  const n = crypto.getRandomValues(new Uint32Array(1))[0] % 1_000_000;
  return String(n).padStart(6, "0");
}

function emailHtml(code: string): string {
  return `<div style="background:#050A1C;padding:32px 16px;font-family:Arial,Helvetica,sans-serif;">
  <div style="max-width:460px;margin:0 auto;background:#0F1E44;border:1px solid #24345E;border-radius:20px;padding:28px 24px;color:#EAF4FF;">
    <p style="margin:0 0 4px;font-size:13px;font-weight:700;letter-spacing:2px;color:#3EF2E0;">MALDEXPRESS</p>
    <h2 style="margin:0 0 12px;font-size:22px;color:#FFFFFF;">Your verification code</h2>
    <p style="margin:0 0 16px;font-size:15px;line-height:1.5;color:#C9D6EA;">Enter this code in the Maldexpress app to confirm your email:</p>
    <p style="margin:0 0 16px;padding:16px 0;text-align:center;font-size:36px;font-weight:700;letter-spacing:12px;font-family:'Courier New',monospace;color:#3EF2E0;background:#081431;border-radius:14px;">${code}</p>
    <p style="margin:0;font-size:13px;line-height:1.5;color:#8C9AB5;">The code expires in 10 minutes. If you didn't sign up for Maldexpress, you can ignore this email.</p>
  </div>
</div>`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  if (!BREVO_API_KEY || !BREVO_SENDER_EMAIL) {
    return json({ error: "Email sending isn't set up yet (BREVO_API_KEY / BREVO_SENDER_EMAIL)" }, 500);
  }
  try {
    const user = await firebaseUser(req.headers.get("Authorization") ?? "");
    if (!user) return json({ error: "Not signed in" }, 401);

    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    if (user.verified) return json({ verified: true });
    const { data: done } = await admin.from("verified_emails").select("uid").eq("uid", user.uid).maybeSingle();
    if (done) return json({ verified: true });

    const now = Date.now();
    const { data: prev } = await admin.from("email_codes").select("*").eq("uid", user.uid).maybeSingle();
    let sendsInWindow = 1;
    let windowStart = new Date(now).toISOString();
    if (prev) {
      const sinceLast = now - new Date(prev.last_sent_at).getTime();
      if (sinceLast < 60_000) {
        return json({ error: "Please wait a minute before asking for another code", retryInSeconds: Math.ceil((60_000 - sinceLast) / 1000) }, 429);
      }
      const windowAge = now - new Date(prev.window_started_at).getTime();
      if (windowAge < 3_600_000) {
        if (prev.sends_in_window >= 5) return json({ error: "Too many codes requested. Try again in an hour" }, 429);
        sendsInWindow = prev.sends_in_window + 1;
        windowStart = prev.window_started_at;
      }
    }

    const code = sixDigitCode();
    const { error: saveErr } = await admin.from("email_codes").upsert({
      uid: user.uid,
      email: user.email,
      code_hash: await sha256Hex(`${user.uid}:${code}`),
      expires_at: new Date(now + 10 * 60_000).toISOString(),
      attempts: 0,
      last_sent_at: new Date(now).toISOString(),
      sends_in_window: sendsInWindow,
      window_started_at: windowStart,
    });
    if (saveErr) {
      console.error("Saving code failed:", saveErr);
      return json({ error: "Couldn't create a code. Try again" }, 500);
    }

    const res = await fetch("https://api.brevo.com/v3/smtp/email", {
      method: "POST",
      headers: { "api-key": BREVO_API_KEY, "Content-Type": "application/json", accept: "application/json" },
      body: JSON.stringify({
        sender: { name: "Maldexpress", email: BREVO_SENDER_EMAIL },
        to: [{ email: user.email }],
        subject: `Your Maldexpress code: ${code}`,
        htmlContent: emailHtml(code),
        textContent: `Your Maldexpress verification code is ${code}. It expires in 10 minutes.`,
      }),
    });
    if (!res.ok) {
      console.error("Brevo send failed:", res.status, await res.text());
      return json({ error: "Couldn't send the email. Try again in a moment" }, 502);
    }
    return json({ sent: true });
  } catch (e) {
    console.error(e);
    return json({ error: "Internal error" }, 500);
  }
});
