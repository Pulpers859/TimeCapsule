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
    /// The memory this entry shows, so a tap opens it; see `MemoryLink`.
    var assetID: String? = nil
    /// Memory figures from building this timeline, shown on the widget only
    /// in a sideload build made with `widget_readout` on. There is no Mac to profile on, so the phone
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
    /// Photos returned it at close to the size it is drawn. See
    /// `WidgetRotation.isSharp`.
    var isSharp = true
    /// For the sideload readout: returned size, requested size, and which
    /// delivery produced it.
    var detail = ""
}

/// Marked `nonisolated` throughout on purpose.
///
/// A nonisolated implementation can satisfy a protocol requirement whatever
/// the requirement's own isolation is; the reverse is not true. Since
/// `TimelineProvider` makes no isolation promise, this is the spelling that
/// cannot become a mismatch.
nonisolated struct MemoryProvider: TimelineProvider {
    func placeholder(in context: Context) -> MemoryEntry {
        MemoryProbe.shared.touch()
        return MemoryEntry(date: Date(), content: .memory(photo: nil, yearsAgo: 3), totalCount: 4)
    }

    func getSnapshot(in context: Context, completion: @escaping (MemoryEntry) -> Void) {
        MemoryProbe.shared.touch()
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
        MemoryProbe.shared.touch()
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
        // Sideload readout: memory at each step of this build, and whether
        // another build was running in the same process at the same time.
        let overlapping = MemoryProbe.shared.beginBuild()
        defer { MemoryProbe.shared.endBuild() }
        // Wait out the previous build's leftovers first; see
        // `WidgetRotation.shouldKeepSettling`.
        let settled = await MemoryProbe.shared.settle()
        var stages = MemoryProbe.Stages()
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
        stages.mark("excl")
        // A random `limit` of each year rather than its earliest, so a busy
        // day shows more than its first hour. Still capped, for the memory
        // reasons above.
        //
        // Twice as many candidates as slots, so a photo that comes back soft
        // can be passed over for another from the same day.
        let candidateLimit = limit * WidgetRotation.candidatesPerSlot
        let groups = MemoryLibrary.yearGroups(
            on: queryDate,
            exclusions: exclusions,
            maxPerYear: candidateLimit,
            randomSample: true
        )
        guard !groups.isEmpty else { return ([], dayBoundary) }
        stages.mark("groups")

        // From `count(on:)`, not by summing the groups, which are capped and
        // would undercount. That path answers from the fetch itself without
        // materialising anything.
        let total = MemoryLibrary.count(on: queryDate, exclusions: exclusions)
        stages.mark("count")
        var generator = SystemRandomNumberGenerator()
        let picks = WidgetRotation.picks(
            from: groups.map { group in group.assets.map { (asset: $0, yearsAgo: group.yearsAgo) } },
            limit: candidateLimit,
            using: &generator
        )

        // One photo at a time: fetch, crop, save, let go. Only file
        // locations accumulate, so memory stays flat however many there are.
        // `nil` tile for the accessory families, which draw no photo.
        var photos: [String: WidgetPhoto] = [:]
        var attempted = 0
        var sharpCount = 0
        var tileDetail = ""
        // Cost of each photo measured directly — just before its fetch and
        // just after its save — because freed memory is not always handed
        // back, so the difference between stages can hide or inflate it.
        var photoDeltas: [Int] = []
        // What each photo leaves behind once it has returned and the main
        // thread has had a moment — the figure that decides how many fit.
        var kept: [Int] = []
        var largestCost = 0
        var waitedForMemory: TimeInterval = 0
        if let tileInfo = await Self.tilePixels(for: family, displaySize: displaySize),
           let folder = WidgetPhotoStore.newBatch(now: now) {
            let tile = tileInfo.size
            tileDetail = "tile \(Int(tile.width))×\(Int(tile.height)) (scale said \(tileInfo.reportedScale))"
            let maxZoom = family == .systemSmall ? .infinity : WidgetPhotoFraming.wideMaxZoom
            // Until `limit` sharp photos are in hand; the spare candidates
            // are only fetched to replace soft ones.
            for pick in picks where sharpCount < limit {
                // Checked before every fetch, not once: this is what makes
                // a day that runs short of memory show eight photos instead
                // of freezing on one.
                var allowed = WidgetRotation.shouldLoadAnother(
                    loadedSoFar: attempted,
                    headroomBytes: Self.headroom(),
                    largestPhotoCost: largestCost
                )
                // Short of room: wait for the system to free what earlier
                // fetches left, rather than stopping. See
                // `WidgetRotation.memoryWaitLimit`.
                while !allowed, waitedForMemory < WidgetRotation.memoryWaitLimit {
                    await MainActor.run {}
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    waitedForMemory += 0.25
                    allowed = WidgetRotation.shouldLoadAnother(
                        loadedSoFar: attempted,
                        headroomBytes: Self.headroom(),
                        largestPhotoCost: largestCost
                    )
                }
                guard allowed else { break }
                attempted += 1
                let before = Self.footprint()
                let (photo, usedAtPeak) = await Self.savedPhoto(
                    for: pick.asset,
                    tile: tile,
                    maxZoom: maxZoom,
                    to: folder.appendingPathComponent("\(attempted).jpg")
                )
                stages.observe(usedAtPeak)
                photoDeltas.append(usedAtPeak - before)
                largestCost = max(largestCost, usedAtPeak - before)
                kept.append(Self.footprint() - before)
                if let photo {
                    photos[pick.asset.localIdentifier] = photo
                    if photo.isSharp { sharpCount += 1 }
                }
            }
        }

        // Rotate through the sharp photos that loaded, in the order picked.
        // A soft one — the full photo is in iCloud and only a small preview
        // is on the phone — is shown only if nothing sharp loaded at all. One
        // that could not be read, or was never fetched because memory ran
        // short, is left out rather than shown as an empty tile. Only if none
        // loaded at all — or this family draws no photo — do the picks stand
        // as they are, up to `limit`.
        let loaded = WidgetRotation.rotation(
            picks.compactMap { pick in
                photos[pick.asset.localIdentifier].map { (item: pick, isSharp: $0.isSharp) }
            },
            limit: limit
        )
        let schedule = WidgetRotation.schedule(
            loaded.isEmpty ? Array(picks.prefix(limit)) : loaded,
            from: now,
            dayBoundary: dayBoundary
        )

        stages.mark("photos")
        let later = waitedForMemory > 0
            ? "waited \(waitedForMemory)s mid-load"
            : "no mid-load wait"
        let perPhoto = photoDeltas.isEmpty
            ? ""
            : " (each +\(MemoryProbe.mb(photoDeltas.reduce(0, +) / photoDeltas.count)), "
                + "max +\(MemoryProbe.mb(photoDeltas.max() ?? 0)))"
        let diagnostics = attempted == 0
            ? nil
            : [
                "\(sharpCount) sharp · \(photos.count - sharpCount) soft · \(tileDetail)",
                stages.summary + perPhoto,
                (kept.isEmpty ? "" : "kept +\(MemoryProbe.mb(kept.reduce(0, +) / kept.count)) each · ")
                    + later,
                settled ?? "no settle wait",
                "build #\(MemoryProbe.shared.buildCount)\(overlapping ? " OVERLAPPED" : "") · "
                    + "process began at \(MemoryProbe.mb(MemoryProbe.shared.processStart))"
            ].joined(separator: "\n")

        let entries = schedule.entries.map { slot in
            MemoryEntry(
                date: slot.date,
                content: .memory(
                    photo: photos[slot.item.asset.localIdentifier],
                    yearsAgo: slot.item.yearsAgo
                ),
                totalCount: total,
                assetID: slot.item.asset.localIdentifier,
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

    /// The tile's size in pixels, or `nil` for a family that shows no photo,
    /// with the screen scale the system reported (for the sideload readout).
    ///
    /// From the size WidgetKit reports for this phone: photos are fetched
    /// and cropped to exactly this, so too large wastes memory on every
    /// photo and too small is visibly soft. The fallbacks are the largest
    /// iPhone's tiles, for the rare context that reports no size.
    ///
    /// The scale is never taken below 3. Every photo is fetched at the tile's
    /// size times the scale, so a scale that comes back low makes every
    /// photo that many times too small, and blurry — which is what the first
    /// build of this code did on device, sharp in Photos and soft on the
    /// widget. Floored at 3, the worst a wrong reading can do is fetch
    /// photos half again larger than needed on a 2x iPhone: a little memory,
    /// never blur.
    ///
    /// The accessory families return `nil`. Neither of them draws the image —
    /// they are a count and a line of text — so fetching one would be decoded
    /// and thrown away, inside the one process with a memory limit.
    private static func tilePixels(
        for family: WidgetFamily,
        displaySize: CGSize
    ) async -> (size: CGSize, reportedScale: CGFloat)? {
        let points: CGSize
        switch family {
        case .accessoryCircular, .accessoryRectangular:
            return nil
        case .systemMedium:
            points = displaySize.width > 0 ? displaySize : CGSize(width: 364, height: 170)
        default:
            points = displaySize.width > 0 ? displaySize : CGSize(width: 170, height: 170)
        }
        let reportedScale = await MainActor.run { UIScreen.main.scale }
        let scale = max(reportedScale, 3)
        return (
            CGSize(
                width: (points.width * scale).rounded(.up),
                height: (points.height * scale).rounded(.up)
            ),
            reportedScale
        )
    }

    /// Serial, so one photo at a time is ever in memory.
    private static let loadQueue = DispatchQueue(label: "Attic.widget.photo-load", qos: .userInitiated)

    /// Fetches one photo, crops it to what the tile shows, and saves it.
    ///
    /// Also returns the memory in use while the fetched photo was held —
    /// the high point of the whole job — for the readout and for the
    /// memory check.
    private static func savedPhoto(
        for asset: PHAsset,
        tile: CGSize,
        maxZoom: Double,
        to url: URL
    ) async -> (photo: WidgetPhoto?, usedAtPeak: Int) {
        // Asked for at the size it will be drawn, no larger. `pixelWidth`
        // and `pixelHeight` only guide the request; the crop is worked out
        // from the image Photos actually returns.
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

        // Start to finish on one thread, inside one pool, so nothing of ours
        // outlives the job. Measured on device this did not by itself stop
        // memory accumulating — that is held inside the system frameworks,
        // and freed by them later — but it keeps our own part of it zero.
        let pooled: (photo: WidgetPhoto?, usedAtPeak: Int)? = await withCheckedContinuation { continuation in
            loadQueue.async {
                let result = autoreleasepool { () -> (photo: WidgetPhoto?, usedAtPeak: Int)? in
                    guard let image = synchronousImage(for: asset, target: target) else {
                        return nil
                    }
                    let usedAtPeak = footprint()
                    let photo = finish(
                        image,
                        target: target,
                        tile: tile,
                        maxZoom: maxZoom,
                        to: url,
                        delivery: "full"
                    )
                    return (photo, usedAtPeak)
                }
                continuation.resume(returning: result)
            }
        }
        if let pooled { return pooled }

        // The full photo is not on the phone. A synchronous request cannot
        // ask for the small preview — it always behaves as high quality — so
        // this one fallback stays asynchronous, and the preview is shown only
        // if nothing sharp loads (see `WidgetRotation.rotation`).
        guard let image = await requestImage(for: asset, target: target, delivery: .fastFormat) else {
            return (nil, footprint())
        }
        let usedAtPeak = footprint()
        let photo = autoreleasepool {
            finish(image, target: target, tile: tile, maxZoom: maxZoom, to: url, delivery: "fast")
        }
        return (photo, usedAtPeak)
    }

    /// The photo at `target`, from what is on the phone, or `nil`.
    ///
    /// Synchronous on purpose, and only ever called on `loadQueue`: see
    /// `savedPhoto`. A synchronous request calls its handler once, before
    /// returning.
    private static func synchronousImage(for asset: PHAsset, target: CGSize) -> UIImage? {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = false
        var result: UIImage?
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: target,
            contentMode: .aspectFit,
            options: options
        ) { image, _ in
            result = image
        }
        return result
    }

    /// Crops and saves `image`, and records how sharp it came back.
    private static func finish(
        _ image: UIImage,
        target: CGSize,
        tile: CGSize,
        maxZoom: Double,
        to url: URL,
        delivery: String
    ) -> WidgetPhoto? {
        let returnedWidth = Double(image.size.width * image.scale)
        let returnedHeight = Double(image.size.height * image.scale)
        guard var saved = save(image, tile: tile, maxZoom: maxZoom, to: url) else { return nil }
        saved.isSharp = WidgetRotation.isSharp(
            returnedWidth: returnedWidth,
            returnedHeight: returnedHeight,
            targetWidth: Double(target.width),
            targetHeight: Double(target.height)
        )
        saved.detail = "got \(Int(returnedWidth))×\(Int(returnedHeight)) of "
            + "\(Int(target.width))×\(Int(target.height)) · \(delivery)"
        return saved
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

    /// The small preview Photos keeps on the phone, for a photo whose full
    /// version is only in iCloud. A widget must not go to the network: the
    /// round trip would blow its time budget. So a soft photo beats an empty
    /// tile, and it is only ever used when nothing sharp loads.
    ///
    /// `.fastFormat` calls its handler once, which is what makes resuming a
    /// continuation from it safe. `.opportunistic` is the mode that calls
    /// back twice, and using it here would crash.
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
        content
            // A tap opens the memory on screen, not just the app. `nil` for
            // the empty and no-access states, where opening the app is the
            // whole answer.
            .widgetURL(entry.assetID.flatMap(MemoryLink.url(forAssetID:)))
    }

    @ViewBuilder
    private var content: some View {
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
            #if ATTIC_SIDELOAD_WIDGET_READOUT
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

    #if ATTIC_SIDELOAD_WIDGET_READOUT
    /// Only in a sideload build made with `widget_readout` on: photos
    /// loaded out of those picked, the most memory used while loading them,
    /// and the memory in use now, while drawing. iOS kills the extension at
    /// about 30 MB; this is how the phone reports how close it came, with no
    /// Mac to profile on.
    ///
    /// Off by default since sideload-42, where both widgets loaded all
    /// twelve photos at a peak of 24.8 MB and the readout had done its job.
    /// It sits over the photo, so it is built only when asked for.
    @ViewBuilder
    private var diagnostics: some View {
        if let diagnostics = entry.diagnostics {
            let drawing = MemoryProbe.shared.noteDraw()
            VStack(alignment: .trailing, spacing: 0) {
                Text(diagnostics)
                Text(
                    "draw \(MemoryProbe.mb(drawing.now)) (max \(MemoryProbe.mb(drawing.max))) · "
                        + "iOS limit \(MemoryProbe.mb(drawing.reportedLimit))"
                )
                if case .memory(let photo?, _) = entry.content {
                    Text(photo.detail)
                }
            }
            .font(.system(size: 7, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.85))
            // Wraps rather than truncates: this build exists to be read.
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.trailing)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4))
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

/// Sideload diagnostics: where the widget's memory goes.
///
/// One process serves every widget on the home screen, so the small and
/// wide widgets' timelines are built — possibly at the same time — and drawn
/// in the same place. A single reading of that process cannot say which of
/// them, or which step, the memory belongs to; this records the steps, the
/// overlap, and the drawing separately.
nonisolated final class MemoryProbe: @unchecked Sendable {
    static let shared = MemoryProbe()

    /// Memory in use when this process first ran any of Attic's code —
    /// the widget system and frameworks, before anything of ours.
    let processStart: Int

    private let lock = NSLock()
    private var inFlight = 0
    private var builds = 0
    private var drawMax = 0
    private var lowestStart: Int?

    private init() {
        processStart = MemoryProvider.footprint()
    }

    /// Forces `shared` into existence, so `processStart` is taken as early
    /// as possible rather than whenever the readout first asks for it.
    func touch() {}

    /// Returns whether another build was already running.
    func beginBuild() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        inFlight += 1
        builds += 1
        return inFlight > 1
    }

    func endBuild() {
        lock.lock()
        inFlight -= 1
        lock.unlock()
    }

    var buildCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return builds
    }

    /// Memory now, the most seen while drawing in this process, and the
    /// limit iOS reports (in use plus what it says is left).
    func noteDraw() -> (now: Int, max: Int, reportedLimit: Int) {
        let now = MemoryProvider.footprint()
        let limit = now + Int(os_proc_available_memory())
        lock.lock()
        drawMax = max(drawMax, now)
        let seen = drawMax
        lock.unlock()
        return (now, seen, limit)
    }

    /// Waits, briefly, for memory left by the previous build to be freed,
    /// and describes the wait for the readout — `nil` if there was none.
    func settle() async -> String? {
        let from = MemoryProvider.footprint()
        let lowest = lowestStartSoFar() ?? from

        var current = from
        var waited: TimeInterval = 0
        while WidgetRotation.shouldKeepSettling(current: current, lowestStart: lowest, waited: waited) {
            await MainActor.run {}
            try? await Task.sleep(nanoseconds: 250_000_000)
            waited += 0.25
            current = MemoryProvider.footprint()
        }

        recordStart(current)
        guard waited > 0 else { return nil }
        return "settled \(Self.mb(from)) → \(Self.mb(current)) in \(waited)s"
    }

    // Synchronous, so the lock is never held across a suspension point.
    private func lowestStartSoFar() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return lowestStart
    }

    private func recordStart(_ bytes: Int) {
        lock.lock()
        lowestStart = min(lowestStart ?? bytes, bytes)
        lock.unlock()
    }

    static func mb(_ bytes: Int) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }

    /// Memory at each named step of one build, plus the highest point.
    struct Stages {
        private var marks: [(String, Int)] = [("start", MemoryProvider.footprint())]
        private var high = 0

        mutating func mark(_ name: String) {
            let now = MemoryProvider.footprint()
            marks.append((name, now))
            high = max(high, now)
        }

        mutating func observe(_ bytes: Int) {
            high = max(high, bytes)
        }

        var summary: String {
            marks.map { "\($0.0) \(MemoryProbe.mb($0.1))" }.joined(separator: " · ")
                + " · high \(MemoryProbe.mb(max(high, marks.map { $0.1 }.max() ?? 0)))"
        }
    }
}
