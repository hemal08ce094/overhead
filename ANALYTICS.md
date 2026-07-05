# Analytics (TelemetryDeck) — setup & compliance

Privacy-preserving, aggregate product analytics. **No SDK, no advertising ID, no
personal data** — only an anonymous per-install SHA-256 hash. Implemented in
`Skylight AR/Analytics.swift` via TelemetryDeck's ingest API over URLSession.

## Finish the setup (2 values)
1. Create a free app at https://telemetrydeck.com (Sign in with Apple / email).
2. Copy your **App ID** and **namespace** from the dashboard.
3. Paste them into the two constants at the top of `Analytics.swift`:
   ```swift
   private static let appID     = "…"   // your App ID
   private static let namespace = "…"   // your org namespace
   ```
Until both are filled, the code sends **nothing** (safe to ship as-is).

## Events instrumented
| Signal | Where | Tells you |
|---|---|---|
| `App.launched` | app init | sessions / active devices / retention |
| `Mode.selected` `{mode: ar\|dark}` | mode chips | AR vs Dark-sky preference |
| `Setting.toggled` `{name, on}` | every `SettingRow` | which layers/settings people keep on |
| `Align.used` `{type: quick\|guided}` | begin(Quick)Align | how often calibration is needed |
| `Plane.identified` | `recordSpot` | core engagement |
| `Favorite.added` | `toggleFavorite` | following flights |
| `Focus.started` | `focusedCallsign` | live find-it usage |
| `Transit.shutterTapped` | shutter button | the hero feature's real usage |
| `Search.opened` / `Events.opened` / `Profile.opened` | nav buttons | navigation reach |
| `Medal.earned` `{id}` | `MedalStore.evaluate` | gamification pull |

Every signal also carries: app version, build, OS version, locale (no identity).

## Opt-out
`Analytics.setOptedOut(true)` disables sending. Wire a Settings toggle to it
(recommended: a "Share anonymous usage" switch, default on).

## App Store privacy label — UPDATE BEFORE RESUBMIT
Currently the listing says nothing-but-location is collected. Add:
- **Data type:** Usage Data → *Product Interaction*.
- **Linked to the user?** **No.**
- **Used for tracking?** **No.**
- **Purpose:** Analytics / App Functionality.
Location answers stay unchanged. "No account / No ads / No tracking" remain true.

## Privacy policy — add one sentence
> Overhead uses TelemetryDeck to collect anonymous, aggregate usage statistics
> (for example, which features are opened) to help us improve the app. This data
> is not linked to your identity, contains no personal information, and is never
> used to track you across apps or the web. You can turn it off in Settings.
