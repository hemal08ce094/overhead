//
//  AccuracyLab.swift
//  Skylight AR
//
//  The measurement side of accuracy work: the camera itself is the one
//  ground truth the system carries. When the sun or moon is in frame, the
//  difference between where the sky layer draws it and where the sensor
//  actually sees it is the whole rendering pipeline's end-to-end error —
//  ephemeris, alignment, heading trim, refraction — in one number.
//
//  Also keeps the transit scorecard: every prediction's lifecycle, so
//  "the countdown was right" becomes a measurable rate, not a feeling.
//

import ARKit
import SceneKit
import os.log

// MARK: - Reading

/// One predicted-vs-observed comparison for a drawn celestial disc.
struct AccuracyReading {
    enum Body: String { case sun = "Sun", moon = "Moon" }
    let body: Body
    /// Observed minus predicted, degrees. Positive az = the real body sits
    /// clockwise (to the right) of the drawn one — the heading is off CCW.
    let deltaAzDeg: Double
    let deltaElDeg: Double
    let confidence: Double      // 0…1, from blob contrast
    let date: Date
}

// MARK: - Camera-frame detector

/// Finds the brightest compact blob near a predicted screen position in the
/// AR camera frame — the sun in day frames, the moon against a night sky.
enum CelestialDetector {

    struct Hit { let viewPoint: CGPoint; let confidence: Double }

    /// Search the luma plane around `predicted` (view coords). Returns the
    /// blob centroid mapped back to view coords, or nil when nothing in the
    /// window is convincingly brighter than its surroundings.
    /// The two bodies photograph differently and get different gates: the sun
    /// saturates and blooms (centroid over saturated pixels only, generous
    /// size cap), the moon is a compact disc against dark sky.
    static func detect(in frame: ARFrame, near predicted: CGPoint,
                       viewport: CGSize, orientation: UIInterfaceOrientation,
                       body: AccuracyReading.Body) -> Hit? {
        let buffer = frame.capturedImage
        guard CVPixelBufferGetPlaneCount(buffer) >= 1 else { return nil }

        // View point → normalized image point (inverse of the display map).
        let toView = frame.displayTransform(for: orientation, viewportSize: viewport)
        guard let toImage = invert(toView) else { return nil }
        let normView = CGPoint(x: predicted.x / viewport.width,
                               y: predicted.y / viewport.height)
        let normImage = normView.applying(toImage)

        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let center = CGPoint(x: normImage.x * CGFloat(width),
                             y: normImage.y * CGFloat(height))

        // Window: ±6° of sky, from the camera's focal length in pixels.
        let fx = CGFloat(frame.camera.intrinsics[0][0])
        let radius = max(24, fx * 0.105)
        guard center.x > -radius, center.x < CGFloat(width) + radius,
              center.y > -radius, center.y < CGFloat(height) + radius else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)

        let x0 = max(0, Int(center.x - radius)), x1 = min(width - 1, Int(center.x + radius))
        let y0 = max(0, Int(center.y - radius)), y1 = min(height - 1, Int(center.y + radius))
        guard x1 > x0 + 8, y1 > y0 + 8 else { return nil }

        // Pass 1 (sparse): peak brightness + background estimate.
        let step = 4
        var peak: Int = 0
        var backgroundSum = 0, backgroundN = 0
        var y = y0
        while y <= y1 {
            var x = x0
            while x <= x1 {
                let v = Int(luma[y * rowBytes + x])
                if v > peak { peak = v }
                backgroundSum += v; backgroundN += 1
                x += step
            }
            y += step
        }
        let background = backgroundSum / max(1, backgroundN)
        // A disc must genuinely outshine its window — clouds and haze fail
        // here. The sun's window is itself bright sky, so its contrast bar is
        // lower and its floor is saturation; the moon must stand off dark sky.
        let minContrast = body == .sun ? 24 : 48
        let minPeak = body == .sun ? 250 : 176
        guard peak - background >= minContrast, peak >= minPeak else { return nil }

