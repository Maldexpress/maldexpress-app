# Maldexpress

A local marketplace + delivery app for the Maldives. One app, three portals:

- **Customers** — browse every listed store and item with no sign-in required; sign in with email (magic link) only when placing an order.
- **Businesses** — register a store, list items (10 free for the first month, 500 on the MVR 500 Pro tier), manage orders, and approve payments.
- **Delivery partners** — pick up jobs, earn a flat per-delivery fee by zone (Malé MVR 15, Hulhumalé Phase 1 MVR 20, Hulhumalé Phase 2 MVR 25), and settle cash collected with the store.

Currently a single static file (`index.html`) — plain HTML/CSS/JS, no build step, no framework. See `CLAUDE.md` for the full architecture notes and open follow-ups if you're picking this up in Claude Code.

## Stack

- Frontend: vanilla HTML/CSS/JS (glassmorphism UI, mobile-first)
- Backend: [Supabase](https://supabase.com) (Postgres + Auth), free tier
- Hosting: static site on [Render](https://render.com)

## Setup

1. **Create a Supabase project** at supabase.com (free tier is enough to start).
2. **Run the schema.** Open the SQL Editor in your Supabase dashboard and run the SQL block found in a comment near the top of `index.html` (search for `SQL to run once`). It creates the `businesses`, `items`, `delivery_persons`, and `orders` tables plus row-level security policies.
3. **Enable email auth.** In Authentication → Providers, confirm Email is turned on (magic link sign-in works out of the box).
4. **Add your keys.** In `index.html`, find:
   ```js
   const SUPABASE_URL = "YOUR_SUPABASE_URL";
   const SUPABASE_ANON_KEY = "YOUR_SUPABASE_ANON_KEY";
   ```
   Replace both with the values from Supabase → Settings → API.
5. **Run it locally** — just open `index.html` in a browser, or serve the folder with any static server (e.g. `npx serve .`).
6. **Deploy** — push to GitHub, then create a new Static Site on Render pointing at this repo. No build command needed; publish directory is the repo root.

## Notes

- Until you fill in the Supabase keys, the app runs in an offline demo mode with seeded sample data and no sign-in requirement, so you can preview the UI immediately.
- Business and delivery accounts use the same Supabase Auth as customers — one email, one account, usable across all three roles.
