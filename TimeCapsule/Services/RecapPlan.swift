import Foundation

nonisolated public enum RecapPlan {
    public static func sampleIndices(itemCount: Int, maximum: Int) -> [Int] {
        guard itemCount > 0, maximum > 0 else { return [] }
        guard itemCount > maximum else { return Array(0..<itemCount) }
        guard maximum > 1 else { return [0] }

        let lastIndex = itemCount - 1
        return (0..<maximum).map { position in
            Int((Double(position) * Double(lastIndex) / Double(maximum - 1)).rounded())
        }
    }
}
