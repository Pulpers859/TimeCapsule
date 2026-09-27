import Foundation

/// The clock a photo was taken on, as opposed to the phone's.
///
/// `PHAsset.creationDate` is a moment with no time zone, so Attic used to
/// show it in the phone's current zone. Apple Photos shows the time the
/// camera recorded, in the camera's own zone. For iPhone photos the two are
/// the same. For a camera whose zone or daylight-saving setting differs from
/// the phone's they are not: a Nikon photo read 11:11 AM in Photos and
/// 12:11 PM in Attic, and the user confirmed 11:11 was when it happened.
///
/// The camera's zone is in the file's EXIF — `DateTimeOriginal` (the clock
/// reading) and `OffsetTimeOriginal` (its offset from UTC) — and PhotoKit
/// has no API for it, so it is read from the file.
///
/// Framework-free, so the parsing and the agreement check are tested on
/// every platform the package builds on.
nonisolated enum CaptureClock {
    /// How far apart the file's moment and the library's may be and still
    /// count as the same. EXIF keeps whole seconds; sub-seconds live in a
    /// separate tag this does not read.
    static let agreementTolerance: TimeInterval = 2

    /// The time zone to show `creationDate` in, or `nil` to use the phone's.
    ///
    /// Only when the file agrees with the library about *when* — the clock
    /// reading at that offset is the same moment as `creationDate`. If the
    /// date was changed in Photos with Adjust Date & Time, the library moved
    /// and the file did not; its zone then describes a time that is no
    /// longer the photo's, and the phone's zone is the safer answer.
    static func recordedTimeZone(
        dateTimeOriginal: String?,
        offset: String?,
        creationDate: Date
    ) -> TimeZone? {
        guard let dateTimeOriginal,
              let offset,
              let offsetSeconds = offsetSeconds(offset),
              let naive = naiveDate(dateTimeOriginal) else {
            return nil
        }
        let moment = naive.addingTimeInterval(-TimeInterval(offsetSeconds))
        guard abs(moment.timeIntervalSince(creationDate)) <= agreementTolerance else { return nil }
        return TimeZone(secondsFromGMT: offsetSeconds)
    }

    /// "+05:30", "-05:00", "+0000" → seconds east of UTC. `nil` for anything
    /// else, or for an offset no real place uses.
    static func offsetSeconds(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let sign = trimmed.first, sign == "+" || sign == "-" else { return nil }
        let digits = trimmed.dropFirst().filter { $0 != ":" }
        guard digits.count == 4, digits.allSatisfy(\.isNumber),
              let hours = Int(digits.prefix(2)),
              let minutes = Int(digits.suffix(2)),
              hours <= 14, minutes < 60 else {
            return nil
        }
        let seconds = hours * 3600 + minutes * 60
        return sign == "-" ? -seconds : seconds
    }

    /// EXIF's "yyyy:MM:dd HH:mm:ss" read as if it were UTC — the clock
    /// reading with no zone attached, for `recordedTimeZone` to place.
    ///
    /// Parsed by hand rather than with a `DateFormatter`, which follows the
    /// device's locale and calendar settings and can misread a fixed format.
    static func naiveDate(_ text: String) -> Date? {
        let parts = text.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == ":" || $0 == " " })
            .map { Int($0) }
        guard parts.count == 6, parts.allSatisfy({ $0 != nil }) else { return nil }
        let values = parts.compactMap { $0 }
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        calendar.timeZone = utc
        let components = DateComponents(
            year: values[0], month: values[1], day: values[2],
            hour: values[3], minute: values[4], second: values[5]
        )
        guard (1...12).contains(values[1]), (1...31).contains(values[2]),
              (0...23).contains(values[3]), (0...59).contains(values[4]),
              (0...60).contains(values[5]) else {
            return nil
        }
        return calendar.date(from: components)
    }
}
