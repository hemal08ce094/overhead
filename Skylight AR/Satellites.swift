//
//  Satellites.swift
//  Overhead
//
//  The naked-eye satellite catalog: CelesTrak's curated "visual" group —
//  the ~150 objects bright enough to spot without optics. Same TLE pipeline
//  as the ISS (fetch, cache, SGP4), scaled from one satellite to the whole
//  visible fleet. The raw element text is cached on disk so a cold launch
//  in airplane mode still has yesterday's sky.
//

import Foundation

/// One tracked object from the visual group, kept as raw TLE lines plus the
/// two numbers the reentry watch needs. `Satellite` objects (SatelliteKit)
/// are built by the scene, not here — this type stays Sendable.
struct SatelliteEntry: Sendable, Equatable {
    let name: String
    let noradId: Int
    let line1: String
    let line2: String

    /// Mean motion, rev/day (TLE line 2, columns 53–63). ~15.5 for LEO;
    /// climbing past 16 means the orbit is decaying fast.
    var meanMotion: Double {
        Double(line2.dropFirst(52).prefix(11).trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// First derivative of mean motion, rev/day² (line 1 stores ṅ/2 in
    /// columns 34–43). Positive and large = the atmosphere is winning.
    var meanMotionDot: Double {
        2 * (Double(line1.dropFirst(33).prefix(10).trimmingCharacters(in: .whitespaces)) ?? 0)
    }

    /// Mean altitude (km) implied by the mean motion, circular-orbit
    /// approximation — accurate enough to rank "how close to reentry".
    var meanAltitudeKm: Double {
        guard meanMotion > 0.1 else { return .infinity }
        let mu = 398_600.4418                       // km³/s²
        let period = 86_400.0 / meanMotion          // s
        let a = pow(mu * pow(period / (2 * .pi), 2), 1.0 / 3.0)
        return a - 6_371.0
    }
}

/// Fetches and caches the visual-group elements. Memory → disk (24 h) →
/// CelesTrak, falling back to a stale disk copy when the network is out —
/// a day-old TLE draws a satellite a fraction of a degree off, which is
/// still better than an empty sky.
actor SatelliteCatalog {
    static let shared = SatelliteCatalog()

    private var cached: [SatelliteEntry]?
    private var fetchedAt: Date?
    private static let maxAge: TimeInterval = 24 * 3600

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("visual-satellites.tle")
    }

    func entries() async -> [SatelliteEntry] {
        if let cached, let fetchedAt, Date().timeIntervalSince(fetchedAt) < Self.maxAge {
            return cached
        }
        // Disk copy still fresh? Parse it and skip the network entirely.
        if cached == nil,
           let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < Self.maxAge,
           let text = try? String(contentsOf: cacheURL, encoding: .utf8) {
            let parsed = Self.parse(text)
            if !parsed.isEmpty {
                cached = parsed
                fetchedAt = modified
                return parsed
            }
        }
        // Network refresh; any failure falls back to whatever we have.
        if let fresh = await fetchFromNetwork() {
            cached = fresh
            fetchedAt = Date()
            return fresh
        }
        if let cached { return cached }
        if let text = try? String(contentsOf: cacheURL, encoding: .utf8) {
            let stale = Self.parse(text)
            cached = stale
            fetchedAt = Date()   // don't re-hit the network every call while offline
            return stale
        }
        return []
    }

    private func fetchFromNetwork() async -> [SatelliteEntry]? {
        guard let url = URL(string: "https://celestrak.org/NORAD/elements/gp.php?GROUP=visual&FORMAT=tle") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let parsed = Self.parse(text)
        guard parsed.count > 10 else { return nil }   // an error page, not elements
        try? text.write(to: cacheURL, atomically: true, encoding: .utf8)
        return parsed
    }

    /// TLE text → entries. The ISS (25544) is skipped — it has its own layer,
    /// glyph, and pass alerts.
    private static func parse(_ text: String) -> [SatelliteEntry] {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var out: [SatelliteEntry] = []
        var i = 0
        while i + 2 < lines.count {
            let name = lines[i], l1 = lines[i + 1], l2 = lines[i + 2]
            guard l1.hasPrefix("1 "), l2.hasPrefix("2 ") else { i += 1; continue }
            let id = Int(l1.dropFirst(2).prefix(5).trimmingCharacters(in: .whitespaces)) ?? 0
            if id != 25_544 {
                out.append(SatelliteEntry(name: name, noradId: id, line1: l1, line2: l2))
            }
            i += 3
        }
        return out
    }
}
