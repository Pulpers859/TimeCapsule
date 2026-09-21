import StoreKit
import SwiftUI

/// The one place Attic asks for money.
///
/// Presented when someone reaches a Pro feature, and reachable on demand from
/// Settings. Deliberately does not block the daily "on this day" experience —
/// that is what convinces someone the app is worth paying for, and it cannot do
/// that from behind a paywall.
struct PaywallView: View {
    @EnvironmentObject private var store: PurchaseStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // NavigationStack is load-bearing, not decoration: `.toolbar` has no
        // bar to render into without a navigation container, so the Close
        // button would simply not exist and the sheet could only be swiped away.
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView {
                    VStack(spacing: 0) {
                        BrandGlyph(systemName: "sparkles", size: 92)
                            .padding(.top, 12)
                            .padding(.bottom, 24)

                        Text("Attic Pro")
                            .font(.system(size: 30, design: .rounded).weight(.bold))
                            .padding(.bottom, 8)

                        Text("A one-time purchase. No subscription, ever.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.bottom, 32)

                        VStack(alignment: .leading, spacing: 18) {
                            PaywallPoint(
                                symbol: "film.stack",
                                title: "Recap videos",
                                detail: "Turn a day's memories into a shareable video with music-video style crossfades."
                            )
                            PaywallPoint(
                                symbol: "calendar.badge.plus",
                                title: "Widen the memory range",
                                detail: "Look at nearby days too, so a trip that spanned a week still finds you."
                            )
                            PaywallPoint(
                                symbol: "moon.stars",
                                title: "Late-night grouping",
                                detail: "Keep an evening that ran past midnight together instead of split across two days."
                            )
                        }
                        .frame(maxWidth: 360)
                        .padding(.bottom, 32)

                        purchaseControls
                            .frame(maxWidth: 360)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 40)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            await store.loadProduct()
        }
        .alert(
            "Purchase",
            isPresented: Binding(
                get: { store.purchaseError != nil },
                set: { if !$0 { store.purchaseError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.purchaseError ?? "")
        }
        .alert(
            "Waiting for Approval",
            isPresented: Binding(
                get: { store.pendingApprovalNotice != nil },
                set: { if !$0 { store.pendingApprovalNotice = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.pendingApprovalNotice ?? "")
        }
        .onChange(of: store.isUnlocked) { _, unlocked in
            if unlocked { dismiss() }
        }
    }

    @ViewBuilder
    private var purchaseControls: some View {
        if store.isUnlocked {
            Label("Pro is unlocked", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
                .frame(height: 52)
        } else if let product = store.product {
            Button {
                Task { await store.purchase() }
            } label: {
                Group {
                    if store.purchaseInFlight {
                        ProgressView().tint(.white)
                    } else {
                        // displayPrice is already localised and currency-correct
                        // for the user's storefront; never format this ourselves.
                        Text("Unlock for \(product.displayPrice)")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(store.purchaseInFlight)

            Button("Restore Purchase") {
                Task { await store.restore() }
            }
            .font(.footnote.weight(.semibold))
            .padding(.top, 14)
            .disabled(store.restoreInFlight)

            Text("A one-time payment unlocks these features on every device signed in to your Apple Account.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
        } else if store.isLoadingProduct {
            ProgressView()
                .frame(height: 52)
        } else {
            VStack(spacing: 12) {
                Text("The Pro upgrade isn't available right now.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task { await store.loadProduct() }
                }
                .font(.footnote.weight(.semibold))
                Button("Restore Purchase") {
                    Task { await store.restore() }
                }
                .font(.footnote.weight(.semibold))
                .disabled(store.restoreInFlight)
            }
        }
    }
}

private struct PaywallPoint: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
