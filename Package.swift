// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Twitcher",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Twitcher",
            path: "Sources/Twitcher"
        )
    ]
)
