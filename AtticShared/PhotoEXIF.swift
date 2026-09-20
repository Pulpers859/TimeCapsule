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

        // TIFF's Make/Model are separate fields, but most cameras' Model
        // already reads as the full name ("iPhone 15 Pro"), so prefixing the
        // make unconditionally would print "Apple iPhone 15 Pro". Only
        // combine them when the model doesn't already say the make.
        let cameraModel: String?
        if let trimmedModel, let trimmedMake, !trimmedModel.localizedCaseInsensitiveContains(trimmedMake) {
            cameraModel = "\(trimmedMake) \(trimmedModel)"
        } else {
            cameraModel = trimmedModel ?? trimmedMake
        }

        let sanitizedFNumber = (fNumber ?? 0) > 0 ? fNumber : nil
        let sanitizedExposure = (exposureTime ?? 0) > 0 ? exposureTime : nil
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
    var shutterSpeedDisplay: String? {
        guard let exposureTime else { return nil }
        if exposureTime >= 1 {
            return Self.trimmedNumber(exposureTime) + " s"
        }
        let denominator = Int((1 / exposureTime).rounded())
        return "1/\(denominator) s"
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
    /// decimal place, which is all an aperture or a multi-second exposure
    /// ever needs.
    private static func trimmedNumber(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
