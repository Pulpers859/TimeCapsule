import Photos
import Combine

@MainActor
class PhotoLibraryModel: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published var yearGroups: [YearGroup] = []
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published var isLoading = false

    private var cancellable: AnyCancellable?

    override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
        // Listen for delete events from multi-select or full-screen delete
        cancellable = NotificationCenter.default
            .publisher(for: .timeCapsulePhotosDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.fetchOnThisDay() }
            }
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            await self?.refreshAuthorizationAndMemories()
        }
    }

    func requestAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorizationStatus = status
        if status == .authorized || status == .limited {
            await fetchOnThisDay()
        }
    }

    func refreshAuthorizationAndMemories() async {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        authorizationStatus = current
        guard current == .authorized || current == .limited else {
            yearGroups = []
            isLoading = false
            return
        }
        await fetchOnThisDay()
    }

    func fetchOnThisDay() async {
        let shouldShowLoading = yearGroups.isEmpty
        if shouldShowLoading {
            isLoading = true
        }
        yearGroups = MemoryLibrary.yearGroups(on: Date())
        isLoading = false
    }
}
