import Photos
import Combine

@MainActor
class PhotoLibraryModel: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published var yearGroups: [YearGroup] = []
    @Published var authorizationStatus: PHAuthorizationStatus
    @Published var isLoading: Bool

    private var cancellable: AnyCancellable?
    private var fetchGeneration = 0

    override init() {
        let initialStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        authorizationStatus = initialStatus
        isLoading = initialStatus == .authorized || initialStatus == .limited
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
        updateAuthorizationStatus(status)
        if status == .authorized || status == .limited {
            await fetchOnThisDay()
        }
    }

    func refreshAuthorizationAndMemories() async {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        updateAuthorizationStatus(current)
        guard current == .authorized || current == .limited else {
            fetchGeneration += 1
            yearGroups = []
            isLoading = false
            return
        }
        await fetchOnThisDay()
    }

    func fetchOnThisDay() async {
        fetchGeneration += 1
        let requestedGeneration = fetchGeneration
        let shouldShowLoading = yearGroups.isEmpty
        if shouldShowLoading {
            isLoading = true
        }
        await Task.yield()
        let queryDate = MemoryWindow.logicalDate(for: Date())
        let groups = await Task.detached(priority: .userInitiated) {
            MemoryLibrary.yearGroups(on: queryDate)
        }.value
        let currentAuthorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard requestedGeneration == fetchGeneration,
              currentAuthorization == .authorized || currentAuthorization == .limited else { return }
        yearGroups = groups
        isLoading = false
    }

    private func updateAuthorizationStatus(_ status: PHAuthorizationStatus) {
        guard authorizationStatus != status else { return }
        authorizationStatus = status
        NotificationCenter.default.post(name: .timeCapsulePhotoAuthorizationDidChange, object: nil)
    }
}
