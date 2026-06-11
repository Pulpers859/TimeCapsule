import Photos
import Combine

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
        yearGroups = MemoryLibrary.yearGroups(on: Date())
        isLoading = false
    }
}
