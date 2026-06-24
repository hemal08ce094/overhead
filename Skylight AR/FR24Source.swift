//
//  FR24Source.swift
//  Skylight AR
//
//  Flightradar24 API data source — drops in behind the `DataSource` protocol
//  for global, satellite-backed (Aireon) coverage where the community ADS-B
//  feeds are blind (the Gulf, oceans). Used when an FR24 API token is set.
//
//  FR24 bills per call, so the poll interval is deliberately slow and the
//  fetch is one bounded query per poll. See ACCESSIBILITY/strategy notes.
//

import Foundation

/// Flightradar24 live flight positions. Endpoint + field names verified against
/// Flightradar24's official API (fr24api.flightradar24.com, Accept-Version v1).
struct FR24Source: DataSource {
    var apiKey: String
    var baseURL = "https://fr24api.flightradar24.com/api"
    var session: URLSession = .shared

    /// FR24 is polled slowly (cost) and aggregates upstream, so a fix is a touch
    /// staler than airplanes.live by the time we render it — project a bit further.
    var feedLatencySec: Double { 2.5 }

    func aircraft(lat: Double, lon: Double, radiusNm: Int) async throws -> [Aircraft] {
        // FR24 queries a bounding box (N,S,W,E), not a radius.
        let latD = Double(radiusNm) / 60.0
        let lonD = Double(radiusNm) / (60.0 * max(0.2, cos(lat * .pi / 180)))
        let bounds = String(format: "%.4f,%.4f,%.4f,%.4f",
                            lat + latD, lat - latD, lon - lonD, lon + lonD)
        return try await fetch([URLQueryItem(name: "bounds", value: bounds)])
    }

    func search(field: AircraftSearchField, value: String) async throws -> [Aircraft] {
        let v = field.normalized(value)
        guard !v.isEmpty else { return [] }
        let key: String
        switch field {
        case .callsign:     key = "callsigns"
        case .registration: key = "registrations"
        case .type:         key = "aircraft"
        case .squawk:       key = "squawks"
        }
        return try await fetch([URLQueryItem(name: key, value: v)])
    }

    private func fetch(_ items: [URLQueryItem]) async throws -> [Aircraft] {
        guard !apiKey.isEmpty,
              var comps = URLComponents(string: "\(baseURL)/live/flight-positions/full") else {
            throw URLError(.badURL)
        }
        comps.queryItems = items
        guard let url = comps.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("v1", forHTTPHeaderField: "Accept-Version")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(http.statusCode == 401 ? .userAuthenticationRequired : .badServerResponse)
        }
        let records = (try? JSONDecoder().decode(FR24Envelope.self, from: data).data)
            ?? (try? JSONDecoder().decode([FR24Flight].self, from: data))
            ?? []
        return records.compactMap(Aircraft.init(fr24:))
    }
}

// MARK: - FR24 decoding

private struct FR24Envelope: Decodable { let data: [FR24Flight] }

private struct FR24Flight: Decodable {
    let fr24_id: String?
    let hex: String?
    let callsign: String?
    let flight: String?
    let lat: Double?
    let lon: Double?
    let track: Double?
    let alt: Double?
    let gspeed: Double?
    let vspeed: Double?
    let squawk: String?
    let timestamp: String?
    let type: String?
    let reg: String?
}

private extension String {
    var fr24Trimmed: String? {
        let t = trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}

private let fr24ISO: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

private extension Aircraft {
    /// Map an FR24 record to the normalized model; drop fixes without a position
    /// or any usable identifier.
    init?(fr24 f: FR24Flight) {
        guard let lat = f.lat, let lon = f.lon else { return nil }
        guard let id = f.hex?.fr24Trimmed ?? f.fr24_id?.fr24Trimmed else { return nil }
        self.hex = id.lowercased()
        self.callsign = (f.callsign ?? f.flight)?.fr24Trimmed
        self.lat = lat
        self.lon = lon
        let altFt = f.alt ?? 0
        self.onGround = altFt <= 0
        self.altGeom = nil
        self.altBaro = altFt > 0 ? altFt : nil
        self.track = f.track
        self.groundSpeedKts = f.gspeed
        self.verticalRateFpm = f.vspeed
        // Age the fix from its timestamp so render-time dead reckoning projects
        // it forward correctly (FR24 fixes can be a few seconds old).
        if let ts = f.timestamp, let when = fr24ISO.date(from: ts) {
            self.positionAgeSec = max(0, Date().timeIntervalSince(when))
        } else {
            self.positionAgeSec = nil
        }
        self.category = nil
        self.type = f.type?.fr24Trimmed
        self.registration = f.reg?.fr24Trimmed
        self.squawk = f.squawk?.fr24Trimmed
    }
}
