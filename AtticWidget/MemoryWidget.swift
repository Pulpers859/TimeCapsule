import Darwin
import os
import Photos
import SwiftUI
import UIKit
import WidgetKit

/// Today's memory, on the home and lock screens.
///
/// Every competitor in this space has one of these — Google Photos, Day One,
/// and every small "on this day" app on the store. It is also the only surface
/// that delivers the app's whole premise without the app being opened.
///
/// It reads the photo library directly rather than rendering something the app
/// left behind in a shared container. A cached snapshot would be correct only
/// as often as the app was launched, which defeats the point of a widget: the
/// person who never opens Attic is exactly who this is for.
struct MemoryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AtticMemoryWidget", provider: MemoryProvider()) { entry in
            MemoryWidgetView(entry: entry)
        }
        .configurationDisplayName("On This Day")
        .description("A photo from today's date in a past year.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryRectangular,
            .accessoryCircular
        ])
    }
}

struct MemoryEntry: TimelineEntry {
    enum Content {
        case memory(photo: WidgetPhoto?, yearsAgo: Int)
        case empty
        case noAccess
    }

    let date: Date
    let content: Content
    let totalCount: Int
    /// Memory figures from building this timeline, shown on the widget in
    /// sideload builds only. There is no Mac to profile on, so the phone
    /// has to report its own numbers.
    var diagnostics: String? = nil
}

/// A photo the widget has already cropped and saved, and where to draw it.
///
/// The timeline holds this — a file location — rather than the picture.
/// Twelve decoded photos held in the timeline is the one thing most likely
/// to push the extension past iOS's memory limit, and Apple's WidgetKit
/// engineers' advice for exactly that is file-backed images and fewer held
/// in memory. Each one is decoded only when it is drawn.
struct WidgetPhoto {
    let url: URL
    /// Where the saved image goes, in fractions of the tile.
    let placement: WidgetPhotoFraming.Rect
    /// Nothing of the tile is left uncovered, so no blurred backdrop.
    let coversTile: Bool
}

