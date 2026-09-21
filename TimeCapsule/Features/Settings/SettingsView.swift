import SwiftUI
import UserNotifications
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(NotificationPreferences.notificationsEnabledKey)
    private var notificationsEnabled = NotificationPreferences.defaultNotificationsEnabled
    @AppStorage(NotificationPreferences.notificationHourKey)
    private var notificationHour = NotificationPreferences.defaultNotificationHour
    @AppStorage(NotificationPreferences.notificationMinuteKey)
    private var notificationMinute = NotificationPreferences.defaultNotificationMinute
    // These two go to the shared suite because the widget reads them too.
    // Writing them to `.standard` while `MemoryWindow` reads the group would
    // leave both controls looking functional and doing nothing.
    @AppStorage(MemoryWindow.storageKey, store: AtticDefaults.shared)
    private var memoryDayWindow = MemoryWindow.defaultDayWindow
    @AppStorage(MemoryWindow.dayStartHourKey, store: AtticDefaults.shared)
    private var dayStartHour = MemoryWindow.defaultDayStartHour

    @EnvironmentObject private var purchaseStore: PurchaseStore

    @State private var notificationTime = Date()
    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var showPaywall = false

    /// Writes through to `NotificationManager` only when the value actually
    /// differs from what is stored.
    ///
    /// The picker used to be driven by `.onChange(of: notificationTime)`, but
    /// `notificationTime` is seeded from storage in `.task`, so simply *opening*
    /// Settings changed it (from "now" to the stored time) and triggered a full
    /// reschedule — the most expensive path in the app — even if the user only
    /// came to read the Good to Know section. Worse, on the spring-forward DST
    /// day `reminderDate` can fall back to "now", so that spurious write
    /// silently replaced the user's chosen reminder time with whatever time
    /// they happened to open Settings.
    ///
    /// A binding only fires on user interaction, so the seeding assignment no
    /// longer reaches the scheduler at all.
    private var notificationTimeBinding: Binding<Date> {
        Binding(
            get: { notificationTime },
            set: { newValue in
                notificationTime = newValue
                let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                guard components.hour != notificationHour || components.minute != notificationMinute else { return }
                NotificationManager.shared.updatePreferences(enabled: notificationsEnabled, notifyAt: newValue)
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SettingsBrandHeader()
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 16, trailing: 0))
                }

                Section {
                    if purchaseStore.isUnlocked {
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
                    } else {
                        ProLockedRow(
                            symbol: "calendar",
                            tint: .accentColor,
                            title: "Memory range",
                            subtitle: "Include nearby days, not just the exact date"
                        ) { showPaywall = true }
                    }

                    if purchaseStore.isUnlocked {
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
                    } else {
                        ProLockedRow(
                            symbol: "moon.stars",
                            tint: .indigo,
                            title: "New day starts at",
                            subtitle: "Keep an evening that ran past midnight together"
                        ) { showPaywall = true }
                    }

                    // Only ever appears when the App Group is missing, which
                    // on a correctly signed build it is not. Without it the
                    // failure is silent and reads as the widget being wrong:
                    // it falls back to a private store, so it shows the
                    // free-tier memory window and an empty exclusion list
                    // while the app shows the real ones. That surfaced as the
                    // widget reporting one memory fewer than the app would
                    // let you page through, with no way to tell why.
                    if !AtticDefaults.isAppGroupAvailable {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Widget can't read these settings")
                                    .font(.subheadline.weight(.semibold))
                                Text("It will show its own defaults, so its memory count can differ from the app's. This needs the app's App Group, which a re-signed build usually drops.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                } header: {
                    Text("Memories")
                } footer: {
                    // Describes the hour actually in effect. The stored value
                    // survives a lapsed entitlement but stops applying, so
                    // reading it raw here would promise behaviour the app is
                    // no longer performing.
                    Text(effectiveDayStartHour == 0
                        ? "Widen the memory range on days with few matches. Set a later day start so an event running past midnight stays grouped with the evening it began."
                        : "Photos taken before \(hourLabel(effectiveDayStartHour)) now count towards the previous day, so a night out stays in one place.")
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

                    DatePicker(selection: notificationTimeBinding, displayedComponents: .hourAndMinute) {
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
                                Text("Notifications are turned off for Attic in iPhone Settings.")
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
                    NavigationLink {
                        ManageExclusionsView()
                    } label: {
                        SettingsRowLabel(
                            symbol: "eye.slash",
                            tint: .gray,
                            title: "Featured Less Often",
                            subtitle: "Photos, albums, and places you've hidden"
                        )
                    }
                }

                Section {
                    SettingsRowLabel(
                        symbol: "trash",
                        tint: .red,
                        title: "Deletes are recoverable",
                        subtitle: "Items go to Recently Deleted in Photos"
                    )
                    // "Only when you ask" was not true: the place-name lookup
                    // fires automatically as each memory comes into view, not on
                    // request. Matching genuinely does stay on device, so the
                    // title stands; the subtitle now says what actually happens.
                    SettingsRowLabel(
                        symbol: "lock.shield",
                        tint: .green,
                        title: "Matching stays on device",
                        subtitle: "Place names come from Apple Maps when you open a memory"
                    )
                } header: {
                    Text("Good to Know")
                }

                Section {
                    if purchaseStore.isUnlocked {
                        SettingsRowLabel(
                            symbol: "checkmark.seal.fill",
                            tint: .green,
                            title: "Attic Pro",
                            subtitle: "Unlocked. Thank you."
                        )
                    } else {
                        Button {
                            showPaywall = true
                        } label: {
                            SettingsRowLabel(
                                symbol: "sparkles",
                                tint: .accentColor,
                                title: "Attic Pro",
                                subtitle: "Recap videos and a wider memory range"
                            )
                        }
                        // App Review requires a visible restore control for a
                        // non-consumable, reachable without buying anything.
                        Button("Restore Purchase") {
                            Task { await purchaseStore.restore() }
                        }
                        .disabled(purchaseStore.restoreInFlight)
                    }
                } header: {
                    Text("Upgrade")
                }
            }
            // The restore button above is reachable from here without ever
            // opening the paywall, and only the paywall was showing what
            // happened. So a restore from Settings was silent in every
            // outcome but success: "No previous purchase was found" was
            // written into `purchaseError` with nothing bound to display it,
            // and the button looked dead. Worse, the message *persisted* —
            // the next time the user opened the paywall, out of nowhere, it
            // greeted them with an alert about a restore they had attempted
            // minutes earlier on a different screen.
            .alert(
                "Restore Purchase",
                isPresented: Binding(
                    // Suppressed while the paywall is up, because it binds an
                    // alert to this same property. Two presentations driven by
                    // one flag across a sheet boundary means the one underneath
                    // tries to present while it is already presenting the
                    // sheet, and UIKit drops it. The paywall is the more
                    // specific context, so it wins whenever it is open.
                    get: { !showPaywall && purchaseStore.purchaseError != nil },
                    set: { if !$0 { purchaseStore.purchaseError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(purchaseStore.purchaseError ?? "")
            }
            .sheet(isPresented: $showPaywall) {
                // Passed explicitly rather than relying on the sheet inheriting
                // it: a missing EnvironmentObject is a crash, not a warning.
                PaywallView().environmentObject(purchaseStore)
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
        .onChange(of: memoryDayWindow) { _, _ in
            // One post refreshes both surfaces: the model refetches the gallery
            // and NotificationManager force-reschedules with the new counts.
            NotificationCenter.default.post(name: .timeCapsulePhotosDidChange, object: nil)
        }
        .onChange(of: dayStartHour) { _, _ in
            NotificationCenter.default.post(name: .timeCapsulePhotosDidChange, object: nil)
        }
        // Re-read on return from iPhone Settings. The denied banner offers a
        // button that sends the user there to turn notifications on, and this
        // sheet stays presented the whole time — so `.task` never runs again
        // and the warning, plus the button that led there, stayed on screen
        // after the user had already done what it asked.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await loadNotificationSettings() }
        }
    }

    /// The day-start hour the app is really using: the free default whenever
    /// Pro is not entitled, and clamped the same way `MemoryWindow` clamps it
    /// so a corrupt or legacy stored value cannot make this sentence promise
    /// an hour the app will not honour.
    private var effectiveDayStartHour: Int {
        guard purchaseStore.isUnlocked else { return MemoryWindow.defaultDayStartHour }
        return max(0, min(dayStartHour, 6))
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

            Text("Attic")
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
/// A Pro setting shown to someone who has not bought the unlock.
///
/// Deliberately a row that opens the paywall rather than a disabled control:
/// a greyed-out picker tells the user the feature is broken, while this tells
/// them it exists and how to get it.
private struct ProLockedRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                SettingsRowLabel(
                    symbol: symbol,
                    tint: tint,
                    title: title,
                    subtitle: subtitle
                )
                Spacer(minLength: 8)
                Text("PRO")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.accentColor.opacity(0.15))
                    )
            }
        }
        .accessibilityHint("Requires Attic Pro")
    }
}

/// Not `private`: `ManageExclusionsView` reuses it for the same tinted-tile
/// row treatment rather than duplicating it.
struct SettingsRowLabel: View {
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
