import SwiftUI
import Photos
import PhotosUI
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = PhotoLibraryModel()
    @State private var isRequestingPhotoAccess = false

    var body: some View {
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
                                LoadingView()
                            } else {
                                EmptyStateView()
                            }
                        } else {
                            TimeCapsuleView(yearGroups: model.yearGroups)
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
        .task {
            await model.refreshAuthorizationAndMemories()
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
        Task {
            try? await Task.sleep(nanoseconds: 750_000_000)
            await model.refreshAuthorizationAndMemories()
        }
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
        VStack(spacing: 18) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Time Capsule")
                .font(.largeTitle.bold())
            Text("Time Capsule finds photos and videos from this date in past years. Your library stays on device.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Button {
                onRequestAccess()
            } label: {
                if isRequesting {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text("Allow Photo Access")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRequesting)
        }
        .padding()
    }
}

struct PermissionDeniedView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Photos Access Required")
                .font(.title2.bold())
            Text("Please enable Photos access in Settings → Privacy → Photos → Time Capsule.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

struct LoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Finding your memories…")
                .foregroundStyle(.secondary)
        }
    }
}

struct LimitedLibraryBanner: View {
    let onManageAccess: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.badge.plus")
                .font(.title3)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Limited Photos Access")
                    .font(.subheadline.weight(.semibold))
                Text("Add more photos to Time Capsule without leaving the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button("Manage", action: onManageAccess)
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("No Memories Yet")
                .font(.title2.bold())
            Text("No photos or videos were taken on this date in previous years.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
    }
}
