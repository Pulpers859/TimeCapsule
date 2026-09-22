// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TimeCapsuleAutomation",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "TimeCapsuleCore", targets: ["TimeCapsuleCore"])
    ],
    targets: [
        .target(
            name: "TimeCapsuleCore",
            path: "AtticShared",
            // `exclude:` only, no `sources:`.
            //
            // The two were listed together, and when `sources:` is given it
            // is authoritative — `exclude:` then has no effect at all, so
            // one of the two lists was dead configuration and the other had
            // to be edited by hand for every new file. Nothing warned when
            // it was not: an allow-list silently compiles a forgotten file
            // nowhere, both SwiftPM jobs stay green, and the only compiler
            // that ever sees this folder never looks at it.
            //
            // A deny-list fails the right way round. A new file here is
            // compiled and tested by default on macOS and Windows, and one
            // that genuinely cannot build off-Apple — because it imports
            // Photos, CoreLocation or ImageIO — breaks the build loudly
            // until it is named below, which is the moment to notice.
            exclude: [
                "MemoryLibrary.swift",
                "MemoryExclusions.swift",
                "AssetEligibility.swift",
                "DayContents.swift"
            ]
        ),
        .testTarget(
            name: "TimeCapsuleCoreTests",
            dependencies: ["TimeCapsuleCore"],
            path: "Tests/TimeCapsuleCoreTests"
        )
    ]
)
