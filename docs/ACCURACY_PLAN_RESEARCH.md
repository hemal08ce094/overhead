# Skylight AR / "Overhead" — Accuracy Plan (Research-Backed Draft)

> Drafted 2026-06-20. Companion to `ACCURACY_PLAN.md` (the code-grounded draft).
> This version is built from external research into how production AR-astronomy and
> flight-tracking apps achieve accuracy, with quantified budgets and citations.
> Adversarially fact-checked (21 claims confirmed / 4 refuted across 24 sources).

## Headline: the research confirms — and hardens — "fix heading first"

The code-grounded draft argued heading/pose is the dominant error. The literature
quantifies *why no amount of compass tuning will fix it*, which changes the strategy
from "tune the compass" to "stop relying on the compass for the final degree."

- **Magnetometer + gyro fusion has a hard ceiling.** A 2024 ION/NAVI field study of
  smartphone magnetometer/gyro heading fusion reports **~17.4° RMS** in real
  environments, and even under *ideal, anomaly-free simulation* the same EKF fusion
  only reaches **~4–5°** — i.e. **sub-degree heading is not attainable from
  magnetometer-based fusion at all.** [navi.632]
- **ARKit `.gravityAndHeading` won't rescue you.** Apple's own docs confirm that
  configuration derives true north from Core Location's heading (`CLHeading`) — so
  it inherits the same magnetometer error; switching to it is not a sub-degree path.
  [apple-worldalignment] (Note: a popular claim that `frame.camera.eulerAngles.y == 0`
  exactly at true north under this mode was **refuted** in our verification — don't
  rely on that specific behavior.)
- **Therefore sub-degree alignment requires "plate-solving" against known objects.**
  Production apps that achieve precise registration do it by aligning to something
  whose true bearing is known, not by trusting the compass: **PeakFinder** aligns the
  rendered horizon to the real mountain silhouette (a landmark solve) rather than the
  magnetometer. [peakfinder-compass]

This is decisive for prioritization: **your sun/moon/known-aircraft alignment is not
a "nice-to-have calibration" — it is the only route to the accuracy users expect.**

---

## Workstream A — Heading: treat the compass as a coarse prior, plate-solve for the rest

1. **Keep ARKit `.gravity` + manual north (as today), but demote the magnetometer to
   a *bootstrap prior only*.** Use it to get within ~15° instantly, then refine by
   plate-solving. Don't expect the compass path to ever be the final answer.
   (Budget: compass alone ≈ 5–25° field; fusion ceiling ≈ 17° RMS / ~4–5° ideal.
   [navi.632])

2. **Continuous celestial plate-solving (primary mechanism).** Sun/Moon true azimuth
   is known to ~0.01°. Whenever one is visible above ~3°, solve the heading offset
   from it continuously and automatically (not a one-shot manual lock). This is the
   AR equivalent of an astrometric solve and is the realistic sub-degree path. Extend
   to bright planets/stars at night. Your `lockToSun()`/`lockToMoon()` already proves
   the primitive — promote it to always-on.

3. **Landmark/known-object solve as the all-weather fallback** (the PeakFinder model
   [peakfinder-compass]). When no celestial body is visible, let the user one-tap a
   *known-identity aircraft* (ADS-B bearing is exact) to solve the offset — the
   cloudy-day analog of the mountain-silhouette solve.

4. **Confidence-gated fusion + residual feedback.** Drive a 1-D complementary/Kalman
   filter (ARKit yaw = drift-prone but smooth; plate-solve = absolute truth when
   available; compass = coarse fallback), and always surface the *measured residual*
   against the sun/moon so calibration error is visible, not silent.

---

## Workstream B — ADS-B aircraft altitude & datum (well-quantified by the research)

5. **Prefer geometric altitude; treat barometric as a fallback that needs correction.**
   ADS-B barometric altitude is referenced to the **standard 1013.25 hPa** datum, not
   local pressure; Flightradar24 explicitly reports *geometric* altitude on the **WGS84
   ellipsoid**. Geometric and barometric disagree by **>245 ft about 9%** of the time
   (Cambridge J. Navigation study). [fr24-altitude, cambridge-adsb] You already prefer
   `alt_geom` — when only `alt_baro` exists, apply a **QNH correction** from the nearest
   METAR before using it for elevation geometry.

6. **Match the observer's altitude datum to the aircraft's.** Geometric ADS-B altitude
   is WGS84-ellipsoidal. CoreLocation's `CLLocation.altitude` is **geoid/MSL-referenced**,
   while **`ellipsoidalAltitude` is WGS84-ellipsoidal** — mixing the two injects the
   local **geoid undulation** (tens of meters, up to ~±100 m) straight into your
   vertical baseline. **Use `ellipsoidalAltitude` for the observer** so both ends of the
   range vector share the WGS84 datum. [apple-ellipsoidalaltitude, mapit-geoid]

