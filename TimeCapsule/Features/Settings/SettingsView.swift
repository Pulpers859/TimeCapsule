import SwiftUI
import UserNotifications
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(NotificationPreferences.notificationsEnabledKey)
    private var notificationsEnabled = NotificationPreferences.defaultNotificationsEnabled
    @AppStorage(NotificationPreferences.notificationHourKey)
    private var notificationHour = NotificationPreferences.defaultNotificationHour
    @AppStorage(NotificationPreferences.notificationMinuteKey)
    private var notificationMinute = NotificationPreferences.defaultNotificationMinute
    @AppStorage(MemoryWindow.storageKey)
    private var memoryDayWindow = MemoryWindow.defaultDayWindow
    @AppStorage(MemoryWindow.dayStartHourKey)
    private var dayStartHour = MemoryWindow.defaultDayStartHour

    @State private var notificationTime = Date()
    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SettingsBrandHeader()
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 16, trailing: 0))
                }

                Section {
                    Picker(selection: $memoryDayWindow) {
                        Text("Exact day").tag(0)
                        Text("±1 day").tag(1)
                        Text("±3 days").tag(3)
                    } label: {
                        SettingsRowLabel(
                            symbol: "calendar",
                            tint: .accentColor,
                            title: "Memory range",
                            subtitle: "How many nearby days to include"
                        )
                    }

                    Picker(selection: $dayStartHour) {
                        Text("Midnight").tag(0)
                        Text("2 AM").tag(2)
                        Text("3 AM").tag(3)
                        Text("4 AM").tag(4)
                        Text("5 AM").tag(5)
                        Text("6 AM").tag(6)
                    } label: {
                        SettingsRowLabel(
                            symbol: "moon.stars",
                            tint: .indigo,
                            title: "New day starts at",
                            subtitle: "Keeps late nights with the evening before"
                        )
                    }
                } header: {
                    Text("Memories")
                } footer: {
                    Text(dayStartHour == 0
                        ? "Widen the memory range on days with few matches. Set a later day start so an event running past midnight stays grouped with the evening it began."
                        : "Photos taken before \(hourLabel(dayStartHour)) now count towards the previous day, so a night out stays in one place.")
                }

                Section {
                    Toggle(isOn: $notificationsEnabled) {
                        SettingsRowLabel(
                            symbol: "bell.badge",
                            tint: .orange,
                            title: "Daily reminder",
                            subtitle: "One nudge when memories are waiting"
                        )
                    }

                    DatePicker(selection: $notificationTime, displayedComponents: .hourAndMinute) {
                        SettingsRowLabel(
                            symbol: "clock",
                            tint: .teal,
                            title: "Reminder time",
                            subtitle: nil
                        )
                    }
                    .disabled(!notificationsEnabled)
                    .opacity(notificationsEnabled ? 1 : 0.5)

                    if authorizationStatus == .denied {
                        VStack(alignment: .leading, spacing: 12) {
                            Label {
                                Text("Notifications are turned off for Time Capsule in iPhone Settings.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }

                            Button("Open iPhone Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .font(.subheadline.weight(.semibold))
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                        }
                        .padding(.vertical, 6)
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    if authorizationStatus != .denied {
                        Text("Upcoming reminders refresh whenever you open the app, so the memory count stays accurate.")
                    }
                }

                Section {
                    SettingsRowLabel(
                        symbol: "trash",
                        tint: .red,
                        title: "Deletes are recoverable",
                        subtitle: "Items go to Recently Deleted in Photos"
                    )
                    SettingsRowLabel(
                        symbol: "lock.shield",
                        tint: .green,
                        title: "Matching stays on device",
                        subtitle: "Locations are looked up only when you ask"
                    )
                } header: {
                    Text("Good to Know")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                }
            }
        }
        .task {
            notificationTime = notificationDate(hour: notificationHour, minute: notificationMinute)
            await loadNotificationSettings()
        }
        .onChange(of: notificationsEnabled) { _, newValue in
            NotificationManager.shared.updatePreferences(enabled: newValue, notifyAt: notificationTime)
            Task { await loadNotificationSettings() }
        }
        .onChange(of: notificationTime) { _, newValue in
            NotificationManager.shared.updatePreferences(enabled: notificationsEnabled, notifyAt: newValue)
        }
        .onChange(of: memoryDayWindow) { _, _ in
            // One post refreshes both surfaces: the model refetches the gallery
            // and NotificationManager force-reschedules with the new counts.
            NotificationCenter.default.post(name: .timeCapsulePhotosDidChange, object: nil)
        }
        .onChange(of: dayStartHour) { _, _ in
            NotificationCenter.default.post(name: .timeCapsulePhotosDidChange, object: nil)
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        hour == 0 ? "midnight" : "\(hour) AM"
    }

    private func loadNotificationSettings() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run {
            authorizationStatus = settings.authorizationStatus
        }
    }

    private func notificationDate(hour: Int, minute: Int) -> Date {
        NotificationPreferences.reminderDate(hour: hour, minute: minute)
    }
}

/// Small branded masthead so Settings reads as part of the app rather than a
/// stock system form.
private struct SettingsBrandHeader: View {
    var body: some View {
        VStack(spacing: 12) {
            BrandGlyph(systemName: "clock.arrow.circlepath", size: 64)

            Text("Time Capsule")
                .font(.system(.title3, design: .rounded, weight: .bold))

            Text("This day, every year you've had a camera.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// The tinted-tile row treatment the system Settings app uses. It costs almost
/// nothing and does most of the work of making a form feel finished.
private struct SettingsRowLabel: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
