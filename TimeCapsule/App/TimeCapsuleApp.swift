import SwiftUI

@main
struct TimeCapsuleApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        NotificationManager.shared.requestAndSchedule()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        NotificationManager.shared.refreshScheduleIfNeeded()
                    }
                }
        }
    }
}
