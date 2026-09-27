import Foundation

/// How the widget turns a day's memories into a rotation.
///
/// Framework-free on purpose, so the choosing and the timing are tested on
/// every CI run — Windows included — instead of only ever being seen on a
/// home screen.
///
/// The shape: twelve photos, thirty minutes each, six hours in all. When the
/// six hours run out the widget asks for a new timeline and draws a fresh
/// twelve, so a day shows up to four different sets rather than one set on
/// a loop. Four reloads a day is well inside what iOS budgets a widget.
///
/// Twelve is also about the ceiling. Every photo in a timeline is fetched
/// before the first one is shown, inside an extension iOS kills at about
/// 30 MB. So each photo is cropped to what the tile shows, written to a file
/// and dropped from memory before the next is fetched; the timeline holds
/// file locations, not pictures. And `shouldLoadAnother` stops early if
/// memory runs low anyway, so a bad day costs photos rather than the widget.
nonisolated enum WidgetRotation {
    static let slotCount = 12
    static let slotInterval: TimeInterval = 30 * 60

    // MARK: - Memory

    /// The limit Apple's WidgetKit engineers state for a widget extension,
    /// and the one its crash reports name (`limit=30 MB`).
    ///
    /// Assumed rather than asked for, because asking does not work
    /// everywhere. `os_proc_available_memory` was the first version of this
    /// check, and on a sideloaded build it reported about 6,600 MB free —
    /// the whole phone, not the widget's allowance — so a check against it
    /// could never trip. Seen on device. Used only when the system's figure
    /// is not believable; see `headroom`.
    static let assumedLimitBytes = 30 * 1024 * 1024

    /// Headroom below which no further photo is fetched, at the least.
    ///
    /// Measured on device, one fetch cost 7.3 MB at its peak — more than the
    /// 6 MB this used to be, so it could not have protected against the
    /// very fetch it was for. Ten covers that; `shouldLoadAnother` raises it
    /// further when a build sees a costlier photo.
    static let memoryFloorBytes = 10 * 1024 * 1024

    /// The largest limit reported by the system that is believed.
    ///
    /// A widget extension's real limit is tens of megabytes. On a sideloaded
    /// build the system has also reported about 6,600 MB — the whole phone —
    /// which is not a limit anything will enforce on an App Store install,
    /// so a figure past this falls back to `assumedLimitBytes`.
    static let believableLimitBytes = 1024 * 1024 * 1024

    /// Memory left before iOS kills the extension, or `nil` if unknown.
    ///
    /// The system's own figure (`os_proc_available_memory`) when the limit
    /// it implies is believable: it is the limit this process actually has,
    /// and on device it read 60 MB where the assumption said 30 — the
    /// assumption is what cut the wide widget to a single photo. Otherwise
    /// the extension's own use against `assumedLimitBytes`.
    ///
    /// Either input is zero when unknown: the system reports zero for no
    /// limit, and a footprint that could not be read comes back as zero.
    static func headroom(reportedAvailable: Int, footprint: Int) -> Int? {
        if reportedAvailable > 0, footprint + reportedAvailable <= believableLimitBytes {
            return reportedAvailable
        }
        if footprint > 0 { return assumedLimitBytes - footprint }
        return nil
    }

    // MARK: - Settling

    /// Memory left over from the previous build that is worth waiting out.
    static let settleMarginBytes = 4 * 1024 * 1024
    /// The longest a build waits for it.
    static let settleLimit: TimeInterval = 2

    /// Whether a build should wait longer before fetching.
    ///
    /// Seen on device: fetching leaves memory behind that the system frees
    /// only later — a process 18 builds old started its next at 7.9 MB — but
    /// the small and wide widgets are built back to back, so the second
    /// started on top of the first's leftovers and fit one photo. Waiting
    /// briefly for memory to come back near the lowest a build has started
    /// at in this process lets the second begin clean.
    static func shouldKeepSettling(current: Int, lowestStart: Int, waited: TimeInterval) -> Bool {
        waited < settleLimit && current > lowestStart + settleMarginBytes
    }

    /// Whether to fetch one more photo.
    ///
    /// The first photo is always fetched: a widget with no photo at all
    /// reads as broken, and at that point nothing else is held. Unknown
    /// headroom is not a reason to stop either.
    ///
    /// The headroom asked for is the floor, or half again the costliest
    /// photo this build has fetched, whichever is more: a day whose photos
    /// are large needs more room than a fixed figure guessed in advance.
    static func shouldLoadAnother(
        loadedSoFar: Int,
        headroomBytes: Int?,
        largestPhotoCost: Int = 0
    ) -> Bool {
        if loadedSoFar == 0 { return true }
        guard let headroomBytes else { return true }
        return headroomBytes >= max(memoryFloorBytes, largestPhotoCost * 3 / 2)
    }

    // MARK: - Sharpness

    /// How many candidates to draw for each photo slot.
    ///
    /// Some photos come back soft — the full photo is in iCloud and only a
    /// small preview is on the phone, which a widget cannot download past —
    /// and those are passed over for another from the same day. Two per slot
    /// is enough spare for an ordinary day without making every reload fetch
    /// twice as much.
    static let candidatesPerSlot = 2

    /// The least of the requested size a returned photo may be and still
    /// count as sharp. Below this it is being stretched by a third or more
    /// to fill its space, which is where softness starts to show.
    static let sharpnessThreshold = 0.75

    static func isSharp(
        returnedWidth: Double,
        returnedHeight: Double,
        targetWidth: Double,
        targetHeight: Double
    ) -> Bool {
        guard targetWidth > 0, targetHeight > 0 else { return true }
        let coverage = min(returnedWidth / targetWidth, returnedHeight / targetHeight)
        return coverage >= sharpnessThreshold
    }

    /// Which loaded photos to rotate through: the sharp ones, in the order
    /// picked, up to `limit`. Soft ones only when there is no sharp one at
    /// all — a soft photo beats an empty widget, but not a sharp photo.
    static func rotation<Item>(
        _ loaded: [(item: Item, isSharp: Bool)],
        limit: Int
    ) -> [Item] {
        let sharp = loaded.filter { $0.isSharp }.map { $0.item }
        let chosen = sharp.isEmpty ? loaded.map { $0.item } : sharp
        return Array(chosen.prefix(limit))
    }

    // MARK: - Photo files

    /// How long a batch of photo files is kept.
    ///
    /// A timeline lives at most six hours before it is replaced, so twelve
    /// is double that — room for iOS postponing a reload — without letting
    /// old batches pile up. Deleting by age rather than "everything but the
    /// newest batch" is deliberate: the small and wide widgets build their
    /// timelines separately, and newest-only would let one delete the
    /// other's photos while they are on screen.
    static let photoFileLifetime: TimeInterval = 12 * 3600

    static func isStale(modified: Date, now: Date) -> Bool {
        now.timeIntervalSince(modified) > photoFileLifetime
    }

    /// A uniformly random `capacity` of everything offered to it, holding no
    /// more than `capacity` at any time.
    ///
    /// This is what lets the widget choose at random from a day with three
    /// hundred photos without keeping three hundred of them. The previous
    /// cap kept the *first* few of each year by capture time, so a busy day
    /// only ever showed its first hour.
    nonisolated struct Reservoir<Element> {
        let capacity: Int
        private(set) var elements: [Element] = []
        private(set) var seen = 0

        init(capacity: Int) {
            self.capacity = max(capacity, 0)
        }

        /// Algorithm R: the `n`th element offered replaces a random kept one
        /// with probability `capacity / n`, which leaves every element
        /// equally likely to be kept however long the stream is.
        mutating func offer(_ element: Element, using generator: inout some RandomNumberGenerator) {
            seen += 1
            if elements.count < capacity {
                elements.append(element)
            } else if capacity > 0 {
                let slot = Int.random(in: 0..<seen, using: &generator)
                if slot < capacity {
                    elements[slot] = element
                }
            }
        }
    }

    /// Up to `limit` items, spread across years, in random order.
    ///
    /// One from each year first, round and round, so twelve slots over a
    /// day with memories from five years show all five before any year
    /// repeats. Then shuffled, so the newest year is not always the first
    /// thing on the home screen.
    ///
    /// - Parameter years: each year's candidates, already randomly chosen.
    static func picks<Item>(
        from years: [[Item]],
        limit: Int,
        using generator: inout some RandomNumberGenerator
    ) -> [Item] {
        var picks: [Item] = []
        var round = 0
        while picks.count < limit {
            var tookAny = false
            for year in years where round < year.count && picks.count < limit {
                picks.append(year[round])
                tookAny = true
            }
            guard tookAny else { break }
            round += 1
        }
        picks.shuffle(using: &generator)
        return picks
    }

    /// When each pick is shown, and when to ask for the next timeline.
    ///
    /// Fewer picks than slots cycle through again, so a day with three
    /// photos still fills six hours instead of ending after ninety minutes
    /// and spending a reload every hour and a half. A single photo gets a
    /// single entry; repeating it would only redraw the same thing.
    ///
    /// Nothing is scheduled at or past `dayBoundary`: the photos belong to
    /// today, and after the boundary they would be yesterday's. The reload
    /// happens at whichever comes first, the end of the rotation or the
    /// boundary.
    static func schedule<Item>(
        _ picks: [Item],
        from now: Date,
        dayBoundary: Date
    ) -> (entries: [(date: Date, item: Item)], reload: Date) {
        let rotationEnd = now.addingTimeInterval(Double(slotCount) * slotInterval)
        let reload = min(rotationEnd, dayBoundary)
        guard !picks.isEmpty else { return ([], reload) }

        let slots = picks.count == 1 ? 1 : slotCount
        var entries: [(date: Date, item: Item)] = []
        for slot in 0..<slots {
            let date = now.addingTimeInterval(Double(slot) * slotInterval)
            // The first entry is always kept, even if the boundary is only
            // seconds away, so the widget is never handed an empty timeline.
            if slot > 0 && date >= dayBoundary { break }
            entries.append((date: date, item: picks[slot % picks.count]))
        }
        return (entries, reload)
    }
}
