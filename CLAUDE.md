# Project brief for Claude Code

## What this is
Maldexpress: a marketplace + delivery app for the Maldives. Three portals in one app — customer (public browsing), business (store management), delivery (job pickup). Currently a single self-contained file, `index.html`, with inline CSS and vanilla JS. No build tooling, no framework, no npm dependencies yet.

## Current architecture (as of this file's writing)
- **State**: one global `state` object, re-rendered on every change via a hand-rolled `render()` dispatcher keyed on `state.role` and `state.screen`.
- **Data layer**: `DB` object (`businesses`, `items`, `orders`, `delivery`) synced to Supabase Postgres tables via `loadDB()` / `saveDB(part)`. `saveDB` currently does a full-array `upsert` per call rather than single-row writes — fine at this scale, but revisit if it grows.
- **Auth**: Supabase email magic-link auth (`signInWithOtp`), shared across all three roles — one signed-in account can own a business, a delivery profile, and place customer orders. `state.authed / state.customerId / state.customerEmail` hold the session.
- **Styling**: "Atoll" theme (replaced "Harbour signage", which replaced the original glassmorphism). The Maldives from a seaplane: a turquoise lagoon hero on Home (`.home-hero`, reef rings drawn with CSS gradients), white sandbar cards with soft shadows on a pale ground, deep-channel navy (`--channel`) for text and the floating pill nav, reef-coral pink (`--coral-pink`) for the order-moving action and prices. One rounded family, Gabarito, heavy for display. Popups slide up as bottom sheets. Colour tokens live in `:root`; the old names (`--glass`, `--coral`, `--ink`, …) are kept as aliases because inline styles in the script use them. Mobile-first, `--fs` CSS variable drives the user-adjustable font size (default 14px).
- **Delivery zone picker**: drawn as a ferry route (`zoneRouteHTML()` / `pickZone()`), stops in order Malé → Hulhumalé Phase 1 → Phase 2. A hidden input keeps the `#c_zone` / `#cao_zone` ids.
- **Sheets/modals**: bottom-sheet popups (`openSheet(name)` / `sheetHTML()`) handle all forms — signup, checkout, settings, etc.

## Business rules to preserve
- Free tier: 30 days from `joinDate`, max 10 items. Pro tier (MVR 500 one-time): max 500 items, no expiry.
- Delivery fee is a **flat amount by zone**, not a percentage: Malé MVR 15, Hulhumalé Phase 1 MVR 20, Hulhumalé Phase 2 MVR 25. Chosen by the customer at checkout.
- **Buy now orders are paid only by Swipe** (cash on delivery and bank transfer were removed for them). Flow: customer places order (`payment_method 'swipe'`, `payment_status 'awaiting_approval'`) → store approves (`awaiting_swipe`) or declines → customer pays on a Swipe link created on the **store's own Swipe account** (edge function `create-order-payment`) → Swipe calls `swipe-order-webhook?business=<id>` → `paid`. A Swipe order can't go to a rider until it's paid, and riders never collect cash for it; the store owes the rider the zone fee after delivery.
- **Fees on Swipe orders**: Maldexpress takes 5% of the order total; Swipe's 1% charge is split 1:1 between the store and Maldexpress. So per order the store owes Maldexpress `5% − 0.5% = 4.5%` (`platform_fee_due`) and keeps 94.5%. Swipe has no split-payment API, so fees are tracked per order and settled by an admin (Admin → Fees). Rates live in `SWIPE_FEES` (index.html) and the webhook — keep them in sync.
- A store must connect its Swipe merchant account (client ID, client secret, webhook signing secret) before it can take orders. Credentials live in `business_swipe_accounts`, which has RLS with no policies so only edge functions can read them.
- **Rentals and auction wins** can be paid by Swipe (if the store has connected it), bank transfer, or cash. Swipe: a rental is inserted as `awaiting_swipe`; an auction win is completed with `payment_method 'swipe'` and then `start_swipe_payment()` opens it for payment (the live `complete_auction_order` comes from `05_encryption.sql`, which isn't in this repo). Bank transfer: the customer uploads a slip whose amount and account number must match the order total and the store's account, and the store must approve it (`approve_order_payment`). Cash: the store marks it received (rentals), or confirms the rider handed it over (auction cash on delivery). Swipe fees apply to these orders too.
- Stores and customers can contact each other at any point (Call / WhatsApp / Viber buttons via `contactHTML()`) on the store's order detail, booking cards, and the customer's order detail.
- Store account number/name are only shown to the customer/rider while payment is unconfirmed.

## Known follow-ups (not yet done)
1. **Split the single HTML file** into a real project structure (components/modules) once it grows further — it's still manageable as one file for now, but don't let it double again without restructuring.
2. **Slip uploads** are stored as base64 data URLs directly in the `orders.slip_url` column. Move to Supabase Storage once volume matters — cheaper and keeps table rows small.
3. **No business/delivery admin oversight** — e.g. no way to suspend a store, dispute a payment claim, or handle a customer complaint. Out of scope for MVP but worth flagging.
4. Payment for the Pro tier upgrade (`payForPro()`) is currently simulated client-side with no real payment gateway. Needs BML/real payment integration before launch.

## Conventions
- Keep everything mobile-first; this is meant to be used primarily on phones.
- Money is always Maldivian Rufiyaa (MVR); the `money()` helper formats it — don't hardcode currency strings elsewhere.
- Don't reintroduce `window.storage` or `localStorage`/`sessionStorage` for real data — Supabase is the single source of truth so the app works outside Claude's own preview environment.
