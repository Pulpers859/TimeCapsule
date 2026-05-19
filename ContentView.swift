import SwiftUI
import Photos
import UIKit

struct ContentView: View {
    @StateObject private var model = PhotoLibraryModel()

    var body: some View {
        Group {
            switch model.authorizationStatus {
            case .notDetermined:
                PermissionRequestView()
                    .task { await model.requestAccess() }

            case .denied, .restricted:
                PermissionDeniedView()

            case .authorized, .limited:
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

            @unknown default:
                PermissionRequestView()
            }
        }
        .task {
            let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if current == .authorized || current == .limited {
                model.authorizationStatus = current
                await model.fetchOnThisDay()
            } else {
                model.authorizationStatus = current
            }
        }
    }
}

struct PermissionRequestView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Time Capsule")
                .font(.largeTitle.bold())
            Text("Needs access to your Photos to show memories from this day in past years.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            ProgressView()
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

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("No Memories Yet")
                .font(.title2.bold())
            Text("No photos were taken on this date in previous years.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
    }
}
