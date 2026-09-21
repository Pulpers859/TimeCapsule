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
        case memory(image: UIImage?, yearsAgo: Int)
        case empty
        case noAccess
    }

    let date: Date
    let content: Content
    let totalCount: Int
}

/// Marked `nonisolated` throughout on purpose.
///
/// A nonisolated implementation can satisfy a protocol requirement whatever
/// the requirement's own isolation is; the reverse is not true. Since
/// `TimelineProvider` makes no isolation promise, this is the spelling that
/// cannot become a mismatch.
nonisolated struct MemoryProvider: TimelineProvider {
    func placeholder(in context: Context) -> MemoryEntry {
        MemoryEntry(date: Date(), content: .memory(image: nil, yearsAgo: 3), totalCount: 4)
    }

    func getSnapshot(in context: Context, completion: @escaping (MemoryEntry) -> Void) {
        Task {
            let entries = await timelineEntries(family: context.family, limit: 1)
            completion(entries.first ?? MemoryEntry(date: Date(), content: .empty, totalCount: 0))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MemoryEntry>) -> Void) {
        Task {
            let refresh = Self.nextDayBoundary(after: Date())
            let entries = await timelineEntries(family: context.family, limit: 4)
            let timeline = Timeline(
                entries: entries.isEmpty
                    ? [MemoryEntry(date: Date(), content: .empty, totalCount: 0)]
                    : entries,
                // Reloading at the day boundary rather than on a fixed interval
                // is what keeps the widget correct the moment "today" changes,
                // including for someone whose day starts at 3am.
                policy: .after(refresh)
            )
            completion(timeline)
        }
    }

    /// Up to `limit` memories, spread across the day so the widget rotates
    /// instead of showing one photo until midnight.
    private func timelineEntries(family: WidgetFamily, limit: Int) async -> [MemoryEntry] {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            return [MemoryEntry(date: Date(), content: .noAccess, totalCount: 0)]
        }

        // Exactly what the gallery asks for, through exactly the same service,
        // so the widget cannot disagree with the grid behind it.
        //
        // Capped at the number of memories this widget can actually show. An
        // uncapped call retains a `PHAsset` for every match across the whole
        // lookback — a widened memory range makes that a 15-day window over
        // 20 years — to use four of them, inside an extension small enough
        // that the difference can get it killed. A killed timeline never
        // installs its next reload, so the home screen freezes on a stale
        // photo until the app is next backgrounded.
        let queryDate = MemoryWindow.logicalDate(for: Date())

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
        let groups = MemoryLibrary.yearGroups(
            on: queryDate,
            exclusions: exclusions,
            maxPerYear: limit
        )
        guard !groups.isEmpty else { return [] }

        // From `count(on:)`, not by summing the groups, which are capped and
        // would undercount. That path answers from the fetch itself without
        // materialising anything.
        let total = MemoryLibrary.count(on: queryDate, exclusions: exclusions)
        let picks = Self.picks(from: groups, limit: limit)

        let now = Date()
        let span = Self.nextDayBoundary(after: now).timeIntervalSince(now)
        // `nil` for the accessory families, which draw no photo.
        let pixelSize = Self.thumbnailSize(for: family)

        var entries: [MemoryEntry] = []
        for (offset, pick) in picks.enumerated() {
            var image: UIImage?
            if let pixelSize {
                image = await Self.thumbnail(for: pick.asset, size: pixelSize)
            }
            let stride = span * Double(offset) / Double(max(picks.count, 1))
            entries.append(
                MemoryEntry(
                    date: now.addingTimeInterval(stride),
                    content: .memory(image: image, yearsAgo: pick.yearsAgo),
                    totalCount: total
                )
            )
        }
        return entries
    }

    /// One photo per year first, so a rotation shows different years rather
    /// than four frames from the same afternoon. Only once years run out does
    /// it take more from the newest one.
    private static func picks(from groups: [YearGroup], limit: Int) -> [(asset: PHAsset, yearsAgo: Int)] {
        var picks: [(asset: PHAsset, yearsAgo: Int)] = []
        for group in groups where picks.count < limit {
            if let asset = group.assets.first {
                picks.append((asset, group.yearsAgo))
            }
        }
        if let newest = groups.first {
            for asset in newest.assets.dropFirst() where picks.count < limit {
                picks.append((asset, newest.yearsAgo))
            }
        }
        return picks
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

    /// The longest edge, in pixels, worth asking Photos for — or `nil` for a
    /// family that shows no photo at all.
    ///
    /// These are pixels, not points, because that is what `targetSize` means.
    /// A `.systemMedium` tile is roughly 338 x 158 points, so on a 3x screen
    /// its widest edge is a bit over 1000 pixels; the old 600 was under half
    /// of that and every photo was being stretched to fit. `.systemSmall` is
    /// about 158 points square, so 512 covers it with a little headroom.
    ///
    /// The accessory families return `nil`. Neither of them draws the image —
    /// they are a count and a line of text — so the previous 200-pixel
    /// request was decoded and thrown away on every timeline refresh, inside
    /// the one process that has a memory limit worth respecting.
    private static func thumbnailSize(for family: WidgetFamily) -> CGFloat? {
        switch family {
        case .systemMedium: 1024
        case .accessoryCircular, .accessoryRectangular: nil
        default: 512
        }
    }

    /// The photo, as sharp as can be had without going to the network.
    ///
    /// Asked for at `.aspectFit`, not `.aspectFill`: the widget now shows the
    /// whole frame, so a request that crops to a square would throw away the
    /// very parts the fit exists to keep.
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
    /// Neither delivery mode calls the result handler more than once, which
    /// is what makes resuming a continuation from it safe. `.opportunistic`
    /// is the mode that calls back twice, and using it here would crash.
    private static func thumbnail(for asset: PHAsset, size: CGFloat) async -> UIImage? {
        if let image = await requestImage(for: asset, size: size, delivery: .highQualityFormat) {
            return image
        }
        return await requestImage(for: asset, size: size, delivery: .fastFormat)
    }

    private static func requestImage(
        for asset: PHAsset,
        size: CGFloat,
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
                targetSize: CGSize(width: size, height: size),
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

    /// The photo, whole, over a blurred copy of itself.
    ///
    /// A plain `.scaledToFill()` crops to the centre, and a widget is a far
    /// more extreme aspect ratio than any photo: a standing portrait in a
    /// `.systemMedium` tile keeps a vertical sliver and throws away the
    /// subject. Fitting instead would show all of it but band the sides with
    /// dead black. Scaling one copy to fill as a backdrop and fitting the
    /// real one on top keeps the tile edge-to-edge while still showing the
    /// picture the photo actually is.
    ///
    /// The explicit `GeometryReader` frame is not decoration. `scaledToFill`
    /// reports a size larger than the one proposed to it, so inside a `ZStack`
    /// it grows the stack rather than overflowing it, and what that does to
    /// the layout differs by family — which is why one size letterboxed while
    /// another zoomed. Pinning both copies to the measured size and clipping
    /// makes every family behave the same way.
    @ViewBuilder
    private static func photo(_ image: UIImage) -> some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
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

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width, height: size.height)
            }
        }
    }

    @ViewBuilder
    private var home: some View {
        switch entry.content {
        case .memory(let image, let yearsAgo):
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
            .containerBackground(for: .widget) {
                ZStack {
                    Color.black
                    if let image {
                        Self.photo(image)
                    } else {
                        // A memory whose photo could not be loaded locally.
                        // The widget never goes to the network, so an
                        // iCloud-only original with no cached rendition lands
                        // here — and a plain black tile captioned "3 Years
                        // Ago" reads as a broken widget rather than as a photo
                        // it cannot reach. Also covers the placeholder entry,
                        // which WidgetKit redacts anyway.
                        Image(systemName: "photo")
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(.white.opacity(0.25))
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
