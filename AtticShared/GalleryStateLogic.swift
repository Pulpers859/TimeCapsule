import Foundation

nonisolated public enum GalleryStateLogic {
    public static func prunedSelection(_ selectedIDs: Set<String>, visibleIDs: Set<String>) -> Set<String> {
        selectedIDs.intersection(visibleIDs)
    }

    public static func indexAfterDeleting(
        identifier: String,
        from identifiers: [String],
        currentIndex: Int
    ) -> Int? {
        guard let removedIndex = identifiers.firstIndex(of: identifier) else {
            return identifiers.isEmpty ? nil : min(max(currentIndex, 0), identifiers.count - 1)
        }
        let remainingCount = identifiers.count - 1
        guard remainingCount > 0 else { return nil }

        if removedIndex < currentIndex {
            return max(currentIndex - 1, 0)
        }
        return min(currentIndex, remainingCount - 1)
    }
}
