import Foundation

/// Camera metadata as read off the file, formatted for display.
///
/// The extraction itself needs `Photos` and `ImageIO`, which is why it lives
/// in `TimeCapsule/Shared` rather than here — this package builds on Windows,
/// where neither exists. Everything in this type is pure formatting, though,
/// and that half is worth the same deterministic test coverage as the rest of
/// this package rather than only ever being eyeballed on whatever photo
/// happens to be open in the simulator.
nonisolated struct PhotoEXIF: Equatable, Sendable {
    let cameraModel: String?
    let lensModel: String?
    let fNumber: Double?
    let exposureTime: Double?
    let iso: Int?
    let focalLength35mm: Int?

    /// Fails when every field is empty, so a caller can use the initializer
    /// itself as the "is there anything worth showing" check.
    init?(
        make: String?,
        model: String?,
        lensModel: String?,
        fNumber: Double?,
        exposureTime: Double?,
        iso: Int?,
        focalLength35mm: Int?
    ) {
        let trimmedMake = make?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let trimmedModel = model?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let trimmedLens = lensModel?.trimmingCharacters(in: .whitespaces).nilIfEmpty

        // TIFF's Make/Model are separate fields, and most cameras keep them
        // that way — Apple's own EXIF has Make "Apple", Model "iPhone 15
        // Pro", so combining them is correct and expected ("Apple iPhone 15
        // Pro"). Some manufacturers duplicate the make into Model instead
        // (Model "Canon EOS R5" alongside Make "Canon"); prepending
        // unconditionally there would print "Canon Canon EOS R5".
        //
        // The overlap test is on the make's *first word*, not the whole
        // string, because makes routinely carry a corporate suffix the model
        // does not repeat: Nikon writes Make "NIKON CORPORATION" with Model
        // "NIKON D850". Testing the whole make there finds no overlap and
        // prints "NIKON CORPORATION NIKON D850" — the exact duplication this
        // branch exists to prevent.
        let cameraModel: String?
        if let trimmedModel, let trimmedMake {
            let makeToken = trimmedMake.split(separator: " ").first.map(String.init) ?? trimmedMake
            cameraModel = trimmedModel.localizedCaseInsensitiveContains(makeToken)
                ? trimmedModel
                : "\(trimmedMake) \(trimmedModel)"
        } else {
            cameraModel = trimmedModel ?? trimmedMake
        }

        // Bounded, not merely positive. These numbers come from a file on
        // disk rather than from anything trustworthy: EXIF stores them as
        // rationals, and a zero denominator arrives here as infinity, which
        // `> 0` happily accepts and `Int(_:)` then traps on — crashing the
        // app the moment the info sheet drew. NaN was already excluded, but
        // only by accident, since every comparison against it is false.
        // Anything outside what a real camera could have recorded is treated
        // as absent, which is the same outcome as the tag being missing.
        let sanitizedFNumber = Self.measurement(fNumber, in: 0.1...1000)
        let sanitizedExposure = Self.measurement(exposureTime, in: 0.0000001...86_400)
        let sanitizedISO = (iso ?? 0) > 0 ? iso : nil
        let sanitizedFocalLength = (focalLength35mm ?? 0) > 0 ? focalLength35mm : nil

        guard cameraModel != nil || trimmedLens != nil || sanitizedFNumber != nil
            || sanitizedExposure != nil || sanitizedISO != nil || sanitizedFocalLength != nil else {
            return nil
        }

        self.cameraModel = cameraModel
        self.lensModel = trimmedLens
        self.fNumber = sanitizedFNumber
        self.exposureTime = sanitizedExposure
        self.iso = sanitizedISO
        self.focalLength35mm = sanitizedFocalLength
    }

    var apertureDisplay: String? {
        guard let fNumber else { return nil }
        return "\u{0192}/" + Self.trimmedNumber(fNumber)
    }

    /// Sub-second exposures read as a shutter-speed fraction — "1/125 s" —
    /// because that is the unit photographers actually think in; a decimal
    /// like "0.008 s" is technically the same number and unreadable as one.
    ///
    /// The denominator keeps a decimal place when it needs one. Rounding it
    /// to a whole number printed real, common exposures as the wrong number
    /// rather than as no number: 0.8s (1/1.25) came out as "1/1 s", and
    /// 1/1.5 came out as "1/2 s" — a third faster than the shot actually
    /// was. Handheld low-light and night-mode frames land in that band
    /// routinely, and Apple's own Photos shows "1/1.3" there.
    /// Between a half second and a second the fraction is abandoned. A
    /// denominator between 1 and 2 reads as "1/1.2 s", which is a strange way
    /// to say 0.8 seconds, and its last digit depends on how the formatter
    /// breaks an exact tie — 1/0.8 is exactly 1.25, and `%.1f` rounds that to
    /// even, giving 1.2 rather than the 1.3 you would write by hand. Cameras
    /// mark this band in decimal seconds (0.8"), which is both clearer and
    /// not sensitive to any of that.
    var shutterSpeedDisplay: String? {
        guard let exposureTime else { return nil }
        if exposureTime > 0.5 {
            return Self.trimmedNumber(exposureTime) + " s"
        }
        return "1/" + Self.trimmedNumber(1 / exposureTime) + " s"
    }

    var isoDisplay: String? {
        guard let iso else { return nil }
        return "ISO \(iso)"
    }

    var focalLengthDisplay: String? {
        guard let focalLength35mm else { return nil }
        return "\(focalLength35mm) mm"
    }

    /// Whole numbers read as "8", not "8.0"; everything else keeps one
    /// decimal place, which is all an aperture, a shutter denominator or a
    /// multi-second exposure ever needs.
    ///
    /// Total by construction: the `Int` conversion — which traps on infinity
    /// and on anything past `Int64` — is reached only for a finite value well
    /// inside that range. `String(format:)` renders the rest without
    /// trapping. Callers already reject out-of-range input; this makes the
    /// crash impossible rather than merely unreached.
    private static func trimmedNumber(_ value: Double) -> String {
        guard value.isFinite, abs(value) < 1e15, value.rounded() == value else {
            return String(format: "%.1f", value)
        }
        return String(Int(value))
    }

    private static func measurement(_ value: Double?, in range: ClosedRange<Double>) -> Double? {
        guard let value, value.isFinite, range.contains(value) else { return nil }
        return value
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
