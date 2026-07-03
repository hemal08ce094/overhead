//
//  Routes.swift
//  Skylight AR
//
//  Route enrichment via adsbdb (origin/destination/airline for a callsign).
//  Cached aggressively — routes don't change mid-flight — with a backoff on
//  unknown callsigns so we never hammer the API.
//

import Foundation

struct PlanePhoto: Sendable, Equatable {
    let url: URL
    let photographer: String
}

/// Airframe photos by ICAO hex via the free planespotters.net API.
/// Cached per hex (including "no photo") so each airframe is fetched once.
@MainActor
final class PlanePhotoFetcher {
    private var cache: [String: PlanePhoto?] = [:]
    private var inFlight: Set<String> = []
    private var failedAt: [String: Date] = [:]

    /// Called when a hex resolves (with or without a photo).
    var onResolved: ((String) -> Void)?

    func cachedPhoto(_ hex: String) -> PlanePhoto? { cache[hex] ?? nil }

    func request(_ hex: String) {
        guard cache.index(forKey: hex) == nil, !inFlight.contains(hex) else { return }
        if let when = failedAt[hex], Date().timeIntervalSince(when) < 600 { return }   // 10-min backoff
        inFlight.insert(hex)
        Task { await fetch(hex) }
    }

    private func fetch(_ hex: String) async {
        defer { inFlight.remove(hex) }
        // planespotters.net rejects generic library User-Agents.
        var request = URL(string: "https://api.planespotters.net/pub/photos/hex/\(hex)")
            .map { URLRequest(url: $0) }
        request?.setValue("SkylightAR/1.0 (+mailto:hemal08ce094@gmail.com)",
                          forHTTPHeaderField: "User-Agent")
        // Only a definitive 200 caches — "no photo exists" is permanent, but a
        // timeout or 429 must retry later, not blank the airframe all session.
        guard let request,
              let (data, resp) = try? await URLSession.shared.data(for: request),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let photos = obj["photos"] as? [[String: Any]] else {
            failedAt[hex] = Date()
            return
        }
        var result: PlanePhoto?
        if let first = photos.first {
            let thumb = (first["thumbnail_large"] as? [String: Any])
                ?? (first["thumbnail"] as? [String: Any])
            if let src = thumb?["src"] as? String, let photoURL = URL(string: src) {
                result = PlanePhoto(url: photoURL,
                                    photographer: first["photographer"] as? String ?? "")
            }
        }
        cache[hex] = result
        onResolved?(hex)
    }
}

struct FlightRoute: Sendable, Equatable {
    var airline: String?
    var originCode: String?
    var destinationCode: String?
    var originCity: String?
    var destinationCity: String?
    var originLat: Double?
    var originLon: Double?
    var destLat: Double?
    var destLon: Double?
    var destCountryISO: String?
}

@MainActor
final class RouteEnricher {
    private var cache: [String: FlightRoute] = [:]
    private var inFlight: Set<String> = []
    private var failedAt: [String: Date] = [:]

    /// Called on the main actor when a callsign resolves, so labels/cards refresh.
    var onResolved: ((String) -> Void)?

    func cached(_ callsign: String?) -> FlightRoute? {
        guard let cs = Self.normalize(callsign) else { return nil }
        return cache[cs]
    }

    /// Kick off a fetch if we don't already have (or aren't already fetching) it.
    func request(_ callsign: String?) {
        guard let cs = Self.normalize(callsign) else { return }
        if cache[cs] != nil || inFlight.contains(cs) { return }
        if let when = failedAt[cs], Date().timeIntervalSince(when) < 600 { return }   // 10-min backoff
        inFlight.insert(cs)
        Task { await fetch(cs) }
    }

    private func fetch(_ callsign: String) async {
        defer { inFlight.remove(callsign) }
        guard let url = URL(string: "https://api.adsbdb.com/v0/callsign/\(callsign)") else { return }
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let route = Self.parse(data) else {
            failedAt[callsign] = Date()
            return
        }
        cache[callsign] = route
        onResolved?(callsign)
    }

    private static func normalize(_ callsign: String?) -> String? {
        guard let cs = callsign?.trimmingCharacters(in: .whitespaces), !cs.isEmpty else { return nil }
        return cs
    }

    private static func parse(_ data: Data) -> FlightRoute? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = obj["response"] as? [String: Any],
              let fr = response["flightroute"] as? [String: Any] else { return nil }
        let origin = fr["origin"] as? [String: Any]
        let dest = fr["destination"] as? [String: Any]
        let airline = (fr["airline"] as? [String: Any])?["name"] as? String
        return FlightRoute(
            airline: airline,
            originCode: (origin?["iata_code"] as? String) ?? (origin?["icao_code"] as? String),
            destinationCode: (dest?["iata_code"] as? String) ?? (dest?["icao_code"] as? String),
            originCity: origin?["municipality"] as? String,
            destinationCity: dest?["municipality"] as? String,
            originLat: origin?["latitude"] as? Double,
            originLon: origin?["longitude"] as? Double,
            destLat: dest?["latitude"] as? Double,
            destLon: dest?["longitude"] as? Double,
            destCountryISO: dest?["country_iso_name"] as? String)
    }
}