        // Pass 2 (sparse): intensity-weighted centroid. For the sun, only the
        // saturated core — flare ghosts and bloom skirts are dimmer and would
        // drag the centroid off the disc.
        let threshold = body == .sun ? 250 : max(peak - 16, background + 32)
        var sx = 0.0, sy = 0.0, sw = 0.0, count = 0
        y = y0
        while y <= y1 {
            var x = x0
            while x <= x1 {
                let v = Int(luma[y * rowBytes + x])
                if v >= threshold {
                    let w = Double(v - background)
                    sx += Double(x) * w; sy += Double(y) * w; sw += w
                    count += 1
                }
                x += step
            }
            y += step
        }
        guard sw > 0 else { return nil }
        // Blob size gate, in degrees of sky: the moon is ~0.5° (cap 2.5°
        // rejects lit cloud banks); the sun's saturated core can bloom far
        // wider on a phone sensor, so it gets up to 8°.
        let area = Double(count * step * step)
        let diameterDeg = 2 * (area / .pi).squareRoot() / Double(fx) * 180 / .pi
        let maxDiameter = body == .sun ? 8.0 : 2.5
        guard diameterDeg > 0.12, diameterDeg < maxDiameter else { return nil }

        let centroid = CGPoint(x: sx / sw, y: sy / sw)
        let outNorm = CGPoint(x: centroid.x / CGFloat(width),
                              y: centroid.y / CGFloat(height)).applying(toView)
        // A saturated core that passed the size gates IS the sun — contrast
        // against the bright circumsolar sky understates it badly.
        let confidence = body == .sun ? 0.9 : min(1, Double(peak - background) / 140)
        return Hit(viewPoint: CGPoint(x: outNorm.x * viewport.width,
                                      y: outNorm.y * viewport.height),
                   confidence: confidence)
    }

    /// CGAffineTransform.inverted() traps on singular matrices; AR display
    /// transforms can be degenerate for a frame during rotation.
    private static func invert(_ t: CGAffineTransform) -> CGAffineTransform? {
        let det = t.a * t.d - t.b * t.c
        guard abs(det) > 1e-9 else { return nil }
        return t.inverted()
    }
}

// MARK: - Transit scorecard

/// Lifecycle log for transit predictions: born → (refined)* → resolved.
/// Ring-buffered for the HUD; mirrored to the unified log for field reports.
@MainActor
final class TransitOutcomeLog {
    static let shared = TransitOutcomeLog()

    enum Outcome: String { case playedOut = "played out", dissolved = "dissolved" }

    struct Entry: Identifiable {
        let id: String              // callsign × body × minute bucket
        let callsign: String
        let body: String
        let firstPredicted: Date
        var lastPredicted: Date
        var refinements: Int = 0
        var outcome: Outcome?
        /// How far the crossing time moved between first sighting and final —
        /// small drift means the motion model held.
        var driftSeconds: Double { lastPredicted.timeIntervalSince(firstPredicted) }
    }

    private(set) var entries: [Entry] = []
    private let log = Logger(subsystem: "overhead", category: "transit-outcomes")

    /// One unresolved entry per plane × body — refinements move the predicted
    /// time, so identity can't be time-bucketed.
    private func openIndex(_ p: TransitPrediction) -> Int? {
        entries.lastIndex { $0.callsign == p.callsign && $0.body == p.body.rawValue
                            && $0.outcome == nil }
    }

    /// Record a prediction: a new crossing begins an entry, a re-prediction
    /// of the same crossing refines it.
    func note(_ p: TransitPrediction) {
        if let i = openIndex(p) {
            guard abs(entries[i].lastPredicted.timeIntervalSince(p.date)) > 0.05 else { return }
            entries[i].lastPredicted = p.date
            entries[i].refinements += 1
            return
        }
        entries.append(Entry(id: "\(p.callsign)-\(p.body.rawValue)-\(Int(p.date.timeIntervalSince1970))",
                             callsign: p.callsign, body: p.body.rawValue,
                             firstPredicted: p.date, lastPredicted: p.date))
        if entries.count > 20 { entries.removeFirst(entries.count - 20) }
        log.info("predicted \(p.callsign) × \(p.body.rawValue) at \(p.date) sep \(p.separationDeg)°")
    }

    func resolve(_ p: TransitPrediction, _ outcome: Outcome) {
        guard let i = openIndex(p) else { return }
        entries[i].outcome = outcome
        log.info("\(p.callsign) × \(p.body.rawValue): \(outcome.rawValue), drift \(self.entries[i].driftSeconds, format: .fixed(precision: 1))s over \(self.entries[i].refinements) refinements")
    }
}
