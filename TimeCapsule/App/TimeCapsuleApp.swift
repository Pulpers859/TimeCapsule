 import SwiftUI

@main
struct TimeCapsuleApp: App {
    @Environment(\.scenePhase) private var scenePhase

    // Owned at app scope so the `Transaction.updates` listener inside it lives
    // as long as the process does. A store created per-view would miss an
    // Ask to Buy approval or a refund that lands while that view is gone.
    @StateObject private var purchaseStore = PurchaseStore()

    init() {
        NotificationManager.shared.requestAndSchedule()

        // Every other sweep runs at the *start* of the next share or recap, so
        // a user who shares once and never again leaves that export sitting in
        // `tmp` indefinitely — and the share sheet's own 60-second cleanup is a
        // main-queue timer that never fires if the app is suspended or killed
        // first. Sweeping at launch is the only path that reclaims anything
        // left by a run that did not end cleanly.
        Task.detached(priority: .utility) {
            sweepStaleShareExports()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(purchaseStore)
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        NotificationManager.shared.refreshScheduleIfNeeded()
                        // Catches an entitlement that changed elsewhere while
                        // the app was backgrounded: a refund, a Family Sharing
                        // change, or a purchase made on another device.
                        Task { await purchaseStore.refreshEntitlement() }
                    }
                }
        }
    }
}
