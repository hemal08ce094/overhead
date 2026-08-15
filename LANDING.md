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
4. **August 12 / Catch a transit** — full-height animated band, NOT a static banner:
   an eclipsed sun (black moon disc over a bright corona with two slowly
   counter-rotating streamer layers) and, every ~9 s, a small airliner silhouette
   with twin contrails crossing the disc on a −14° lane — an original drawn
   recreation of the famous eclipse-transit videos. Heading "Catch a transit", copy:
   "August 12 — a total solar eclipse and the Perseids peak, the same week. Overhead
   warns you when a plane is about to cross the face of the Sun, counts you down,
   and hands you the shutter." Reduced motion: plane parked mid-disc, no rotation.
   The working implementation (styles, keyframes, SVG silhouette) is in the repo at
   `docs/landing-intro-reference.html` — lift it as-is. Do NOT embed or re-host
   clips of third-party transit videos; if real footage is ever wanted here, it
   must be licensed from its creator or shown via the platform's official embed
   player. (Keep this section easy to swap for future sky events.)
5. **Privacy strip** — short: "No account. No ads. No tracking. Your location goes
   only to public flight services to fetch the sky around you." Link to /privacy.
6. **Footer** — App Store badge again, /privacy link, contact mailto TODO(email),
   "Made for people who look up."

**Entrance choreography ("the label moment")** — the hero must not simply appear; it
plays a one-time ~2.5s sequence that demonstrates the product before the headline
lands. A working single-file reference with all timings/easings is in the repo at
`docs/landing-intro-reference.html` — match it exactly:

1. **0–600ms** — page paints already near-black (no white flash). ~140 tiny stars
   fade in with randomized 0–500ms stagger: opacity 0→(0.25–0.8), scale 0.9→1,
   450ms, `cubic-bezier(0.23, 1, 0.32, 1)`. After settling, each star twinkles
   subtly (ease-in-out, 4–9s periods, desynchronized).
2. **500ms→** — a single glowing dot begins a slow linear drift across the upper
   sky (~0.5vw/s) and keeps drifting forever — planes don't stop.
3. **1400–1500ms** — a 1px gold leader line draws from the dot (250ms,
   stroke-dashoffset), then a glass label pops on at its end: scale 0.95→1 +
   opacity, 200ms, transform-origin at the line's end. Label: "**QTR649 → Doha**"
   with sub-line "38,000 ft · overhead now". Line + label ride along with the dot.
4. **1900–2500ms** — headline words rise in one by one (translateY 10px→0 +
   opacity, 350ms each, 60ms stagger), then subhead + CTA fade up together (400ms).

Rules, non-negotiable:
- Plays **once** (localStorage flag). Return visits: single 300ms fade, label
  already pinned. Never a separate route/splash page — it's the hero itself.
- **Any** input skips instantly to the settled state (pointerdown, keydown, wheel,
  touchmove). Use Web Animations API so `finish()` lands everything at once.
- `prefers-reduced-motion`: opacity fades only, no drift, whole sequence ≤400ms.
- Animate only transform/opacity/clip-path/stroke-dashoffset. No layout properties.

**Live flight upgrade** — when possible, the label shows a REAL flight near the
visitor instead of the scripted QTR649: IP → approx location via
`get.geojs.io/v1/ip/geo.json` (CORS-open), then a Supabase edge function
`GET /overhead?lat=&lon=` (spec below), then destination via
`api.adsbdb.com/v0/callsign/{callsign}` (CORS-open; patch the "→ City" in
whenever it answers, even after the label popped). Hard budget: if location+flight
haven't answered ~800ms in, play the scripted beat — the choreography is never
delayed by the network.

Behavior requirements:
- Supabase edge function `GET /overhead?lat=X&lon=Y` for the live label: server-side
  fetch `https://api.adsb.lol/v2/point/{lat}/{lon}/40` (falls back to
  `https://api.airplanes.live/v2/point/…` if adsb.lol errors), pick the nearest
  airborne aircraft with a callsign, respond
  `{callsign, alt_ft, lat, lon}` (or `{}` if the sky is empty) with
  `Access-Control-Allow-Origin: *`, cache 15s per rounded coordinate. The free
  ADS-B feeds send no CORS headers, which is why the proxy must exist. Do not log
  coordinates.
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

- `docs/landing-intro-reference.html` — the entrance choreography reference
  (open in a browser; `?slow=1` runs it at quarter speed, "replay" bottom-right).

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
