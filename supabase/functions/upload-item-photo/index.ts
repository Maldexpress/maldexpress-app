// Saves a store's product photo to the public `product-images` bucket.
// Called from the app with the photo as the raw request body:
//   sb.functions.invoke('upload-item-photo', { body: file, headers: { 'x-file-ext': 'jpg' } })
//
// Why a function: accounts live in Firebase, and Firebase ID tokens carry no
// Supabase `role` claim. The database (PostgREST) accepts them as `anon` and
// RLS checks public.app_uid(), but Storage refuses them, so direct uploads
// from the browser fail. This function verifies the Firebase token itself
// (same rule as app_uid(): this project, verified email) and writes the file
// with the service role into the caller's own folder: <firebase uid>/<random>.<ext>.
// Deploy with --no-verify-jwt (the gateway doesn't check Firebase tokens).
import { createClient } from "npm:@supabase/supabase-js@2";
import { createRemoteJWKSet, jwtVerify } from "npm:jose@5.9.6";

const FIREBASE_PROJECT_ID = Deno.env.get("FIREBASE_PROJECT_ID") ?? "maldexpress";
const FIREBASE_JWKS = createRemoteJWKSet(
  new URL("https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com"),
);
const MAX_BYTES = 8 * 1024 * 1024;
const TYPES: Record<string, string> = { jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png", webp: "image/webp", gif: "image/gif", heic: "image/heic" };
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-file-ext",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status: number) => new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json", ...CORS } });

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
  } catch { return null; }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const uid = await firebaseUid(req.headers.get("Authorization") ?? "");
  if (!uid) return json({ error: "Sign in with a verified email to upload photos" }, 401);

  const ext = (req.headers.get("x-file-ext") ?? "jpg").toLowerCase().replace(/[^a-z]/g, "");
  const contentType = TYPES[ext];
  if (!contentType) return json({ error: "Use a JPG, PNG, WebP, GIF or HEIC photo" }, 415);
  const bytes = new Uint8Array(await req.arrayBuffer());
  if (!bytes.length) return json({ error: "The photo is empty" }, 400);
  if (bytes.length > MAX_BYTES) return json({ error: "The photo is bigger than 8 MB" }, 413);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const path = `${uid}/img_${crypto.randomUUID().replace(/-/g, "").slice(0, 12)}.${ext}`;
  const { error } = await admin.storage.from("product-images").upload(path, bytes, { contentType, cacheControl: "3600", upsert: false });
  if (error) { console.error(error); return json({ error: "Upload failed" }, 500); }
  const { data } = admin.storage.from("product-images").getPublicUrl(path);
  return json({ url: data.publicUrl, path }, 200);
});
