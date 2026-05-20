import Photos
import UIKit
import SwiftUI
import Combine

struct YearGroup: Identifiable {
    let id: Int
    let year: Int
    let assets: [PHAsset]

    init(year: Int, assets: [PHAsset]) {
        self.id = year
        self.year = year
        self.assets = assets
    }

    var yearsAgo: Int {
        Calendar.current.component(.year, from: Date()) - year
    }

    var label: String {
        yearsAgo == 1 ? "1 Year Ago" : "\(yearsAgo) Years Ago"
    }
}

@MainActor
class PhotoLibraryModel: ObservableObject {
    @Published var yearGroups: [YearGroup] = []
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published var isLoading = false

    private var cancellable: AnyCancellable?

    init() {
        // Listen for delete events from multi-select or full-screen delete
        cancellable = NotificationCenter.default
            .publisher(for: .timeCapsulePhotosDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.fetchOnThisDay() }
            }
    }

    func requestAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorizationStatus = status
        if status == .authorized || status == .limited {
            await fetchOnThisDay()
        }
    }

    func fetchOnThisDay() async {
        let shouldShowLoading = yearGroups.isEmpty
        if shouldShowLoading {
            isLoading = true
        }
        let calendar = Calendar.current
        let today = Date()
        let currentYear = calendar.component(.year, from: today)
        let month = calendar.component(.month, from: today)
        let day = calendar.component(.day, from: today)

        var groups: [YearGroup] = []

        // Look back up to 20 years
        for year in stride(from: currentYear - 1, through: currentYear - 20, by: -1) {
            guard let startDate = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                  let endDate = calendar.date(byAdding: .day, value: 1, to: startDate) else { continue }

            let fetchOptions = PHFetchOptions()
            fetchOptions.predicate = NSPredicate(
                format: "creationDate >= %@ AND creationDate < %@",
                startDate as NSDate,
                endDate as NSDate
            )
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

            let result = PHAsset.fetchAssets(with: fetchOptions)
            if result.count > 0 {
                var assets: [PHAsset] = []
                result.enumerateObjects { asset, _, _ in
                    if asset.mediaType == .image || asset.mediaType == .video {
                        assets.append(asset)
                    }
                }
                if !assets.isEmpty {
                    groups.append(YearGroup(year: year, assets: assets))
                }
            }
        }

        yearGroups = groups
        isLoading = false
    }
}

// Helper to load UIImage from PHAsset. Callers can choose whether they want a
// cropped thumbnail-style result or a full-frame display image.
func loadImage(
    from asset: PHAsset,
    targetSize: CGSize = CGSize(width: 800, height: 800),
    contentMode: PHImageContentMode = .aspectFill
) async -> UIImage? {
    await withCheckedContinuation { continuation in
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        var didResume = false

        _ = manager.requestImage(for: asset, targetSize: targetSize, contentMode: contentMode, options: options) { image, info in
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if isDegraded { return }
            if didResume { return }
            didResume = true
            continuation.resume(returning: image)
        }
    }
}
