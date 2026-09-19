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

    /// Even sampling, then a single place of give so a pick can land on a
    /// photo worth keeping.
    ///
    /// Even spacing is what guarantees every year appears, so it stays the
    /// skeleton — a pick may move by one position at most, and never past its
    /// neighbours. That keeps the year spread intact while letting an obvious
    /// favourite displace the arbitrary frame that happened to fall on the
    /// sampled index.
    ///
    /// When the set is short enough that every item is already included, or
    /// the picks are adjacent, there is no slack and nothing moves.
    public static func sampleIndices(
        itemCount: Int,
        maximum: Int,
        preferring preferred: [Bool]
    ) -> [Int] {
        let base = sampleIndices(itemCount: itemCount, maximum: maximum)
        guard preferred.count == itemCount, base.count > 1 else { return base }

        var result = base
        for position in result.indices {
            let index = result[position]
            if preferred[index] { continue }

            // The lower bound reads from `result` (already settled) and the
            // upper bound from `base` (not yet visited). Together they keep the
            // picks strictly increasing no matter which way anything moves.
            let lowerBound = position > 0 ? result[position - 1] + 1 : 0
            let upperBound = position < base.count - 1 ? base[position + 1] - 1 : itemCount - 1

            for candidate in [index - 1, index + 1]
            where candidate >= lowerBound && candidate <= upperBound
                && candidate >= 0 && candidate < itemCount {
                if preferred[candidate] {
                    result[position] = candidate
                    break
                }
            }
        }
        return result
    }

    // MARK: - Slide motion

    /// A rectangle in the recap's own render space, in Doubles rather than
    /// `CGRect` so this stays compilable — and testable — on the non-Apple
    /// platforms the package CI builds on.
    public struct Rect: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// Smoothstep. Linear motion reads as a camera being dragged; easing both
    /// ends is what makes a slow push look deliberate rather than mechanical.
    public static func easedProgress(_ progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    public static func zoomFactor(from start: Double, to end: Double, progress: Double) -> Double {
        start + (end - start) * easedProgress(progress)
    }

    /// Scales `base` by `zoom` about a focus point, so that point stays put
    /// while everything else moves outward from it.
    ///
    /// `focusX`/`focusY` are normalised 0...1 within `base`, measured from its
    /// top-left. 0.5, 0.5 is a centred push; a face's centre pans toward the
    /// face instead.
    public static func framedRect(
        base: Rect,
        zoom: Double,
        focusX: Double = 0.5,
        focusY: Double = 0.5
    ) -> Rect {
        let safeZoom = max(zoom, 0.0001)
        let fx = min(max(focusX, 0), 1)
        let fy = min(max(focusY, 0), 1)
        return Rect(
            x: base.x + base.width * fx * (1 - safeZoom),
            y: base.y + base.height * fy * (1 - safeZoom),
            width: base.width * safeZoom,
            height: base.height * safeZoom
        )
    }

    /// How many frames a slide is on screen for, counting the crossfades it
    /// shares with its neighbours. Motion is normalised against this so a
    /// slide's push runs continuously from the moment it fades in to the
    /// moment it is gone, instead of freezing during the transitions.
    public static func visibleFrameCount(
        slideIndex: Int,
        slideCount: Int,
        holdFrames: Int,
        fadeFrames: Int
    ) -> Int {
        guard slideCount > 0, slideIndex >= 0, slideIndex < slideCount else { return 0 }
        var total = holdFrames
        if slideIndex > 0 { total += fadeFrames }
        if slideIndex < slideCount - 1 { total += fadeFrames }
        return total
    }
}
