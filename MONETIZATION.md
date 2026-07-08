# Monetization — Overhead Pro (DRAFT for review)

Status: **draft, not implemented.** Decisions marked ⚖️ need Hemal's sign-off.

## 1. Recommendation in one paragraph

Freemium with a single subscription group **"Overhead Pro"** (monthly + annual
with 7-day free trial) plus a **lifetime** non-consumable, built on StoreKit 2
with no server and no accounts — entitlements live in the App Store receipt,
matching the app's "no accounts, no tracking" privacy story. The free app stays
the complete magic trick (point at the sky, everything is labeled) so featuring
editors and eclipse-week first-runs never hit a wall; Pro sells the *power
tools* built on the moat — Transit Mastery, the time machine, and the companion
surfaces. Target: paywall live in **1.3 before the Aug 6–13 featuring window**.

## 2. Free vs Pro split

Principles:
- Accessibility features are never paywalled (core mission).
- Nothing that shipped free in 1.0–1.2 gets taken away (tiny install base, but
  App Review + goodwill both punish clawbacks).
- Medals stay earnable by everyone — progression must stay honest.
- The paywall sells the moat: cross-domain aircraft × celestial intelligence.

| Free (forever) | Overhead Pro |
|---|---|
| Live AR sky: aircraft, sun, moon, planets, stars, constellations, ISS, Milky Way | **Transit Mastery** (v1.3 features): transit predictions + alerts, capture countdown + Live Activity, quality grading, walk-to-intercept, share cards |
| Dark sky, night vision, hear/feel sky (a11y) | **Time scrub** beyond ±24 h (planetarium time machine — any date) |
| Calibration / tap-to-align | **Premium widgets + watch complications** (new ones; existing stay free) |
| Tiers, medals, sharing | **Sky Pro pack** (future): deeper star catalog + precession-exact mode, satellite passes beyond ISS, aurora alerts |
| Sky events calendar + reminders, ISS pass alerts | |
| Flight search, favorites, route arcs | |
| FR24 bring-your-own-key (user already pays FR24) | |

⚖️ Open call: whether basic time scrub (±24 h) stays free (recommended: yes —
it powers "when does the ISS come?" moments that drive habit).

## 3. Pricing (⚖️ confirm)

| Product | ID | Price (US tier) | Notes |
|---|---|---|---|
| Monthly | `pro_monthly` | $1.99 | anchor; most will pick annual |
| Annual | `pro_yearly` | $14.99 | **7-day free trial**; the recommended/default option |
| Lifetime | `pro_lifetime` | $39.99 | non-consumable; converts subscription-averse astronomy buyers (large segment — see Sky Guide/Stellarium reviews) |

- Family Sharing: **on** for all three (goodwill, negligible revenue loss).
- Use App Store automatic regional pricing; no launch discount (trial is the offer).
- Comparables: Sky Guide Plus $2.99/mo–$19.99/yr, Night Sky+ $5.99/mo,
  Flighty $47.99/yr. We undercut deliberately: young app, ratings > revenue in year 1.

## 4. ⚠️ Licensing prerequisite — flight data

The default feed is **airplanes.live, whose free API is non-commercial**. The
moment the app takes money this needs resolving — *before* 1.3 ships:

1. **Recommended:** email airplanes.live for written permission (common ask;
   the aircraft layer itself stays free, which strengthens the case) and/or
   set up their commercial/donation arrangement.
2. Fallback: keep every aircraft-touching feature free forever and sell only
   celestial features (weakens the moat story — transit tools touch aircraft).
3. Escape hatch: licensed feed (FR24 official API) for the app's own traffic —
   real per-call costs, changes unit economics; avoid unless forced.

## 5. Technical design (StoreKit 2, no server)

New file `Skylight AR/ProStore.swift`:

- `@MainActor @Observable final class ProStore` — same didSet/observable house
  style as `SkyEngine`.
- `Product.products(for:)` at init; `purchase()`; `AppStore.sync()` for Restore.
- Long-lived `Transaction.updates` listener task started at app launch;
  entitlement = any unrevoked transaction in `Transaction.currentEntitlements`
  for the three product IDs. No receipt server, no JWS validation service —
  StoreKit 2 on-device verification (`VerificationResult.verified`) only.
- `var isPro: Bool` published; snapshot mirrored to the **App Group**
  UserDefaults (`pro.entitled` + expiry) so SkylightWidgets, OverheadWatch and
  the Live Activity can gate without StoreKit calls.
- Grace period / billing retry: honor `Transaction.currentEntitlements`
  semantics (it already includes grace); no custom logic.
- Ask-to-buy (`.pending`) → show "waiting for approval" toast, resolve via the
  updates listener.

Testing: add `Overhead.storekit` configuration file to the project + a sandbox
test checklist (purchase, trial, cancel, refund via
`Transaction.beginRefundRequest`, restore on second device, family sharing).

## 6. Paywall UX

- **Native-simple:** `SubscriptionStoreView` (iOS 17+) with custom marketing
  header styled to the night theme — medal-quality hero (reuse the 3D medal /
  transit artwork), feature checklist, then the system store view. System view
  = pricing/terms/restore handled correctly for App Review by construction.
- Lifetime rendered as a quiet third option below the subscription pair.
- Required links: Privacy Policy + Terms (EULA). **Prerequisite:** host
  PRIVACY.md content on the landing page and add the URL to `AppInfo` —
  App Review rejects subscription paywalls without both links.
- Placement (contextual, never launch-blocking):
  - Tapping a Pro feature (transit alert toggle, deep time scrub, premium widget)
    → paywall sheet with that feature as the hero.
  - One quiet "Overhead Pro" row in Settings.
  - Post-medal-earn is reserved for the **rating** prompt — never both.
- Copy tone: same voice as the app ("The sky's power tools").

## 7. ASC setup (scriptable via existing asc.js tooling)

1. Create subscription group "Overhead Pro" + 2 subscriptions + 1 NC IAP,
   localized display names/descriptions.
2. Introductory offer: 7-day free trial on annual.
3. Upload the per-IAP review screenshot (paywall screen; screenshot-hook infra
   can capture `-shot paywall`).
4. Paid Applications agreement + tax/banking must be Active (check — app has
   been free so far).
5. Review notes: explain entitlement is StoreKit-only, no login.

## 8. Measurement

Paywall.shown / Paywall.converted(product) / Paywall.dismissed via the existing
TelemetryDeck client. **Prerequisite:** TelemetryDeck App ID still not pasted —
analytics are inert; activate before 1.3 or we fly blind on conversion.

## 9. Rollout plan

| When | What |
|---|---|
| now → Jul 10 | ⚖️ Sign off split + pricing; email airplanes.live; host privacy/terms URLs; paste TelemetryDeck IDs |
| Jul 10–17 | ASC products; `ProStore` + paywall behind a DEBUG flag; `.storekit` test config; App Group entitlement mirror |
| Jul 17–24 | Transit Mastery v1 (the Pro content) + gates; sandbox QA matrix; `-shot paywall` screenshot |
| ~Jul 24 | Submit **1.3** (buffer for review + one rejection before the eclipse window) |
| Aug 6–13 | Featuring/eclipse traffic hits a finished funnel: free wow → transit tools upsell |

## 10. App Review watch-list

- Paywall shows price, term, auto-renew language, Restore, Privacy + Terms links
  (SubscriptionStoreView covers most of this).
- No feature that was advertised in screenshots as free may sit behind the wall.
- Medals/referral rewards stay cosmetic and non-purchasable (incentivized-
  manipulation rule).
- Physical-goods rule N/A; external-purchase links: don't.
