import SwiftUI
import Photos
import PhotosUI
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = PhotoLibraryModel()
    @State private var isRequestingPhotoAccess = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            AppBackground()

            Group {
                switch model.authorizationStatus {
                case .notDetermined:
                    PermissionRequestView(
                        isRequesting: isRequestingPhotoAccess,
                        onRequestAccess: requestPhotoAccess
                    )

                case .denied, .restricted:
                    PermissionDeniedView()

                case .authorized, .limited:
                    VStack(spacing: 0) {
                        if model.authorizationStatus == .limited {
                            LimitedLibraryBanner(onManageAccess: openLimitedLibraryPicker)
                        }

                        ZStack {
                            if model.yearGroups.isEmpty {
                                if model.isLoading {
                                    SkeletonGalleryView()
                                } else {
                                    EmptyStateView(onOpenSettings: { showSettings = true })
                                }
                            } else {
                                TimeCapsuleView(
                                    yearGroups: model.yearGroups,
                                    onOpenSettings: { showSettings = true }
                                )
                            }
                        }
                    }

                @unknown default:
                    PermissionRequestView(
                        isRequesting: isRequestingPhotoAccess,
                        onRequestAccess: requestPhotoAccess
                    )
                }
            }
            // Swapping between skeleton, empty, and gallery is a full-screen
            // change; a cross-fade keeps it from snapping.
            .animation(.easeInOut(duration: 0.28), value: model.isLoading)
            .animation(.easeInOut(duration: 0.28), value: model.yearGroups.isEmpty)
        }
        .task {
            await model.refreshAuthorizationAndMemories()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    await model.refreshAuthorizationAndMemories()
                }
            }
        }
    }

    private func requestPhotoAccess() {
        guard !isRequestingPhotoAccess else { return }
        isRequestingPhotoAccess = true
        Task {
            await model.requestAccess()
            await MainActor.run {
                isRequestingPhotoAccess = false
            }
        }
    }

    private func openLimitedLibraryPicker() {
        guard let rootViewController = foregroundRootViewController(),
              let presentingViewController = topViewController(from: rootViewController) else {
            return
        }

        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presentingViewController)
        // PHPhotoLibraryChangeObserver refreshes when the limited selection changes.
    }

    private func foregroundRootViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows
            .first { $0.isKeyWindow }?
            .rootViewController
    }

    private func topViewController(from root: UIViewController?) -> UIViewController? {
        var top = root
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

struct PermissionRequestView: View {
    let isRequesting: Bool
    let onRequestAccess: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            BrandGlyph(systemName: "clock.arrow.circlepath", size: 104)
                .padding(.bottom, 28)

            Text("Attic")
                .font(.system(size: 34, design: .rounded).weight(.bold))
                .padding(.bottom, 8)

            Text("Photos and videos from this day, every year you've had a camera.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 300)
                .padding(.bottom, 34)

            VStack(alignment: .leading, spacing: 18) {
                // These two strings are a privacy claim, so they have to match
                // what the binary actually does.
                //
                // "Nothing is uploaded" was not true: a memory's coordinates are
                // sent to Apple Maps to name the place. And "when you open a
                // memory's details" described a lookup that actually fires
                // automatically as each photo comes into view, because the place
                // name appears in the caption while browsing, not only in the
                // details sheet.
                //
                // The feature is fine and worth keeping -- it uses coordinates
                // already stored in the photo, never the device's current
                // location, and asks for no location permission. It was only the
                // description that was wrong, so the description is what changed.
                PermissionPoint(
                    symbol: "iphone",
                    title: "Stays on your iPhone",
                    detail: "Your photos and videos are never uploaded. Finding your memories happens entirely on device."
                )
                PermissionPoint(
                    symbol: "location",
                    title: "Place names from Apple Maps",
                    detail: "When a memory has coordinates saved in it, those are sent to Apple Maps to name the place. Your current location is never used."
                )
                PermissionPoint(
                    symbol: "bell.badge",
                    title: "A gentle daily nudge",
                    detail: "One reminder a day, at a time you choose."
                )
            }
            .frame(maxWidth: 340)
            .padding(.bottom, 36)

            Spacer(minLength: 0)

            Button(action: onRequestAccess) {
                Group {
                    if isRequesting {
                        ProgressView().tint(.white)
                    } else {
                        Text("Allow Photo Access")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(isRequesting)
            .frame(maxWidth: 360)

            Text("You can change this anytime in iPhone Settings.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.top, 14)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 40)
    }
}

private struct PermissionPoint: View {
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

struct PermissionDeniedView: View {
    var body: some View {
        EmptyStateScaffold(
            symbol: "lock.fill",
            title: "Photos Access Required",
            message: "Attic needs access to your library to find memories from this day. Enable it in Settings → Privacy → Photos → Attic."
        ) {
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings")
                    .font(.headline)
                    .frame(minWidth: 200)
                    .frame(height: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        }
    }
}

struct LimitedLibraryBanner: View {
    let onManageAccess: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Limited Photos Access")
                    .font(.subheadline.weight(.semibold))
                Text("Attic can only see the photos you've picked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button("Manage", action: onManageAccess)
                .font(.footnote.weight(.semibold))
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .padding(.horizontal, TCMetrics.screenPadding)
        .padding(.bottom, 8)
    }
}

struct EmptyStateView: View {
    let onOpenSettings: () -> Void
    /// True only when *this day* actually holds memories that an exclusion is
    /// hiding — not merely that the user has ever hidden anything. The
    /// difference matters: the latter is permanent once set, so it would
    /// blame exclusions on every empty day forever after the first hidden
    /// photo, including dates where nothing was captured at all and widening
    /// the memory range is the only thing that would help.
    @State private var hiddenByExclusions = false

    /// Says "nothing was captured" only when that is actually true.
    ///
    /// Excluding one album can empty a whole day, and then telling the user
    /// nothing exists — and offering to widen the memory range, which will
    /// not bring any of it back — sends them looking for a problem in the
    /// wrong place. The hidden memories are recoverable, but only from a
    /// Settings screen they have no reason to think of unless something
    /// points at it.
    private var message: String {
        if hiddenByExclusions {
            return "Everything from this date is hidden by Featured Less Often. You can bring it back in Settings."
        }
        return MemoryWindow.dayWindow == 0
            ? "Nothing was captured on this date in previous years. Widening the memory range will look at nearby days too."
            : "Nothing turned up in the current memory range. Try widening it, or check back tomorrow."
    }

    var body: some View {
        EmptyStateScaffold(
            symbol: "calendar.badge.clock",
            title: "No Memories Today",
            message: message
        ) {
            Button(action: onOpenSettings) {
                Text(hiddenByExclusions ? "Open Settings" : "Adjust Memory Range")
                    .font(.headline)
                    .frame(minWidth: 220)
                    .frame(height: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        }
        .task { hiddenByExclusions = await dayIsEmptyOnlyBecauseOfExclusions() }
        // Restoring an exclusion from Settings usually repopulates the day
        // and replaces this view entirely, but not always — restoring a
        // place that has nothing on today's date leaves this on screen, and
        // the message would otherwise still blame the exclusion it just lost.
        .onReceive(NotificationCenter.default.publisher(for: .timeCapsulePhotosDidChange)) { _ in
            Task { hiddenByExclusions = await dayIsEmptyOnlyBecauseOfExclusions() }
        }
    }
}
