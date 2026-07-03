// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeBeacon",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "ClaudeBeacon",
            path: "Sources/ClaudeBeacon"
        )
    ]
)
