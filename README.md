# Maldexpress

A local marketplace + delivery app for the Maldives. One app, three portals:

- **Customers** — browse every listed store and item with no sign-in required; sign in with email (magic link) only when placing an order.
- **Businesses** — register a store, list items (10 free for the first month, 500 on the MVR 500 Pro tier), manage orders, and approve payments.
- **Delivery partners** — pick up jobs, earn a flat per-delivery fee by zone (Malé MVR 15, Hulhumalé Phase 1 MVR 20, Hulhumalé Phase 2 MVR 25), and settle cash collected with the store.

Currently a single static file (`index.html`) — plain HTML/CSS/JS, no build step, no framework. See `CLAUDE.md` for the full architecture notes and open follow-ups if you're picking this up in Claude Code.

## Stack

- Frontend: vanilla HTML/CSS/JS (mobile-first)
- Backend: [Supabase](https://supabase.com) (Postgres + Auth), free tier
- Hosting: static site on [Render](https://render.com)

## Setup

1. **Create a Supabase project** at supabase.com (free tier is enough to start).
2. **Run the schema.** Open the SQL Editor in your Supabase dashboard and run the SQL block found in a comment near the top of `index.html` (search for `SQL to run once`). It creates the `businesses`, `items`, `delivery_persons`, and `orders` tables plus row-level security policies.
3. **Set up sign-in.** In Firebase, enable Email/Password sign-in. In Supabase, add Firebase (project ID `maldexpress`) under Authentication → Third-party auth, then run `supabase/migrations/2026-11-08_firebase_auth.sql`.
4. **Add your keys.** In `index.html`, find:
   ```js
   const SUPABASE_URL = "YOUR_SUPABASE_URL";
   const SUPABASE_ANON_KEY = "YOUR_SUPABASE_ANON_KEY";
   ```
   Replace both with the values from Supabase → Settings → API.
5. **Run it locally** — just open `index.html` in a browser, or serve the folder with any static server (e.g. `npx serve .`).
6. **Deploy** — push to GitHub, then create a new Static Site on Render pointing at this repo. No build command needed; publish directory is the repo root.

## Swipe payments for orders

Buy now orders are paid through each store's own Swipe merchant account after the store approves the order. To turn it on:

1. Run the **SWIPE ORDER PAYMENTS** block at the end of the SQL comment in `index.html` (Supabase → SQL Editor).
2. Deploy the two edge functions:
   ```
   supabase functions deploy create-order-payment
   supabase functions deploy swipe-order-webhook --no-verify-jwt
   ```
3. Make sure the `SWIPE_TOKEN_URL` and `SWIPE_API_BASE_URL` secrets are set (Supabase → Edge Functions → Secrets). The Pro-upgrade function already uses them.
4. Each store opens its dashboard → **Connect Swipe**, enters its Swipe client ID, client secret and webhook signing secret, and pastes the webhook URL shown there into its Swipe Merchant Portal.

Maldexpress takes 5% of each order and Swipe's 1% charge is split equally, so a store owes 4.5% per order. An admin records fee payments under Admin → Fees.

## Notes

- Until you fill in the Supabase keys, the app runs in an offline demo mode with seeded sample data and no sign-in requirement, so you can preview the UI immediately.
- Accounts use **Firebase Auth** (project `maldexpress`, email + password with email verification); Supabase stores the data and checks the Firebase login on every request (Supabase → Authentication → Third-party auth → Firebase). One account works across all three roles. Add your site's domain under Firebase → Authentication → Settings → Authorized domains.