/// Marked `nonisolated` throughout on purpose.
///
/// A nonisolated implementation can satisfy a protocol requirement whatever
/// the requirement's own isolation is; the reverse is not true. Since
/// `TimelineProvider` makes no isolation promise, this is the spelling that
/// cannot become a mismatch.
nonisolated struct MemoryProvider: TimelineProvider {
    func placeholder(in context: Context) -> MemoryEntry {
        MemoryEntry(date: Date(), content: .memory(photo: nil, yearsAgo: 3), totalCount: 4)
    }

    func getSnapshot(in context: Context, completion: @escaping (MemoryEntry) -> Void) {
        Task {
            let (entries, _) = await timelineEntries(
                family: context.family,
                displaySize: context.displaySize,
                limit: 1
            )
            completion(entries.first ?? MemoryEntry(date: Date(), content: .empty, totalCount: 0))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MemoryEntry>) -> Void) {
        Task {
            let (entries, refresh) = await timelineEntries(
                family: context.family,
                displaySize: context.displaySize,
                limit: WidgetRotation.slotCount
            )
            let timeline = Timeline(
                entries: entries.isEmpty
                    ? [MemoryEntry(date: Date(), content: .empty, totalCount: 0)]
                    : entries,
                // The earlier of the end of the rotation and the day
                // boundary. The boundary is what keeps the widget correct the
                // moment "today" changes, including for someone whose day
                // starts at 3am; the end of the rotation is what draws a
                // fresh random twelve every six hours instead of looping.
                policy: .after(refresh)
            )
            completion(timeline)
        }
    }

    /// Up to `limit` random memories, one every thirty minutes, and when to
    /// ask for the next batch. See `WidgetRotation` for the shape.
    private func timelineEntries(
        family: WidgetFamily,
        displaySize: CGSize,
        limit: Int
    ) async -> (entries: [MemoryEntry], refresh: Date) {
        let now = Date()
        let dayBoundary = Self.nextDayBoundary(after: now)
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            return ([MemoryEntry(date: now, content: .noAccess, totalCount: 0)], dayBoundary)
        }

        // Exactly what the gallery asks for, through exactly the same service,
        // so the widget cannot disagree with the grid behind it.
        //
        // Capped at the number of memories this widget can actually show. An
        // uncapped call retains a `PHAsset` for every match across the whole
        // lookback — a widened memory range makes that a 15-day window over
        // 20 years — to use twelve of them, inside an extension small enough
        // that the difference can get it killed. A killed timeline never
        // installs its next reload, so the home screen freezes on a stale
        // photo until the app is next backgrounded.
        let queryDate = MemoryWindow.logicalDate(for: now)

        // Resolved once, and resolved *bounded*. Both halves matter and the
        // previous version only had the first.
        //
        // Left to their defaults the two calls below each build their own
        // context, which for an excluded cloud shared album — fetched
        // unbounded, since PhotoKit rejects a predicate inside one — is two
        // full walks of that album inside the extension. Resolving once fixes
        // that. But it was resolved through
        // `MemoryExclusions.Context.current()` with no argument, and that
        // default leaves the album lookup unbounded for *every* excluded
        // album, not just the cloud-backed ones. So an excluded ordinary
        // album of ten thousand photos went from two small indexed queries to
        // one full enumeration of all ten thousand — strictly worse, in the
        // one process with a jetsam limit, and the exact failure
        // `excludedAlbumMemberIdentifiers(matching:)` documents as the thing
        // that kills this extension. Trading the common case for the rare one
        // is not what that change was for.
        //
        // `exclusionContext(on:)` is the same context `yearGroups` and
        // `count` build privately, date-bounded, resolved once.
        let exclusions = MemoryLibrary.exclusionContext(on: queryDate)
        // A random `limit` of each year rather than its earliest, so a busy
        // day shows more than its first hour. Still capped, for the memory
        // reasons above.
        let groups = MemoryLibrary.yearGroups(
            on: queryDate,
            exclusions: exclusions,
            maxPerYear: limit,
            randomSample: true
        )
        guard !groups.isEmpty else { return ([], dayBoundary) }

        // From `count(on:)`, not by summing the groups, which are capped and
        // would undercount. That path answers from the fetch itself without
        // materialising anything.
        let total = MemoryLibrary.count(on: queryDate, exclusions: exclusions)
        var generator = SystemRandomNumberGenerator()
        let picks = WidgetRotation.picks(
            from: groups.map { group in group.assets.map { (asset: $0, yearsAgo: group.yearsAgo) } },
            limit: limit,
            using: &generator
        )

        // One photo at a time: fetch, crop, save, let go. Only file
        // locations accumulate, so memory stays flat however many there are.
        // `nil` tile for the accessory families, which draw no photo.
        var photos: [String: WidgetPhoto] = [:]
        var attempted = 0
        var peakUsed = Self.footprint()
        if let tile = await Self.tilePixels(for: family, displaySize: displaySize),
           let folder = WidgetPhotoStore.newBatch(now: now) {
            let maxZoom = family == .systemSmall ? .infinity : WidgetPhotoFraming.wideMaxZoom
            for pick in picks {
                // Checked before every fetch, not once: this is what makes
                // a day that runs short of memory show eight photos instead
                // of freezing on one.
                guard WidgetRotation.shouldLoadAnother(
                    loadedSoFar: attempted,
                    headroomBytes: Self.headroom()
                ) else { break }
                attempted += 1
                let (photo, usedAtPeak) = await Self.savedPhoto(
                    for: pick.asset,
                    tile: tile,
                    maxZoom: maxZoom,
                    to: folder.appendingPathComponent("\(attempted).jpg")
                )
                peakUsed = max(peakUsed, usedAtPeak)
                if let photo {
                    photos[pick.asset.localIdentifier] = photo
                }
            }
        }

        // Rotate through the photos that actually loaded. One that could not
        // be read locally, or was never fetched because memory ran short,
        // is left out rather than shown as an empty tile. Only if none
        // loaded at all — or this family draws no photo — do the picks stand
        // as they are.
        let loaded = picks.filter { photos[$0.asset.localIdentifier] != nil }
        let schedule = WidgetRotation.schedule(
            loaded.isEmpty ? picks : loaded,
            from: now,
            dayBoundary: dayBoundary
        )

        let diagnostics = attempted == 0
            ? nil
            : "\(photos.count)/\(picks.count) · peak \(Self.megabytes(peakUsed))"

        let entries = schedule.entries.map { slot in
            MemoryEntry(
                date: slot.date,
                content: .memory(
                    photo: photos[slot.item.asset.localIdentifier],
                    yearsAgo: slot.item.yearsAgo
                ),
                totalCount: total,
                diagnostics: diagnostics
            )
        }
        return (entries, schedule.reload)
    }

    /// Memory left before iOS kills this extension, or `nil` if unknown.
    /// See `WidgetRotation.headroom` for why this is not simply what the
    /// system reports.
    static func headroom() -> Int? {
        WidgetRotation.headroom(
            reportedAvailable: Int(os_proc_available_memory()),
            footprint: footprint()
        )
    }

    /// What this extension is using, as iOS counts it against the limit
    /// (`phys_footprint`, the figure Xcode's memory gauge shows). Zero if it
    /// cannot be read.
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    /// The next time the answer to "what is today" changes.
    static func nextDayBoundary(after date: Date, calendar: Calendar = .current) -> Date {
        let boundary = calendar.date(
            bySettingHour: MemoryWindow.dayStartHour,
            minute: 0,
            second: 0,
            of: date
        ) ?? date
        if boundary > date { return boundary }
        return calendar.date(byAdding: .day, value: 1, to: boundary)
            ?? date.addingTimeInterval(60 * 60)
    }

    /// The tile's size in pixels, or `nil` for a family that shows no photo.
    ///
    /// From the size WidgetKit reports for this phone, not a guess: photos
    /// are fetched and cropped to exactly this, so a guess too large wastes
    /// memory on every photo and one too small is soft. The fallbacks are the
    /// largest iPhone's tiles, for the rare context that reports no size.
    ///
    /// The accessory families return `nil`. Neither of them draws the image —
    /// they are a count and a line of text — so fetching one would be decoded
    /// and thrown away, inside the one process with a memory limit.
    private static func tilePixels(for family: WidgetFamily, displaySize: CGSize) async -> CGSize? {
        let points: CGSize
        switch family {
        case .accessoryCircular, .accessoryRectangular:
            return nil
        case .systemMedium:
            points = displaySize.width > 0 ? displaySize : CGSize(width: 364, height: 170)
        default:
            points = displaySize.width > 0 ? displaySize : CGSize(width: 170, height: 170)
        }
        // `UIScreen.main` is deprecated for apps with scenes; an extension
        // has none, and it is still the one reliable source of the scale.
        let scale = await MainActor.run { UIScreen.main.scale }
        return CGSize(
            width: (points.width * scale).rounded(.up),
            height: (points.height * scale).rounded(.up)
        )
    }

    /// Fetches one photo, crops it to what the tile shows, and saves it.
    ///
    /// Also returns the memory in use while the fetched photo was held —
    /// the high point of the whole job — for the sideload readout.
    private static func savedPhoto(
        for asset: PHAsset,
        tile: CGSize,
        maxZoom: Double,
        to url: URL
    ) async -> (photo: WidgetPhoto?, usedAtPeak: Int) {
        // Asked for at the size it will be drawn, no larger. `pixelWidth`
        // and `pixelHeight` only guide the request; the crop below is worked
        // out from the image Photos actually returns.
        let target: CGSize
        if let frame = WidgetPhotoFraming.frame(
            imageWidth: Double(asset.pixelWidth),
            imageHeight: Double(asset.pixelHeight),
            tileWidth: Double(tile.width),
            tileHeight: Double(tile.height),
            maxZoom: maxZoom
        ) {
            target = CGSize(width: frame.width.rounded(.up), height: frame.height.rounded(.up))
        } else {
            let edge = max(tile.width, tile.height)
            target = CGSize(width: edge, height: edge)
        }

        guard let image = await thumbnail(for: asset, target: target) else {
            return (nil, footprint())
        }
        let usedAtPeak = footprint()
        let photo = autoreleasepool {
            save(image, tile: tile, maxZoom: maxZoom, to: url)
        }
        return (photo, usedAtPeak)
    }

    /// Crops to the visible part and writes it out as JPEG.
    ///
    /// Only an upright image is cropped. A `CGImage` is stored unrotated, so
    /// for any other orientation its pixel grid is not the one the crop was
    /// worked out on, and cropping it would cut the wrong part. Photos
    /// returns resized images upright in practice; if one ever is not, it is
    /// saved whole — `jpegData` keeps its orientation — and drawn at its
    /// full placement, clipped by the tile. Same picture, more pixels.
    private static func save(_ image: UIImage, tile: CGSize, maxZoom: Double, to url: URL) -> WidgetPhoto? {
        let width = Double(image.size.width * image.scale)
        let height = Double(image.size.height * image.scale)
        guard let crop = WidgetPhotoFraming.crop(
            imageWidth: width,
            imageHeight: height,
            tileWidth: Double(tile.width),
            tileHeight: Double(tile.height),
            maxZoom: maxZoom
        ) else { return nil }

        let data: Data?
        let placement: WidgetPhotoFraming.Rect
        if image.imageOrientation == .up,
           let cgImage = image.cgImage,
           cgImage.width == Int(width.rounded()),
           cgImage.height == Int(height.rounded()),
           let cropped = cgImage.cropping(to: CGRect(
               x: crop.source.x,
               y: crop.source.y,
               width: crop.source.width,
               height: crop.source.height
           ).integral) {
            data = UIImage(cgImage: cropped).jpegData(compressionQuality: 0.85)
            placement = crop.placement
        } else {
            data = image.jpegData(compressionQuality: 0.85)
            placement = crop.fullPlacement
        }

        guard let data, (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return WidgetPhoto(url: url, placement: placement, coversTile: crop.coversTile)
    }

    /// The photo, as sharp as can be had without going to the network.
    ///
    /// Quality is requested first and a fast rendition is the fallback rather
    /// than the default. `.fastFormat` returns whatever is already cached,
    /// which for a large photo is often a couple of hundred pixels — fine as
    /// a grid thumbnail, visibly soft blown up to fill a home screen tile.
    /// But it is also all that exists locally for an asset whose original
    /// lives in iCloud, and a widget must not go to the network: the round
    /// trip would blow its time budget. So a soft photo beats an empty tile,
    /// and it is only ever reached when the sharp one is genuinely absent.
    ///
    /// `.aspectFit` at the size the photo will be drawn: the whole frame,
    /// which `save` then crops to what the tile shows. Photos does the
    /// resizing in its own process, which is what keeps a 12-megapixel
    /// original from ever being decoded in this one.
    ///
    /// Neither delivery mode calls the result handler more than once, which
    /// is what makes resuming a continuation from it safe. `.opportunistic`
    /// is the mode that calls back twice, and using it here would crash.
    private static func thumbnail(for asset: PHAsset, target: CGSize) async -> UIImage? {
        if let image = await requestImage(for: asset, target: target, delivery: .highQualityFormat) {
            return image
        }
        return await requestImage(for: asset, target: target, delivery: .fastFormat)
    }

    private static func requestImage(
        for asset: PHAsset,
        target: CGSize,
        delivery: PHImageRequestOptionsDeliveryMode
    ) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = delivery
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false

        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: target,
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}

