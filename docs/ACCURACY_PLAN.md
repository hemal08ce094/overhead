# Skylight AR / "Overhead" — Accuracy Improvement Plan

> Drafted 2026-06-20. A prioritized roadmap for making virtual objects land more
> precisely on their real-world counterparts in the AR sky. Grounded in the
> current implementation (file:line references are to the state of `main` at the
> time of writing — verify before acting in a later session).

## Core insight: the math is already excellent — heading is the bottleneck

The positional math is genuinely rigorous:
- Full WGS84 ECEF→ENU topocentric transforms — `SkylightAR.swift:258–295`
- Saemundsson/Bennett atmospheric refraction — `SkylightAR.swift:300–304`
- Lunar-parallax geocentric→topocentric correction — `SkyLayer.swift:88–92`
- Proper sidereal (GMST/LST/hour-angle) star transforms — `SkylightAR.swift:332–346`
- Aircraft dead-reckoning / extrapolation — `SkylightAR.swift:920–940`

Those paths are sub-degree accurate. **But the entire virtual sky is rotated to
true north by one number derived from the compass (`CLHeading.trueHeading`),
whose accuracy is ±5–25° depending on device and magnetic environment.** A 0.05°
geometry error is invisible; a 10° heading error puts every plane a hand's-width
from where it really is.

**~90% of perceived inaccuracy is device pose, not math.** This plan is
prioritized ruthlessly around that.

---

## P0 — Heading & pose (the dominant error)

### 1. Fuse ARKit yaw with the compass (complementary / 1-D Kalman filter)
- **Today:** `alignNorth()` (`SkylightAR.swift:1741–1769`) is a proportional
  controller nudging `worldNode.eulerAngles.y` toward the compass each frame
  (gain 0.01–0.05, 1.5° deadband). ARKit yaw and the compass never actually fuse.
- **Why it works:** ARKit yaw is low-noise but drifts; the compass is noisy but
  has no long-term drift — complementary error profiles. Trust ARKit short-term
  rate, compass long-term absolute.
- **Gain:** removes both the ~5 s lag to correct a bias and SLAM drift.
- **Effort:** medium. **Biggest single win.**

### 2. Continuous, automatic celestial alignment (not a one-time manual lock)
- **Today:** `lockToSun()` / `lockToMoon()` exist as a manual calibration step.
- **Change:** Sun/Moon azimuth is known to ±0.01°, so whenever one is above ~3°
  and visible, *solve* the heading offset exactly — no magnetometer needed.
  Promote to a continuous, opportunistic correction ("Sun detected — auto-aligned
  ±0.3°"); extend to bright planets/stars. Effectively plate-solving; sub-degree
  heading in clear conditions.
- **Effort:** medium. **Fastest path to a dramatic visible improvement.**

### 3. One-tap "snap to this plane"
- ADS-B identity is certain, so a plane's true az/el is known. Manual pan-to-align
  already exists (`SkylightAR.swift:1881–1893`); add a one-tap "align to this
  aircraft" that solves the offset from the tapped glyph's screen position vs. its
  true bearing.
- **Effort:** low. **High trust — uses the objects users are already looking at.**

### 4. Harden the sweep calibration
- The weighted circular mean (`SkylightAR.swift:1839–1854`) silently bakes in a
  constant bias if the sweep happens in a magnetic anomaly.
- Add (a) a **per-bucket variance/consistency check** that rejects/warns on bad
  sweeps, and (b) **post-lock residual feedback** — after calibrating, if Sun/Moon
  is visible, show the measured residual ("locked, Sun is 2° off — tap to refine").
- **Effort:** low–medium.

---

## P1 — Aircraft data freshness & altitude

### 5. Extrapolate altitude, not just lat/lon
- Dead-reckoning (`SkylightAR.swift:920–940`) projects horizontal position but
  ignores vertical rate — a climbing/descending plane sits at its stale altitude.
  ADS-B carries `geom_rate` / `baro_rate`; integrate it. Visible mostly on
  approach/departure traffic near the horizon.

### 6. Per-source feed latency + prefer the fresh feed
- `feedLatencySec = 1.5` (`SkylightAR.swift:461`) is tuned for airplanes.live
  (1 Hz) but also applied to FR24 (8 s polling, `SkylightAR.swift:770`). Set
  latency per source and prefer airplanes.live when available; a fixed 1.5 s
  assumption on an 8 s-old fix is a large lever-arm error for fast movers.

### 7. Velocity-aware smoothing
- The α=0.5 position low-pass (`SkylightAR.swift:977`) adds ~33 ms lag on top of
  feed lag and fights the dead-reckoning. Predict-then-smooth (smooth the residual
  against the predicted track) instead of smoothing absolute position.

### 8. Barometric → geometric altitude
- Already prefers `alt_geom`; when only `alt_baro` exists, correct with local QNH
  from the nearest METAR. Modest gain, mostly near the horizon.

---

## P1 — Satellites

### 9. Auto-refresh the ISS TLE
- Fetched once per session (`SkylightAR.swift:1631`) and never refreshed; a
  week-old TLE drifts >1°. Refresh daily, cache with a timestamp, surface
  staleness. Cheap, and ISS passes are a flagship feature where error is very
  visible.

---

## P2 — Observer position, time, atmosphere (smaller, cheap wins)

- **Tighten location accuracy in AR:** bump from `kCLLocationAccuracyHundredMeters`
  (`SkylightAR.swift:588`) to `Best` while the AR view is active; matters for
  nearby/low aircraft.
- **Geoid + observer height:** apply EGM96 undulation to the WGS84 altitude and let
  users set a rooftop height. Small for distant objects.
- **Time sync:** device clock only, no NTP. A one-shot SNTP offset at launch
  protects ISS and dead-reckoning from clock drift.
- **Pressure/temperature refraction:** feed METAR pressure/temp into the refraction
  formula (`SkylightAR.swift:300`). Sub-0.1°, horizon-only.

---

## Cross-cutting: instrument first, so improvement is provable

You can't tune accuracy you can't measure. Before/alongside the above:

- **Accuracy debug HUD:** live heading source, compass accuracy, ARKit tracking
  state, current heading offset, per-object age, and the **measured residual vs.
  Sun/Moon**.
- **A single regression metric:** with Sun/Moon visible, log angular error between
  rendered and user-confirmed position → an error distribution to track across
  builds.
- **Record & replay:** capture sensor + feed streams in the field and replay
  offline, so heading-fusion changes are testable without standing outside.

---

## Suggested sequence

1. **Instrumentation** (HUD + residual metric) — makes everything after measurable.
2. **P0 #2 & #3** (celestial auto-align + tap-to-snap) — fastest visible jump.
3. **P0 #1** (ARKit/compass fusion) — the durable structural fix.
4. **P0 #4**, then **P1** (altitude extrapolation, per-source latency, TLE refresh).
5. **P2** polish.

The error budget says it plainly: nail heading and you've fixed most of what
users feel.

---

## Reference: key files

| Concern | File |
| --- | --- |
| Coordinate math, pose, calibration, dead-reckoning, render | `Skylight AR/SkylightAR.swift` |
| Data flow, aircraft model, calibration state machine, settings | `Skylight AR/SkyEngine.swift` |
| Celestial + satellite positions (SwiftAA / SatelliteKit) | `Skylight AR/SkyLayer.swift` |
| Flight feed (FR24) timestamps/polling | `Skylight AR/FR24Source.swift` |
| AR screen UI + calibration overlay | `Skylight AR/ARSkyScreen.swift` |
