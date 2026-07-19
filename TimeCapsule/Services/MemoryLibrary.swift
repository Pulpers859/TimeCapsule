import Foundation
import Photos

nonisolated struct YearGroup: Identifiable {
    let id: Int
    let year: Int
    let assets: [PHAsset]
    private let referenceYear: Int

    init(year: Int, assets: [PHAsset], referenceYear: Int = Calendar.current.component(.year, from: Date())) {
        self.id = year
        self.year = year
        self.assets = assets
        self.referenceYear = referenceYear
    }

    var yearsAgo: Int {
        referenceYear - year
    }

    var label: String {
        yearsAgo == 1 ? "1 Year Ago" : "\(yearsAgo) Years Ago"
    }
}

nonisolated enum MemoryLibrary {
    static func yearGroups(on date: Date, calendar: Calendar = .current) -> [YearGroup] {
        let currentYear = calendar.component(.year, from: date)
        let ranges = stride(
            from: currentYear - 1,
            through: currentYear - MemoryWindow.lookbackYears,
            by: -1
        ).compactMap { year -> (year: Int, start: Date, end: Date)? in
            guard let range = MemoryWindow.range(for: date, anniversaryYear: year, calendar: calendar) else {
                return nil
            }
            return (year, range.start, range.end)
        }
        guard !ranges.isEmpty else { return [] }

        let datePredicates = ranges.map { item in
            NSPredicate(
                format: "creationDate >= %@ AND creationDate < %@",
                item.start as NSDate,
                item.end as NSDate
            )
        }
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: datePredicates)
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let result = PHAsset.fetchAssets(with: fetchOptions)
        var assetsByYear: [Int: [PHAsset]] = [:]
        result.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .image || asset.mediaType == .video,
                  let creationDate = asset.creationDate,
                  let matchingYear = ranges.first(where: {
                      creationDate >= $0.start && creationDate < $0.end
                  })?.year else {
                return
            }
            assetsByYear[matchingYear, default: []].append(asset)
        }

        return ranges.compactMap { item in
            guard let assets = assetsByYear[item.year], !assets.isEmpty else { return nil }
            return YearGroup(year: item.year, assets: assets, referenceYear: currentYear)
        }
    }

    static func count(on date: Date, calendar: Calendar = .current) -> Int {
        yearGroups(on: date, calendar: calendar).reduce(0) { total, group in
            total + group.assets.count
        }
    }

}
