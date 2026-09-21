import Foundation

/// How a video's running time is written, everywhere it is written.
///
/// There were three copies of this: the grid's duration badge, the
/// full-screen info sheet's Duration row, and the playback scrubber's
/// end labels. They had drifted apart in two ways that mattered.
///
/// Only the scrubber's copy checked that the value was finite before
/// handing it to `Int(_:)`, which traps on NaN and on infinity rather
/// than producing a wrong number. The same trap, reached through a
/// malformed EXIF rational, already crashed this app once.
///
/// None of them handled an hour. `String(format: "%d:%02d", total / 60,
/// total % 60)` writes a 75-minute recording as "75:00" — not wrong so
/// much as not how anyone writes a duration, and long videos are exactly
/// the ones whose length a person wants to read before tapping.
///
/// Pure Foundation on purpose: it lives in the package target, so the
/// tests actually run in CI on macOS and on Windows, which is not true
/// of anything that has to import Photos or SwiftUI.
nonisolated public enum MediaDuration {
    /// `seconds` as `m:ss`, or `h:mm:ss` once it reaches an hour.
    ///
    /// Anything not finite, negative, or past the range an `Int` can hold
    /// is written as "0:00" rather than trapping. A duration is a caption;
    /// it is never worth a crash.
    public static func formatted(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 1, seconds < 86_400 * 365 else { return "0:00" }

        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60

        if hours > 0 {
            return "\(hours):\(twoDigits(minutes)):\(twoDigits(remainder))"
        }
        return "\(minutes):\(twoDigits(remainder))"
    }

    /// Built by hand rather than with `String(format: "%02d", …)`.
    ///
    /// `%d` is a 32-bit conversion and `Int` is 64-bit, so every such call
    /// relies on the platform's `CVarArg` encoding and the argument staying
    /// small. That holds here, but this target is also compiled for Windows
    /// by CI, and a zero-padded integer is not worth depending on a
    /// `Foundation` format implementation for on three platforms.
    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
