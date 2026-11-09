// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Butler",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Butler",
            path: "Sources/Butler",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
