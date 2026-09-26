import Foundation

/// Where the widget draws a photo inside its tile.
///
/// Two plain answers were both wrong for the wide tile, which is about 2.1:1.
/// Filling it crops a standing photo to a band through the middle and loses
/// the subject. Fitting it shows the whole photo, but a portrait then covers
/// about a third of the width and the tile reads as narrow — seen on device.
///
/// So this sits between them: zoom past the fit by at most `wideMaxZoom`,
/// crop what spills over, and let the blurred copy fill what is left. A
/// photo that is already close to the tile's shape — an ordinary landscape —
/// simply fills, because a zoom that stops a few points short leaves slivers
/// of blur that look like a mistake.
///
/// Doubles rather than `CGRect`, so it builds and is tested on every
/// platform the package CI runs on.
nonisolated enum WidgetPhotoFraming {
    /// How far past the fit the wide tile zooms: 1.5 widens a portrait from
    /// about a third of the tile to about half, keeping two-thirds of its
    /// height.
    static let wideMaxZoom = 1.5

    /// A photo whose fill needs no more zoom than this over its fit just
    /// fills. A 4:3 landscape in the wide tile needs about 1.6; a 3:2 about
    /// 1.43.
    static let fillThreshold = 1.65

    /// Of the height cropped, the share taken from the top. People are
    /// nearer the top of a standing photo than the bottom, so a centred crop
    /// cuts heads before feet.
    static let topBias = 0.3

    nonisolated struct Frame: Equatable {
        var width: Double
        var height: Double
        /// Centre of the photo, in the tile's coordinates.
        var centerX: Double
        var centerY: Double
        /// True when nothing of the tile is left uncovered, so the blurred
        /// backdrop behind it would never be seen.
        var coversTile: Bool
    }

    /// - Parameter maxZoom: the furthest past the fit to zoom. Pass
    ///   `.infinity` to always fill, as the small tile does.
    static func frame(
        imageWidth: Double,
        imageHeight: Double,
        tileWidth: Double,
        tileHeight: Double,
        maxZoom: Double
    ) -> Frame? {
        guard imageWidth > 0, imageHeight > 0, tileWidth > 0, tileHeight > 0 else { return nil }

        let fit = min(tileWidth / imageWidth, tileHeight / imageHeight)
        let fill = max(tileWidth / imageWidth, tileHeight / imageHeight)
        let fillZoom = fill / fit
        let zoom = fillZoom <= fillThreshold ? fillZoom : min(fillZoom, max(maxZoom, 1))

        let width = imageWidth * fit * zoom
        let height = imageHeight * fit * zoom

        // Horizontal overflow is cropped evenly; vertical overflow mostly
        // from the bottom. With no overflow the photo is centred.
        let overflowY = max(height - tileHeight, 0)
        let centerY = tileHeight / 2 + overflowY * (0.5 - topBias)

        // A hair of tolerance, so rounding never reports a filled tile as
        // uncovered and draws a backdrop no one can see.
        let covers = width >= tileWidth - 0.5 && height >= tileHeight - 0.5

        return Frame(
            width: width,
            height: height,
            centerX: tileWidth / 2,
            centerY: centerY,
            coversTile: covers
        )
    }
}
