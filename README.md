# Overhead — Sky Above the Horizon

Point your iPhone at the sky and see what's really there: live aircraft with
routes and photos, the sun, the moon at its true phase, the naked-eye planets,
1,600 stars with constellations, the ISS riding its orbit — all placed at their
exact positions in augmented reality.

## What it does

- **Live aircraft** within 80 nm, labeled with callsign, type, and destination —
  with render-time dead reckoning so planes appear where they *are*, not where
  they were five seconds ago. Tap one for the airframe's actual photo, its
  route, and live stats. Filed routes are reality-checked against observed
  approaches ("Landing now at SFO").
- **The celestial sky** — sun, topocentric moon, Mercury→Saturn, named bright
  stars, constellation lines, atmospheric refraction at the horizon.
- **Transit alerts** — the marquee trick: Overhead predicts when an aircraft
  will cross the moon or sun from your exact position, with a countdown and a
  gold shutter to capture the moment as a share card.
- **Favorites & Focus** — heart a flight, focus it from anywhere, follow it in
  the Dynamic Island and on the lock screen.
- **Spatial audio flyovers** — each nearby plane becomes a positioned engine
  hum (HRTF); point at the sound to find it. The sky, eyes-free.
- **Sky events** — solar eclipses with *local* obscuration computed for your
  coordinates (August 12, 2026 — be ready), meteor showers, full moons, with
  on-device Apple Intelligence narration.
- **Siri**: "What's flying over me?" · **Control Center / Action button**
  control · **StandBy moon clock** · **Apple Watch**: next ISS pass on your
  wrist · dark-sky low-power mode driven by the IMU alone.

## Platforms

| Target | What it is |
|---|---|
| `Skylight AR` (iOS app) | The full AR experience (display name **Overhead**) |
| `SkylightWidgets` | Live Activity, Control Center control, StandBy moon clock |
| `OverheadWatch` | Standalone watchOS app — next ISS pass + moon phase |
| `OverheadVision` | visionOS mixed-immersion sky (self-contained) |

## Data & credits

- Live ADS-B traffic: [airplanes.live](https://airplanes.live) (non-commercial feed)
- Routes: [adsbdb](https://www.adsbdb.com) · Airframe photos: [planespotters.net](https://www.planespotters.net)
- Orbits: [CelesTrak](https://celestrak.org) TLEs, propagated with [SatelliteKit](https://github.com/gavineadie/SatelliteKit)
- Ephemeris: [SwiftAA](https://github.com/onekiloparsec/SwiftAA) (VSOP87 / Meeus)
- Earth imagery (when used): NASA Blue Marble (public domain)

All computation is on-device. No accounts, no tracking, no server.
