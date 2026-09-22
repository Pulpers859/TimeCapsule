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
    /// A burst is one press of the shutter and many `PHAsset`s — Photos shows
    /// it as a single item. Counting every frame would make Attic's number for
    /// a day disagree with the number the user can see in Photos, which is the
    /// one place they can check it.
    ///
    /// An asset with no `burstIdentifier` is not part of a burst and is always
    /// counted.
    static func isRepresentative(_ asset: PHAsset) -> Bool {
        asset.burstIdentifier == nil || asset.representsBurst
    }
}
