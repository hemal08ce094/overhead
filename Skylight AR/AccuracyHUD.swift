//
//  AccuracyHUD.swift
//  Skylight AR
//
//  DEBUG diagnostics overlay: end-to-end sky error (predicted vs camera-
//  observed sun/moon), compass state, and the transit scorecard. Enabled
//  with the `-accuracyHUD YES` launch argument.
//

import SwiftUI

struct AccuracyHUDView: View {
    var engine: SkyEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ACCURACY LAB")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))

            row("compass", engine.headingAccuracyDeg >= 0
                ? String(format: "±%.1f°", engine.headingAccuracyDeg)
                : "unknown")

            if let r = engine.accuracyReading {
                let age = Date().timeIntervalSince(r.date)
                row("\(r.body.rawValue.lowercased()) Δ",
                    String(format: "az %+.2f° el %+.2f° (c %.2f%@)",
                           r.deltaAzDeg, r.deltaElDeg, r.confidence,
                           age > 3 ? ", stale" : ""))
            } else {
                row("sun/moon", "not in frame")
            }

            let log = TransitOutcomeLog.shared.entries
            if log.isEmpty {
                row("transits", "none yet")
            } else {
                let done = log.filter { $0.outcome != nil }
                row("transits", "\(log.count) predicted · \(done.count) resolved")
                ForEach(log.suffix(3).reversed()) { e in
                    row(e.callsign,
                        "\(e.body) · \(e.outcome?.rawValue ?? "pending") · drift \(String(format: "%.1f", e.driftSeconds))s")
                }
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.white.opacity(0.85))
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.white.opacity(0.55))
            Text(value)
        }
    }
}