7. **Dead-reckon altitude too** (as in draft #1 §5): integrate ADS-B vertical rate;
   horizontal-only extrapolation strands climbing/descending traffic at a stale altitude.

---

## Workstream C — Topocentric celestial & satellites

8. **Add pressure/temperature scaling to refraction.** Keep the Bennett/Saemundsson
   model (Meeus) you already use, but scale it by the standard factor
   **`(P / 1010) × (283 / (273 + T))`** when METAR P/T is available. [jgiesen-refract,
   juliaastro-refraction] (Caveat: a claimed ±0.0003° accuracy for the full SPA model
   was **refuted** as overstated — treat this as a small near-horizon refinement, not a
   precision guarantee.)

9. **Confirm topocentric reductions.** The rigorous chain is sidereal rotation →
   observer-difference (parallax) → SEZ/horizon coordinates (Vallado). [jgiesen-refract]
   You already do lunar parallax; ensure the same observer-difference reduction is the
   basis for anything near-Earth.

10. **Refresh the ISS TLE daily; never use one >10 days old.** SGP4 is sub-km at epoch
    but TLE error grows roughly **1–2 km/day**, and accuracy becomes unreliable past
    ~10 days. [destevez-tle, oltrogge-amos] (The specific "error ∝ age^1.5" growth law
    was **not** confirmed — treat growth as ~linear for planning.) Today the TLE is
    fetched once per session and never refreshed (`SkylightAR.swift:1631`).

---

## Workstream D — Geolocation & time

11. **Use `ellipsoidalAltitude` (see §6) and request best accuracy in AR.** Bump
    `kCLLocationAccuracyHundredMeters` (`SkylightAR.swift:588`) to `Best` while the AR
    view is active.

12. **SNTP time offset at launch.** Ephemeris (sun/moon/ISS) and dead-reckoning all key
    off the device clock; a one-shot SNTP correction guards against clock drift —
    relevant because the ISS moves ~7.7 km/s, so even a 1 s clock error ≈ 7.7 km of ISS
    position. [projectpluto-gps]

---

## What the research changed vs. the code-grounded draft

| Topic | Draft #1 said | Research adds |
| --- | --- | --- |
| Heading priority | "Heading dominates; fuse + auto-align" | **Quantifies the ceiling** (~17° RMS / ~4–5° ideal) → plate-solving isn't optional, it's the *only* sub-degree path; compass is a coarse prior. [navi.632] |
| `.gravityAndHeading` | (not discussed) | Won't help — it's built on `CLHeading`. [apple-worldalignment] |
| Aircraft altitude | "Prefer geom; QNH for baro" | Quantified: baro = 1013 hPa datum; **~9% disagree >245 ft.** [cambridge-adsb] |
| Observer altitude | "Geoid undulation uncorrected" | Concrete fix: **use `ellipsoidalAltitude`** to match ADS-B WGS84 datum. [apple-ellipsoidalaltitude] |
| Refraction | "Add P/T" | Exact factor `(P/1010)×(283/(273+T))`; SPA "ultra-precision" claim debunked. |
| ISS TLE | "Refresh daily" | Budget: **~1–2 km/day, useless >10 days.** [destevez-tle] |

**Net:** the sequence in `ACCURACY_PLAN.md` stands, but elevate **celestial/landmark
plate-solving (A2–A3)** to *the* headline feature — the research says the compass can
never deliver the last degree, so the known-object solve is the product's accuracy
engine, not a calibration nicety.

---

## Sources

- [navi.632] ION/NAVI 2024, smartphone magnetometer/gyro heading fusion — https://navi.ion.org/content/71/1/navi.632
- [apple-worldalignment] Apple — ARConfiguration.WorldAlignment.gravityAndHeading — https://developer.apple.com/documentation/arkit/arconfiguration/worldalignment/gravityandheading
- [peakfinder-compass] PeakFinder — compass/landmark alignment — https://www.peakfinder.com/mobile/compass/
- [fr24-altitude] Flightradar24 — Understanding altitude — https://www.flightradar24.com/blog/inside-flightradar24/understanding-altitude-on-flightradar24/
- [cambridge-adsb] J. Navigation — geometric vs barometric altitude in ADS-B — https://www.cambridge.org/core/journals/journal-of-navigation/article/abs/study-on-geometric-and-barometric-altitude-data-in-automatic-dependent-surveillance-broadcast-adsb-messages/F44587C944F9C41E7B88A96419EBFAF7
- [apple-ellipsoidalaltitude] Apple — CLLocation.ellipsoidalAltitude — https://developer.apple.com/documentation/corelocation/cllocation/ellipsoidalaltitude
- [mapit-geoid] Height and geoid models — https://mapitgis.com/docs/external-gnss/height-and-geoid-models/
- [jgiesen-refract] Atmospheric refraction (Meeus) — http://www.jgiesen.de/refract/index.html
- [juliaastro-refraction] JuliaAstro SolarPosition — refraction — https://juliaastro.org/SolarPosition/stable/refraction/
- [destevez-tle] D. Estévez — A brief study of TLE variation — https://destevez.net/2017/11/a-brief-study-of-tle-variation/
- [oltrogge-amos] Oltrogge, AMOS 2014 — TLE/SGP4 accuracy — https://amostech.com/TechnicalPapers/2014/Poster/OLTROGGE.pdf
- [projectpluto-gps] Project Pluto — GPS/time — https://www.projectpluto.com/gps_expl.htm

> Verification note: claims above are those that survived 3-vote adversarial checking.
> Explicitly **refuted** during research (do not treat as fact): magnetometer EKF
> reaching sub-degree under ideal conditions; SPA refraction ±0.0003°; TLE error ∝
> age^1.5; ARKit `eulerAngles.y == 0` exactly at true north under gravityAndHeading.
