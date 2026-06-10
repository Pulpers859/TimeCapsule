import SwiftUI
import UserNotifications
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("TimeCapsule.notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("TimeCapsule.notificationHour") private var notificationHour = 9
    @AppStorage("TimeCapsule.notificationMinute") private var notificationMinute = 0
    @AppStorage(MemoryWindow.storageKey) private var memoryDayWindow = 0

    @State private var notificationTime = Date()
    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Memory range", selection: $memoryDayWindow) {
                        Text("Exact day").tag(0)
                        Text("±1 day").tag(1)
                        Text("±3 days").tag(3)
                    }
                } header: {
                    Text("Memories")
                } footer: {
                    Text("Widen the range to include photos taken within a few days of today's date in past years. Helpful on days with no exact matches.")
                }

                Section("Daily Reminder") {
                    Toggle("Daily memory notification", isOn: $notificationsEnabled)

                    DatePicker("Reminder time", selection: $notificationTime, displayedComponents: .hourAndMinute)
                        .disabled(!notificationsEnabled)

                    if authorizationStatus == .denied {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Notifications are currently turned off in iPhone Settings.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 4)
                    } else {
                        Text("The app refreshes your upcoming reminders whenever it becomes active so the count stays current.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Delete Behavior") {
                    Text("Deleting from Time Capsule moves items to the Photos app's Recently Deleted album, where they can still be recovered for a limited time.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            notificationTime = notificationDate(hour: notificationHour, minute: notificationMinute)
            await loadNotificationSettings()
        }
        .onChange(of: notificationsEnabled) { newValue in
            NotificationManager.shared.updatePreferences(enabled: newValue, notifyAt: notificationTime)
            Task { await loadNotificationSettings() }
        }
        .onChange(of: notificationTime) { newValue in
            NotificationManager.shared.updatePreferences(enabled: notificationsEnabled, notifyAt: newValue)
        }
        .onChange(of: memoryDayWindow) { _ in
            // One post refreshes both surfaces: the model refetches the gallery
            // and NotificationManager force-reschedules with the new counts.
            NotificationCenter.default.post(name: .timeCapsulePhotosDidChange, object: nil)
        }
    }

    private func loadNotificationSettings() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run {
            authorizationStatus = settings.authorizationStatus
        }
    }

    private func notificationDate(hour: Int, minute: Int) -> Date {
        let calendar = Calendar.current
        return calendar.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: Date()
        ) ?? Date()
    }
}
