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
        let queryDate = MemoryWindow.logicalDate(for: Date())
        let groups = MemoryLibrary.yearGroups(on: queryDate)
        guard !groups.isEmpty else { return [] }

        let total = groups.reduce(0) { $0 + $1.assets.count }
        let picks = Self.picks(from: groups, limit: limit)

        let now = Date()
        let span = Self.nextDayBoundary(after: now).timeIntervalSince(now)
        let pixelSize = Self.thumbnailSize(for: family)

        var entries: [MemoryEntry] = []
        for (offset, pick) in picks.enumerated() {
            let image = await Self.thumbnail(for: pick.asset, size: pixelSize)
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

    private static func thumbnailSize(for family: WidgetFamily) -> CGFloat {
        switch family {
        case .systemMedium: 600
        case .accessoryCircular, .accessoryRectangular: 200
        default: 400
        }
    }

    /// A widget extension is held to a much smaller memory budget than the
    /// app, so this asks for a modest thumbnail and never goes to the network:
    /// an iCloud round trip would blow the widget's time budget and the
    /// placeholder is a better outcome than a blank slot.
    private static func thumbnail(for asset: PHAsset, size: CGFloat) async -> UIImage? {
        let options = PHImageRequestOptions()
        // `.fastFormat` calls the result handler exactly once, which is what
        // makes resuming the continuation here safe.
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false

        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: size, height: size),
                contentMode: .aspectFill,
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

    @ViewBuilder
    private var home: some View {
        switch entry.content {
        case .memory(let image, let yearsAgo):
            ZStack(alignment: .bottomLeading) {
                Color.black
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
                // A gradient rather than a solid scrim: the label has to stay
                // legible over a bright sky and a dark room alike.
                LinearGradient(
                    colors: [.black.opacity(0.65), .black.opacity(0.1), .clear],
                    startPoint: .bottom,
                    endPoint: .center
                )
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
                .padding(.horizontal, 2)
                .padding(.bottom, 1)
            }
            .containerBackground(.black, for: .widget)

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
