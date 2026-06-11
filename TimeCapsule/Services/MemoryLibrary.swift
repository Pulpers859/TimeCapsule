import Foundation
import Photos

struct YearGroup: Identifiable {
    let id: Int
    let year: Int
    let assets: [PHAsset]

    init(year: Int, assets: [PHAsset]) {
        self.id = year
        self.year = year
        self.assets = assets
    }

    var yearsAgo: Int {
        Calendar.current.component(.year, from: Date()) - year
    }

    var label: String {
        yearsAgo == 1 ? "1 Year Ago" : "\(yearsAgo) Years Ago"
    }
}

enum MemoryLibrary {
    static func yearGroups(on date: Date, calendar: Calendar = .current) -> [YearGroup] {
        let currentYear = calendar.component(.year, from: date)

        return stride(from: currentYear - 1, through: currentYear - MemoryWindow.lookbackYears, by: -1).compactMap { year in
            let assets = assets(on: date, anniversaryYear: year, calendar: calendar)
            guard !assets.isEmpty else { return nil }
            return YearGroup(year: year, assets: assets)
        }
    }

    static func count(on date: Date, calendar: Calendar = .current) -> Int {
        yearGroups(on: date, calendar: calendar).reduce(0) { total, group in
            total + group.assets.count
        }
    }

    private static func assets(on date: Date, anniversaryYear: Int, calendar: Calendar) -> [PHAsset] {
        guard let range = MemoryWindow.range(for: date, anniversaryYear: anniversaryYear, calendar: calendar) else {
            return []
        }

        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate < %@",
            range.start as NSDate,
            range.end as NSDate
        )
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let result = PHAsset.fetchAssets(with: fetchOptions)
        guard result.count > 0 else { return [] }

        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            if asset.mediaType == .image || asset.mediaType == .video {
                assets.append(asset)
            }
        }
        return assets
    }
}
