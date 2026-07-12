//
//  AirportWeather.swift
//  Skylight AR
//
//  Live field weather from NOAA's aviationweather.gov METAR API — official,
//  free, no key, global ICAO coverage. The only thing that leaves the device
//  is the airport's ICAO code. Cached ten minutes per station (METARs are
//  issued hourly; special reports rarely beat that).
//

import Foundation

struct Metar: Decodable, Equatable {
    let rawOb: String?
    let obsTime: Int?              // unix seconds
    let temp: Double?              // °C
    let dewp: Double?
    let wdir: WindDir?             // degrees, or "VRB"
    let wspd: Double?              // kt
    let wgst: Double?
    let visib: Visib?              // statute miles, or "10+"
    let altim: Double?             // hPa
    let fltCat: String?            // VFR / MVFR / IFR / LIFR
    let clouds: [Cloud]?

    struct Cloud: Decodable, Equatable { let cover: String?; let base: Double? }

    /// The API sends numbers or strings ("VRB", "10+") in the same fields.
    enum WindDir: Decodable, Equatable {
        case degrees(Double), variable
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let d = try? c.decode(Double.self) { self = .degrees(d) } else { self = .variable }
        }
    }
    enum Visib: Decodable, Equatable {
        case miles(Double), plus(Double)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let d = try? c.decode(Double.self) { self = .miles(d) }
            else {
                let s = (try? c.decode(String.self)) ?? ""
                self = .plus(Double(s.replacingOccurrences(of: "+", with: "")) ?? 10)
            }
        }
    }

    var observed: Date? { obsTime.map { Date(timeIntervalSince1970: Double($0)) } }
    /// Lowest broken/overcast layer — the ceiling, if any.
    var ceiling: Cloud? {
        clouds?.filter { ["BKN", "OVC", "VV"].contains($0.cover ?? "") }
            .min { ($0.base ?? .infinity) < ($1.base ?? .infinity) }
    }
}

@MainActor
@Observable
final class AirportWeather {
    static let shared = AirportWeather()

    enum State: Equatable { case idle, loading, loaded(Metar), unavailable }
    private(set) var state: State = .idle

    private var cache: [String: (metar: Metar, at: Date)] = [:]
    private var task: Task<Void, Never>?

    func load(icao: String) {
        let station = icao.uppercased()
        if let hit = cache[station], Date().timeIntervalSince(hit.at) < 600 {
            state = .loaded(hit.metar)
            return
        }
        state = .loading
        task?.cancel()
        task = Task {
            guard let url = URL(string:
                "https://aviationweather.gov/api/data/metar?ids=\(station)&format=json") else {
                state = .unavailable; return
            }
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 8
                let (data, _) = try await URLSession.shared.data(for: req)
                guard !Task.isCancelled else { return }
                if let metar = try JSONDecoder().decode([Metar].self, from: data).first {
                    cache[station] = (metar, Date())
                    state = .loaded(metar)
                } else {
                    state = .unavailable   // no METAR station at this field
                }
            } catch {
                guard !Task.isCancelled else { return }
                state = .unavailable
            }
        }
    }
}
