# Overhead — landing page brief for Lovable

Paste the **Lovable prompt** section into a new Lovable project (or the existing one that
hosts `/privacy`, so the domain and Supabase backend are shared). Everything below it is
the exact copy and behavior the page needs — no placeholders to fill except the two
marked `TODO`.

---

## Lovable prompt (paste this)

Build a single-page marketing site for **Overhead**, an iOS augmented-reality sky app.
Dark, premium, astronomy feel: near-black indigo background (#02030B), a subtle animated
starfield, thin constellation lines as decorative accents, white/soft-gray text, one
warm gold accent (#F0B24A). Rounded glass cards. Mobile-first. No cookie banners, no
signup forms, no chat widgets.

Sections in order:

1. **Hero** — big headline "Everything above you, labeled." Subhead: "Point your phone
   at any light in the sky. Overhead tells you whether it's a planet, a satellite, or
   flight QTR649 to Doha — placed exactly where it really is." Primary CTA: black
   "Download on the App Store" badge linking to
   https://apps.apple.com/app/id6782262384 . Beside the copy, an iPhone mockup frame
   showing the app's dark-sky screenshot (I'll upload screenshots as assets).
2. **The party trick** — three feature cards:
   - "Meteor or A380?" — Every 'was that one?!' gets an answer. Planes, planets,
     stars and the ISS share one sky — tap any light and know.
   - "Catch a transit" — Overhead warns you when a plane is about to cross the face
     of the Moon or Sun, counts you down, and hands you the shutter.
   - "A sky journal in real metal" — Every flight you spot builds your tier. Medals
     are struck, engraved and spun in 3D — earned, never bought.
3. **Dark sky mode** — full-width screenshot band: "No camera needed. A star map that
   follows your hands, tuned for night vision."
4. **August 12** — event banner: "Total solar eclipse + the Perseids peak, the same
   week. Overhead counts you down to both — from your exact spot." (Keep this section
   easy to swap for future sky events.)
5. **Privacy strip** — short: "No account. No ads. No tracking. Your location goes
   only to public flight services to fetch the sky around you." Link to /privacy.
6. **Footer** — App Store badge again, /privacy link, contact mailto TODO(email),
   "Made for people who look up."

Behavior requirements:
- The page must read a `?sky=CODE` URL parameter (e.g. `?sky=SKY-7Q2M`). When present:
  store one row {code, timestamp} in a Supabase table `sky_referrals`, show a small
  toast-style line under the hero CTA — "⭐ A friend showed you this sky. Their code
  SKY-7Q2M is remembered — enter it when Overhead first opens." — and keep the code in
  localStorage so the toast survives reloads.
- Add a tiny read-only endpoint (Supabase RPC or edge function) `GET /count?code=X`
  returning {code, clicks} so the iOS app can later display a sharer's click count.
  No personal data anywhere: codes are random, no IPs stored, no analytics scripts.
- Smart App Banner meta tag: `<meta name="apple-itunes-app" content="app-id=6782262384">`.
- OpenGraph/Twitter cards: title "Overhead — everything above you, labeled",
  description = hero subhead, og:image = the dark-sky screenshot.

## Assets to upload to Lovable

From the repo `Screenshots/` folder (already App Store quality):
- `iphone-6.9/` dark-sky + plane-card shots for hero and bands
- `watch-ultra-v2/` one watch shot for a small "on your wrist" card (optional)

## TODO before publish
- Contact email in footer (suggest the feedback address already in the app).
- Rename the Lovable subdomain (current `immaculate-display-copy` will appear on share
  cards) — or attach a custom domain. Short and confident: e.g. `overhead-sky`.

## How this connects to the app (context, not for Lovable)
- The iOS app will generate a per-install **sky code** (e.g. `SKY-7Q2M`), bake it into
  share cards and share URLs (`https://<domain>/?sky=SKY-7Q2M`).
- Onboarding gains one optional screen: "Who showed you the sky?" → enter a code →
  the app POSTs a redemption to the same Supabase project (`sky_redemptions`).
- Redemption thresholds unlock **cosmetic** recognition only (Ambassador/Constellation
  badge, special medal finish) — never functionality, to stay clear of App Review's
  incentivized-install rules.
