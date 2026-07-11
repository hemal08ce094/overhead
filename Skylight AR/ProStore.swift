//
//  ProStore.swift
//  Skylight AR
//
//  Overhead Pro: a single lifetime unlock, StoreKit 2 only — no server, no
//  accounts, entitlement straight from the App Store receipt (matching the
//  app's no-tracking privacy story). The paywall lives here too, and all its
//  marketing copy sits in one editable catalog below.
//

import SwiftUI
import StoreKit

// MARK: - Editable Pro catalog

/// Every user-facing Pro string in one place — tweak copy or reorder feature
/// rows here and nowhere else. The price is NOT here: it comes localized from
/// App Store Connect at runtime, so repricing needs no app update.
enum ProCatalog {
    static let title = String(localized: "Overhead Pro")
    static let tagline = String(localized: "The sky's power tools. One purchase, yours forever.")

    static let features: [(icon: String, title: String, detail: String)] = [
        ("clock.arrow.2.circlepath",
         String(localized: "Time Machine"),
         String(localized: "Scrub the sky to any date — stand under next month's eclipse tonight.")),
        ("calendar.badge.clock",
         String(localized: "Preview any sky event"),
         String(localized: "Jump straight to an eclipse, a shower peak, or a full moon from its page.")),
        ("sparkles",
         String(localized: "Everything we build next"),
         String(localized: "Transit capture tools and every future Pro feature — included.")),
    ]

    static let purchaseFootnote =
        String(localized: "One-time purchase · Yours forever · Family Sharing included")
    static let ownedTitle = String(localized: "You're Pro")
    static let ownedDetail = String(localized: "Thank you for keeping Overhead pointed at the sky.")
}

// MARK: - Store

/// Owns the lifetime entitlement. `isPro` is the single gate the whole app
/// reads; a mirror lands in the App Group so widgets and the watch can check
/// without touching StoreKit.
@MainActor
@Observable
final class ProStore {
    static let shared = ProStore()

    private(set) var isPro = false
    private(set) var product: Product?
    private(set) var purchasing = false

    private var updatesTask: Task<Void, Never>?

    private init() {
        // Keep listening for the app's whole life: purchases from another
        // device, Ask to Buy approvals, refunds — all arrive here.
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
                await self?.refreshEntitlement()
            }
        }
        Task {
            await refreshEntitlement()
            await loadProduct()
        }
    }

    func loadProduct() async {
        guard product == nil else { return }
        product = try? await Product.products(for: [AppInfo.proLifetimeID]).first
    }

    func refreshEntitlement() async {
        var owned = false
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let transaction) = entitlement,
               transaction.productID == AppInfo.proLifetimeID,
               transaction.revocationDate == nil {
                owned = true
            }
        }
        #if DEBUG
        // `-forcePro YES` in the scheme / simctl launch args fakes ownership
        // for UI work without a StoreKit configuration.
        if UserDefaults.standard.bool(forKey: "forcePro") { owned = true }
        #endif
        isPro = owned
        // Cheap mirror for the widget/watch processes.
        UserDefaults(suiteName: AppInfo.appGroupID)?.set(owned, forKey: "pro.entitled")
    }

    func purchase() async {
        guard let product, !purchasing else { return }
        purchasing = true
        defer { purchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    await refreshEntitlement()
                    Analytics.log("Pro.purchased")
                }
            case .pending:
                // Ask to Buy — resolves later through Transaction.updates.
                Analytics.log("Pro.purchasePending")
            case .userCancelled:
                Analytics.log("Pro.purchaseCancelled")
            @unknown default:
                break
            }
        } catch {
            // Purchase sheet already surfaced the error; nothing to add.
        }
    }

    func restore() async {
        try? await AppStore.sync()
        await refreshEntitlement()
    }
}

// MARK: - Small UI atoms

/// The little gold chip that marks a Pro feature wherever it's gated.
struct ProChip: View {
    var body: some View {
        Text(verbatim: "PRO")
            .font(Theme.display(9, .heavy))
            .tracking(1.2)
            .foregroundStyle(Theme.nightBottom)
            .padding(.horizontal, 6).padding(.vertical, 2.5)
            .background(Theme.gold, in: Capsule())
    }
}

// MARK: - Paywall

/// The Overhead Pro page. Works pushed (settings) or as a sheet (feature
/// gates); the buy button uses the localized App Store price.
struct PaywallView: View {
    /// Where the paywall was opened from, for conversion analytics.
    var source: String = "settings"

    private var store: ProStore { ProStore.shared }

    private var buyDisabled: Bool {
        #if DEBUG
        store.purchasing                          // let screenshots show it live
        #else
        store.product == nil || store.purchasing  // offline: purchase() would no-op
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                // Hero: the night sky's product shot.
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(RadialGradient(colors: [Theme.gold.opacity(0.35), .clear],
                                                 center: .center, startRadius: 6, endRadius: 70))
                            .frame(width: 140, height: 140)
                        Image(systemName: "sparkles")
                            .font(.system(size: 52, weight: .medium))
                            .foregroundStyle(
                                LinearGradient(colors: [Theme.gold, Theme.accent],
                                               startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                    Text(ProCatalog.title)
                        .font(Theme.display(30, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(ProCatalog.tagline)
                        .font(Theme.display(14, .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }
                .padding(.top, 26)

                VStack(spacing: 0) {
                    ForEach(Array(ProCatalog.features.enumerated()), id: \.offset) { i, feature in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: feature.icon)
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(Theme.gold)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(feature.title)
                                    .font(Theme.display(16, .semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                Text(feature.detail)
                                    .font(Theme.display(13, .regular))
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        if i < ProCatalog.features.count - 1 {
                            Divider().overlay(.white.opacity(0.08)).padding(.leading, 60)
                        }
                    }
                }
                .padding(.vertical, 4)
                .nightCard()

                if store.isPro {
                    VStack(spacing: 6) {
                        Label(ProCatalog.ownedTitle, systemImage: "checkmark.seal.fill")
                            .font(Theme.display(17, .bold))
                            .foregroundStyle(Theme.gold)
                        Text(ProCatalog.ownedDetail)
                            .font(Theme.display(13, .regular))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .nightCard()
                } else {
                    VStack(spacing: 12) {
                        Button {
                            Task { await store.purchase() }
                        } label: {
                            if store.purchasing {
                                ProgressView().tint(Theme.nightBottom)
                            } else if let product = store.product {
                                Text("Unlock for \(product.displayPrice)")
                            } else {
                                // No product yet (offline, or the StoreKit
                                // configuration isn't selected in the scheme).
                                #if DEBUG
                                // simctl launches skip the .storekit config;
                                // show the real ASC price for screenshots.
                                Text(verbatim: "Unlock for $39.99")
                                #else
                                Text("Unlock Overhead Pro")
                                #endif
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(buyDisabled)

                        Text(ProCatalog.purchaseFootnote)
                            .font(Theme.display(11, .regular))
                            .foregroundStyle(Theme.textTertiary)

                        Link("Terms of Use", destination: AppInfo.termsURL)
                            .font(Theme.display(11, .medium))
                            .foregroundStyle(Theme.textTertiary.opacity(0.9))

                        Button("Restore purchases") {
                            Task { await store.restore() }
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                }
                Spacer(minLength: 30)
            }
            .padding(.horizontal, 24)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.skyGradient.ignoresSafeArea())
        .navigationTitle(ProCatalog.title)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .task {
            await store.loadProduct()
            Analytics.log("Paywall.shown", ["source": source])
        }
    }
}

#Preview("Paywall") {
    NavigationStack { PaywallView() }
}