struct MemoryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MemoryEntry

    var body: some View {
        switch family {
        case .accessoryRectangular, .accessoryCircular:
            accessory
        default:
            home
        }
    }

    /// The photo, drawn where the provider decided.
    ///
    /// The framing — the small tile filling, the wide one zooming part-way
    /// so a portrait is not a sliver and a landscape still fills — is
    /// `WidgetPhotoFraming`'s, worked out once when the photo was saved. The
    /// saved image is already cropped to the part that shows, so here it is
    /// only placed. Placement is in fractions of the tile, so a tile drawn a
    /// little larger or smaller than reported (StandBy, display zoom) still
    /// comes out right.
    ///
    /// Whatever the photo leaves uncovered shows a blurred copy of it, so the
    /// tile is edge to edge either way; skipped when nothing of it would
    /// show, which also spares the blur's own memory.
    ///
    /// Everything is pinned to the `GeometryReader`'s measured size and
    /// clipped. `scaledToFill` reports a size larger than the one proposed to
    /// it, so inside a `ZStack` it grows the stack rather than overflowing
    /// it, and what that did to the layout differed by family — which is why
    /// one size once letterboxed while another zoomed.
    @ViewBuilder
    private static func photo(_ photo: WidgetPhoto) -> some View {
        GeometryReader { geometry in
            let size = geometry.size
            // Read from the file here, at draw time, so it is decoded only
            // while this entry is being drawn. A file that has gone — cleaned
            // up, or purged by iOS — falls back to the missing-photo icon.
            if let image = UIImage(contentsOfFile: photo.url.path) {
                let rect = CGRect(
                    x: photo.placement.x * size.width,
                    y: photo.placement.y * size.height,
                    width: photo.placement.width * size.width,
                    height: photo.placement.height * size.height
                )
                ZStack {
                    if !photo.coversTile {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: size.width, height: size.height)
                            .clipped()
                            // `opaque` because a blur otherwise samples past the edge
                            // and fades the border to transparent, which over the
                            // black container reads as a vignette.
                            .blur(radius: 20, opaque: true)
                            .overlay(Color.black.opacity(0.3))
                    }

                    Image(uiImage: image)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
                .frame(width: size.width, height: size.height)
                .clipped()
            } else {
                missingPhoto
                    .frame(width: size.width, height: size.height)
            }
        }
    }

    /// A memory whose photo could not be loaded locally.
    ///
    /// The widget never goes to the network, so an iCloud-only original with
    /// no cached rendition lands here — and a plain black tile captioned "3
    /// Years Ago" reads as a broken widget rather than as a photo it cannot
    /// reach. Also covers the placeholder entry, which WidgetKit redacts
    /// anyway.
    private static var missingPhoto: some View {
        Image(systemName: "photo")
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(.white.opacity(0.25))
    }

    @ViewBuilder
    private var home: some View {
        switch entry.content {
        case .memory(let photo, let yearsAgo):
            // The labels are the widget's *content*; everything visual is its
            // container background. That split is not cosmetic. Since iOS 17
            // a widget insets its content by a system margin, so a photo drawn
            // as content stops short of the rounded edge and leaves a black
            // ring around itself. Only the container background is allowed to
            // reach the corners, while the same margin keeps the text off them
            // — which is where text belongs anyway.
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.label(yearsAgo: yearsAgo))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                if entry.totalCount > 1 {
                    Text("\(entry.totalCount) memories")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            #if ATTIC_SIDELOAD
            .overlay(alignment: .topTrailing) { diagnostics }
            #endif
            .containerBackground(for: .widget) {
                ZStack {
                    Color.black
                    if let photo {
                        Self.photo(photo)
                    } else {
                        Self.missingPhoto
                    }
                    // A gradient rather than a solid scrim: the label has to
                    // stay legible over a bright sky and a dark room alike.
                    LinearGradient(
                        colors: [.black.opacity(0.75), .black.opacity(0.15), .clear],
                        startPoint: .bottom,
                        endPoint: .center
                    )
                }
            }

        case .empty:
            centred(
                title: "No memories today",
                detail: "Nothing was taken on this date in an earlier year."
            )

        case .noAccess:
            centred(
                title: "Open Attic",
                detail: "Attic needs access to your photos to show memories."
            )
        }
    }

    @ViewBuilder
    private var accessory: some View {
        switch entry.content {
        case .memory(_, let yearsAgo):
            if family == .accessoryCircular {
                VStack(spacing: 0) {
                    Text("\(entry.totalCount)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(yearsAgo == 1 ? "1 yr" : "\(yearsAgo) yrs")
                        .font(.system(size: 10))
                }
                .containerBackground(.clear, for: .widget)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text("On This Day")
                        .font(.headline)
                    Text(
                        entry.totalCount == 1
                            ? "1 memory · \(Self.label(yearsAgo: yearsAgo))"
                            : "\(entry.totalCount) memories · \(Self.label(yearsAgo: yearsAgo))"
                    )
                    .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .containerBackground(.clear, for: .widget)
            }

        case .empty:
            Text("No memories today")
                .font(.caption)
                .containerBackground(.clear, for: .widget)

        case .noAccess:
            Text("Open Attic")
                .font(.caption)
                .containerBackground(.clear, for: .widget)
        }
    }

    #if ATTIC_SIDELOAD
    /// Sideload builds only: photos loaded out of those picked, the most
    /// memory used while loading them, and the memory in use now, while
    /// drawing. iOS kills the extension at about 30 MB; this is how the
    /// phone reports how close it came, with no Mac to profile on.
    @ViewBuilder
    private var diagnostics: some View {
        if let diagnostics = entry.diagnostics {
            Text("\(diagnostics) · now \(MemoryProvider.megabytes(MemoryProvider.footprint())) of 30")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.black.opacity(0.45), in: Capsule())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }
    #endif

    private func centred(title: String, detail: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
            if family != .systemSmall {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    /// Matches `YearGroup.label` rather than inventing a second wording.
    private static func label(yearsAgo: Int) -> String {
        yearsAgo == 1 ? "1 Year Ago" : "\(yearsAgo) Years Ago"
    }
}

/// Where the widget keeps the photos its timelines point at.
///
/// Caches, because every file here can be rebuilt on the next reload; iOS
/// may purge it, and a purged photo shows the missing-photo icon until then.
nonisolated enum WidgetPhotoStore {
    private static var root: URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("WidgetPhotos", isDirectory: true)
    }

    /// A fresh folder for one timeline's photos, after clearing out batches
    /// old enough that no timeline can still be showing them.
    static func newBatch(now: Date) -> URL? {
        guard let root else { return nil }
        let fileManager = FileManager.default
        let batches = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for batch in batches {
            let modified = (try? batch.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if WidgetRotation.isStale(modified: modified, now: now) {
                try? fileManager.removeItem(at: batch)
            }
        }

        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            return nil
        }
    }
}
