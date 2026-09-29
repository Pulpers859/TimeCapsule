import Foundation

/// Which of the names Apple Maps offers for a place to show.
///
/// Maps can answer a field with an empty string rather than none at all.
/// Seen on device for a photo taken on a plane at Logan Airport: the viewer
/// caption read "1 year ago ·" with nothing after the dot, and the info
/// sheet showed a Location row with no value. An empty name had been taken
/// as a name, which also stopped the lookup from trying Maps' other ones.
///
/// Framework-free, so the rule is tested on every CI run.
nonisolated enum PlaceNameText {
    /// The first candidate with something in it, trimmed; `nil` if none has.
    static func best(_ candidates: [String?]) -> String? {
        for candidate in candidates {
            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { continue }
            return trimmed
        }
        return nil
    }
}
