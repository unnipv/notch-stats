// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NotchStats",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NotchStats", targets: ["NotchStats"])
    ],
    targets: [
        .executableTarget(
            name: "NotchStats",
            path: "Sources/NotchStats",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
