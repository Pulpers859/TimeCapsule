import Foundation

/// Single source of truth for how many days around today's date count as
/// "this day" when looking back at past years. Both the gallery fetch
/// (`PhotoLibraryModel.fetchOnThisDay()`) and the notification count
/// (`MemoryLibrary.count(on:)`) must use this so the two
/// surfaces never disagree.
nonisolated enum MemoryWindow {
    static let storageKey = "TimeCapsule.memoryDayWindow"
    static let dayStartHourKey = "TimeCapsule.dayStartHour"
    static let defaultDayWindow = 0
    static let defaultDayStartHour = 0

    static func clampedDayWindow(_ value: Int) -> Int {
        max(0, min(value, 7))
    }

    /// The calendar every anniversary calculation runs in.
    ///
    /// Deliberately not `Calendar.current`. iOS lets someone pick Japanese,
    /// Buddhist, Hebrew, Islamic or Persian as their system calendar from
    /// Settings, and `Calendar.current` then reports year numbers in that
    /// calendar — which breaks two assumptions this file is built on.
    ///
    /// The first is that a year number is absolute. Under the Japanese
    /// calendar `component(.year, from: Date())` returns the year *within the
    /// current era*, so in 2026 it is 8, and the twenty-year lookback strode
    /// from 7 down to -12. The second is that subtracting two year numbers
    /// gives an elapsed number of years. It does not across an era boundary:
    /// a 2018 photo reads as Heisei 30, today reads as Reiwa 8, and
    /// `8 - 30` is -22. Every caller of `yearsAgo` guards on `> 0`, so that
    /// did not show up as a negative number on screen — it silently removed
    /// the "N years ago" caption, the info-sheet strapline and the share
    /// caption for every memory older than the era change.
    ///
    /// Anchoring the arithmetic to a proleptic Gregorian year removes both,
    /// and keeps the user's time zone so nothing about which instant a day
    /// starts at changes. For someone already on Gregorian this returns
    /// their own calendar untouched, so it is exactly a no-op for them.
    ///
    /// Presentation is a separate question and is *not* forced Gregorian:
    /// `YearGroup.displayYear` formats through the user's own calendar, so a
    /// Buddhist-calendar user still reads 2568.
    static func anniversaryCalendar(_ calendar: Calendar = .current) -> Calendar {
        guard calendar.identifier != .gregorian else { return calendar }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        gregorian.locale = calendar.locale
        return gregorian
    }

    /// 0 = exact day only. Clamped so a corrupt default can't explode fetches.
    ///
    /// Read from the shared suite, not `.standard`, so the widget resolves the
    /// same window the gallery does.
    ///
    /// Returns the free default when Pro is not entitled, rather than the
    /// stored value being wiped when an entitlement goes away. Gating at the
    /// point of use is what makes a lapsed entitlement recoverable: the
    /// user's chosen value survives, it simply stops applying, and buying
    /// again — or a failed verification correcting itself — restores it with
    /// nothing to re-enter.
    static var dayWindow: Int {
        guard AtticDefaults.isProEntitled else { return defaultDayWindow }
        return clampedDayWindow(
            AtticDefaults.shared.object(forKey: storageKey) as? Int ?? defaultDayWindow
        )
    }

    /// How far back Attic looks with Pro: effectively the whole history of
    /// anyone who has owned a phone camera.
    static let fullLookbackYears = 20

    /// How far back the free version looks.
    ///
    /// This is the paywall. The three original Pro features — recap videos,
    /// nearby days and a custom day start — were real but small, and the free
    /// version did the whole job without them, so almost nobody would have
    /// had a reason to pay. The value of an on-this-day app is depth: the
    /// photo from two years ago is nice, the one from ten years ago is why
    /// people stop scrolling. So depth is what Pro sells.
    ///
    /// Two years rather than three so the locked years show up sooner and more
    /// often, which is what makes the gate sell rather than merely restrict.
    static let freeLookbackYears = 2

    /// How many past years to search, for a given entitlement. Pure, so the
    /// rule is testable without StoreKit or shared defaults.
    static func lookback(isPro: Bool) -> Int {
        isPro ? fullLookbackYears : freeLookbackYears
    }

    /// How many past years the current user can see.
    ///
    /// Gated here, beside `dayWindow` and `dayStartHour`, for the same reason
    /// those are: at the point of use, so a lapsed or unverified entitlement
    /// narrows what is shown without destroying anything.
    ///
    /// Read in exactly one place, `MemoryLibrary.anniversaryRanges`, and every
    /// count in the app goes through that — the gallery, the widget and the
    /// notification schedule. That is what keeps them agreeing. Gating the
    /// gallery alone would have had the widget showing a photo from 2016 that
    /// the app then refused to open, and a notification promising twelve
    /// memories to someone who could see three.
    static var lookbackYears: Int {
        lookback(isPro: AtticDefaults.isProEntitled)
    }

    /// Hour (0–6) at which a new TimeCapsule "day" begins. Photos taken before
    /// this hour are attributed to the previous calendar day, so an event that
    /// runs past midnight stays grouped under the evening it started.
    /// 0 = midnight (default, preserves prior behavior).
    ///
    /// Gated on the entitlement for the same reason as `dayWindow`.
    static var dayStartHour: Int {
        guard AtticDefaults.isProEntitled else { return defaultDayStartHour }
        return max(0, min(AtticDefaults.shared.object(forKey: dayStartHourKey) as? Int ?? defaultDayStartHour, 6))
    }

    /// Returns the "logical date" for a given wall-clock time.
    /// When the clock reads before `dayStartHour`, the user is still in the
    /// previous evening — shift the reference date back one day so the gallery
    /// shows that evening's memories rather than the new calendar day's (which
    /// hasn't really started yet). Returns `date` unchanged when `dayStartHour == 0`.
    static func logicalDate(
        for date: Date,
        dayStartHour: Int = MemoryWindow.dayStartHour,
        calendar: Calendar = .current
    ) -> Date {
        let calendar = anniversaryCalendar(calendar)
        let startHour = max(0, min(dayStartHour, 6))
        guard startHour > 0 else { return date }
        let hour = calendar.component(.hour, from: date)
        guard hour < startHour else { return date }
        return calendar.date(byAdding: .day, value: -1, to: date) ?? date
    }

    /// How many years back a memory is, measured the way an "on this day" app
    /// means it: the difference between calendar years, not elapsed duration.
    ///
    /// This distinction is the whole point of the helper. `Calendar`'s
    /// `dateComponents([.year], from:to:)` answers "how many whole years have
    /// *passed*", so a photo taken at 4:59 PM on Aug 3 2024, viewed at 8:03 AM
    /// on Aug 3 2026, comes back as 1 — the second anniversary is still nine
    /// hours away. The gallery groups that same photo under 2024 and labels it
    /// "2 Years Ago", so any surface using elapsed duration silently disagrees
    /// with the grid it was opened from, and only when the current time of day
    /// happens to fall earlier than the capture time.
    ///
    /// Both dates go through `logicalDate` so the answer matches how
    /// `range(for:anniversaryYear:)` attributes assets to a year: a photo taken
    /// just after midnight on Jan 1 belongs to the previous evening, and so to
    /// the previous year, whenever `dayStartHour` is non-zero.
    static func yearsAgo(
        for date: Date,
        relativeTo reference: Date = Date(),
        dayStartHour: Int = MemoryWindow.dayStartHour,
        calendar: Calendar = .current
    ) -> Int {
        let calendar = anniversaryCalendar(calendar)
        let referenceYear = calendar.component(
            .year,
            from: logicalDate(for: reference, dayStartHour: dayStartHour, calendar: calendar)
        )
        let memoryYear = calendar.component(
            .year,
            from: logicalDate(for: date, dayStartHour: dayStartHour, calendar: calendar)
        )
        return referenceYear - memoryYear
    }

    /// Half-open bounds of the one logical day that contains `date`.
    ///
    /// Deliberately has no `dayWindow` parameter, and that is the whole point
    /// of it being separate from `range(for:anniversaryYear:)`. `dayWindow` is
    /// a *recall* setting — how near to today's date still counts as "on this
    /// day" when looking back at past years. It is not a definition of a day.
    /// Widening this by it would make "the rest of that day" mean up to seven
    /// days, and would hand a plainly factual question ("what else did I shoot
    /// that day") two different answers depending on whether Pro was bought.
    ///
    /// `dayStartHour` is the opposite case and *is* honoured: it is the app's
    /// own declared answer to where a day boundary sits, already applied by
    /// `logicalDate`, `yearsAgo` and `range`. An evening running to 2am is the
    /// exact case it exists for, and splitting that night across two days is
    /// the bug it was added to fix.
    ///
    /// Advances by `.day` rather than adding 86,400 seconds so a
    /// daylight-saving transition does not shift the boundary by an hour, and
    /// checks the resolved month and day the way `range` does, so 29 February
    /// is never rolled silently into 1 March.
    static func dayBounds(
        containing date: Date,
        dayStartHour: Int = MemoryWindow.dayStartHour,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date)? {
        let calendar = anniversaryCalendar(calendar)
        let startHour = max(0, min(dayStartHour, 6))

        // Which logical day this instant belongs to. A photo taken at 01:00
        // with a 4am day start belongs to the previous evening.
        let logical = logicalDate(for: date, dayStartHour: startHour, calendar: calendar)

        let year = calendar.component(.year, from: logical)
        let month = calendar.component(.month, from: logical)
        let day = calendar.component(.day, from: logical)

        guard let start = calendar.date(from: DateComponents(
            year: year, month: month, day: day,
            hour: startHour, minute: 0, second: 0
        )), calendar.component(.month, from: start) == month,
            calendar.component(.day, from: start) == day,
            let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            return nil
        }
        return (start, end)
    }

    /// A stable identifier for the logical day containing `date`.
    ///
    /// Used for view identity and for caching a per-day answer, so it has to
    /// be the same string for two instants in the same logical day and a
    /// different one across the boundary. Built from the logical day's own
    /// components rather than from a formatter, so it does not move with the
    /// user's locale.
    static func dayKey(
        containing date: Date,
        dayStartHour: Int = MemoryWindow.dayStartHour,
        calendar: Calendar = .current
    ) -> String? {
        let calendar = anniversaryCalendar(calendar)
        let logical = logicalDate(
            for: date,
            dayStartHour: max(0, min(dayStartHour, 6)),
            calendar: calendar
        )
        let parts = calendar.dateComponents([.year, .month, .day], from: logical)
        guard let year = parts.year, let month = parts.month, let day = parts.day else {
            return nil
        }
        return "\(year)-\(month)-\(day)"
    }

    /// Date range for the anniversary of `referenceDate` in `anniversaryYear`,
    /// widened by the configured window on both sides. `end` is exclusive.
    /// The range begins at `dayStartHour` (not midnight) so photos taken in the
    /// early hours of the next calendar day are attributed to the previous evening.
    static func range(
        for referenceDate: Date,
        anniversaryYear: Int,
        dayWindow: Int = MemoryWindow.dayWindow,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date)? {
        let calendar = anniversaryCalendar(calendar)
        let month = calendar.component(.month, from: referenceDate)
        let day = calendar.component(.day, from: referenceDate)
        let startHour = dayStartHour

        let window = clampedDayWindow(dayWindow)

        // Include hour so the window begins at dayStartHour, not midnight.
        // The month/day equality check rejects dates that do not exist in this
        // year (Feb 29 outside a leap year); `Calendar` would otherwise roll
        // them silently forward to Mar 1.
        let exactAnniversary = calendar.date(from: DateComponents(
            year: anniversaryYear, month: month, day: day,
            hour: startHour, minute: 0, second: 0
        )).flatMap { candidate -> Date? in
            guard calendar.component(.month, from: candidate) == month,
                  calendar.component(.day, from: candidate) == day else { return nil }
            return candidate
        }

        let anniversary: Date
        if let exactAnniversary {
            anniversary = exactAnniversary
        } else {
            // Feb 29 viewed from a non-leap year.
            //
            // With no window there is genuinely no anniversary to show, so the
            // year is correctly dropped. With a window there very much is: a
            // user on Feb 29 with +/-3 days is asking for Feb 26 - Mar 3, a
            // range that exists in *every* year. The old code checked existence
            // before widening, so it discarded 15 of the last 20 years on the
            // one day a user is most likely to go looking.
            //
            // Anchoring on the last real day of the month (Feb 28) skews the
            // window one day early rather than losing the year entirely. That
            // is the same convention a monthly reminder set for the 31st uses.
            guard window > 0,
                  let monthStart = calendar.date(from: DateComponents(
                      year: anniversaryYear, month: month, day: 1,
                      hour: startHour, minute: 0, second: 0
                  )),
                  let daysInMonth = calendar.range(of: .day, in: .month, for: monthStart)?.count,
                  let clamped = calendar.date(from: DateComponents(
                      year: anniversaryYear, month: month, day: min(day, daysInMonth),
                      hour: startHour, minute: 0, second: 0
                  )) else {
                return nil
            }
            anniversary = clamped
        }
        guard let start = calendar.date(byAdding: .day, value: -window, to: anniversary),
              let end = calendar.date(byAdding: .day, value: window + 1, to: anniversary) else {
            return nil
        }
        return (start, end)
    }
}
