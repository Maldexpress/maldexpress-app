// Moves bank slips out of the database 3 hours after the store confirmed them.
// Run by pg_cron every 15 minutes (migration 2026-11-12_slip_expiry_support.sql).
// Each slip is saved, exactly as stored (still encrypted for the customer and
// the store if it was), to the private `slip-archive` bucket as
// <table>/<id>.json, then cleared from the row. Safe to call any time: it only
// touches slips whose 3 hours are up, so there's nothing to protect it with.
// Deploy with --no-verify-jwt.
import { createClient } from "npm:@supabase/supabase-js@2";

const HOLD_HOURS = 3;
const BATCH = 50;

Deno.serve(async () => {
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const cutoff = new Date(Date.now() - HOLD_HOURS * 3600_000).toISOString();
  const out: Record<string, number> = {};
  for (const table of ["orders", "rental_bookings"]) {
    const { data, error } = await db.from(table)
      .select("id, slip_url, slip_enc, slip_iv, slip_keys, slip_confirmed_at")
      .lt("slip_confirmed_at", cutoff).is("slip_archived_at", null)
      .or("slip_url.not.is.null,slip_enc.not.is.null").limit(BATCH);
    if (error) { console.error(table, error); continue; }
    let moved = 0;
    for (const r of data ?? []) {
      const path = `${table}/${r.id}.json`;
      const body = JSON.stringify({ kind: table, ref: r.id, confirmed_at: r.slip_confirmed_at,
        slip_url: r.slip_url, slip_enc: r.slip_enc, slip_iv: r.slip_iv, slip_keys: r.slip_keys });
      const up = await db.storage.from("slip-archive").upload(path, new Blob([body], { type: "application/json" }), { upsert: true, contentType: "application/json" });
      if (up.error) { console.error(path, up.error); continue; }
      const { error: e2 } = await db.from(table).update({
        slip_url: null, slip_enc: null, slip_iv: null, slip_keys: null,
        slip_archived_at: new Date().toISOString(), slip_archive_path: path,
      }).eq("id", r.id);
      if (e2) console.error(path, e2); else moved++;
    }
    out[table] = moved;
  }
  return new Response(JSON.stringify({ ok: true, moved: out }), { headers: { "Content-Type": "application/json" } });
});
