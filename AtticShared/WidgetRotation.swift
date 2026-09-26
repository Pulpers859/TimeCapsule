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
/// before the first one is shown, inside an extension with a small memory
/// limit; the widget keeps each one compressed until it is drawn so that
/// twelve costs roughly what four used to.
nonisolated enum WidgetRotation {
    static let slotCount = 12
    static let slotInterval: TimeInterval = 30 * 60

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
