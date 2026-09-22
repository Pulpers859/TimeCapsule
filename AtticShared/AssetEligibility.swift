import Photos

/// What Attic is able to show at all.
///
/// One rule, in one place, because two places that must agree eventually do
/// not. `MemoryLibrary` decides which assets count as memories and
/// `DayContents` decides which count as part of a day; those are different
/// questions with different answers, but "can the viewer render this" is the
/// same question for both, and if they disagreed the day grid could offer a
/// tile the pager cannot open.
nonisolated enum AssetEligibility {
    /// The two media types the full-screen viewer knows how to display.
    ///
    /// Audio assets exist in PhotoKit and cannot be rendered; `.unknown` is
    /// whatever a future iOS adds.
    static func isBrowsable(_ asset: PHAsset) -> Bool {
        asset.mediaType == .image || asset.mediaType == .video
    }

    /// Whether this asset should be counted once rather than forty times.
    ///
    /// A burst is one press of the shutter and many `PHAsset`s, and Photos
    /// shows it as a single item. A count that said 47 against Photos' 12
    /// would look like a bug in the one number a user can actually check.
    ///
    /// Belt and braces, not the mechanism. `PHFetchOptions.includeAllBurstAssets`
    /// defaults to false, so a fetch already returns only the representative
    /// frame — which means the memory fetch and the day fetch have never
    /// disagreed about this, contrary to what an audit of the day browser
    /// concluded and what the commit that landed it claimed. This survives as
    /// a guard for the day someone sets that option, and is otherwise a no-op.
    static func isRepresentative(_ asset: PHAsset) -> Bool {
        asset.burstIdentifier == nil || asset.representsBurst
    }
}
