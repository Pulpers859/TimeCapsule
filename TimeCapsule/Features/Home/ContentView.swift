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

            Text("Time Capsule")
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
                PermissionPoint(
                    symbol: "iphone",
                    title: "Stays on your iPhone",
                    detail: "Matching happens on device. Nothing is uploaded."
                )
                PermissionPoint(
                    symbol: "location",
                    title: "Locations only on request",
                    detail: "Place names are looked up when you open a memory's details."
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
            message: "Time Capsule needs access to your library to find memories from this day. Enable it in Settings → Privacy → Photos → Time Capsule."
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
                Text("Time Capsule can only see the photos you've picked.")
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

    private var message: String {
        MemoryWindow.dayWindow == 0
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
                Text("Adjust Memory Range")
                    .font(.headline)
                    .frame(minWidth: 220)
                    .frame(height: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        }
    }
}
