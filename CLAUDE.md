# Project brief for Claude Code

## What this is
Maldexpress: a marketplace + delivery app for the Maldives. Three portals in one app — customer (public browsing), business (store management), delivery (job pickup). Currently a single self-contained file, `index.html`, with inline CSS and vanilla JS. No build tooling, no framework, no npm dependencies yet.

## Current architecture (as of this file's writing)
- **State**: one global `state` object, re-rendered on every change via a hand-rolled `render()` dispatcher keyed on `state.role` and `state.screen`.
- **Data layer**: `DB` object (`businesses`, `items`, `orders`, `delivery`) synced to Supabase Postgres tables via `loadDB()` / `saveDB(part)`. `saveDB` currently does a full-array `upsert` per call rather than single-row writes — fine at this scale, but revisit if it grows.
- **Auth**: Supabase email magic-link auth (`signInWithOtp`), shared across all three roles — one signed-in account can own a business, a delivery profile, and place customer orders. `state.authed / state.customerId / state.customerEmail` hold the session.
- **Styling**: glassmorphism theme (blurred translucent cards) over an ocean-gradient background, mobile-first, `--fs` CSS variable drives the user-adjustable font size.
- **Sheets/modals**: bottom-sheet popups (`openSheet(name)` / `sheetHTML()`) handle all forms — signup, checkout, settings, etc.

## Business rules to preserve
- Free tier: 30 days from `joinDate`, max 10 items. Pro tier (MVR 500 one-time): max 500 items, no expiry.
- Delivery fee is a **flat amount by zone**, not a percentage: Malé MVR 15, Hulhumalé Phase 1 MVR 20, Hulhumalé Phase 2 MVR 25. Chosen by the customer at checkout.
- Payment methods: bank transfer (customer uploads a slip → business approves) or cash to the delivery partner (rider marks cash collected → owes the business `total - deliveryFee` → business confirms settlement).
- Store account number/name are only shown to the customer/rider while payment is unconfirmed.

## Known follow-ups (not yet done)
1. **Order read access is public** (`orders for select using (true)` in the RLS policy). Any signed-in user can currently read all orders, not just their own. Needs scoping to: the order's own customer, the business that owns it, or the assigned rider.
2. **Split the single HTML file** into a real project structure (components/modules) once it grows further — it's still manageable as one file for now, but don't let it double again without restructuring.
3. **Slip uploads** are stored as base64 data URLs directly in the `orders.slip_url` column. Move to Supabase Storage once volume matters — cheaper and keeps table rows small.
4. **No business/delivery admin oversight** — e.g. no way to suspend a store, dispute a payment claim, or handle a customer complaint. Out of scope for MVP but worth flagging.
5. Payment for the Pro tier upgrade (`payForPro()`) is currently simulated client-side with no real payment gateway. Needs BML/real payment integration before launch.

## Conventions
- Keep everything mobile-first; this is meant to be used primarily on phones.
- Money is always Maldivian Rufiyaa (MVR); the `money()` helper formats it — don't hardcode currency strings elsewhere.
- Don't reintroduce `window.storage` or `localStorage`/`sessionStorage` for real data — Supabase is the single source of truth so the app works outside Claude's own preview environment.
