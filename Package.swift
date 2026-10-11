// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Grab",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Grab",
            path: "Sources/Grab",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
