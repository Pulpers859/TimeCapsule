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
