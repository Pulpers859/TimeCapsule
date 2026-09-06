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
            path: "TimeCapsule/Services",
            exclude: [
                "MemoryLibrary.swift",
                "MemoryRecapExporter.swift",
                "NotificationManager.swift",
                "PhotosEditHandoff.swift"
            ],
            sources: [
                "GalleryStateLogic.swift",
                "MemoryWindow.swift",
                "NotificationPlan.swift",
                "RecapPlan.swift"
            ]
        ),
        .testTarget(
            name: "TimeCapsuleCoreTests",
            dependencies: ["TimeCapsuleCore"],
            path: "Tests/TimeCapsuleCoreTests"
        )
    ]
)
