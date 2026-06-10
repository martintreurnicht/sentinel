// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sentinel",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pinned exactly: the framework, its checksum, and the appcast CLI tools
        // in the artifact's bin/ (used by the release workflow) move together.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.3"),
    ],
    targets: [
        .executableTarget(
            name: "Sentinel",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")]
        ),
        .testTarget(name: "SentinelTests", dependencies: ["Sentinel"]),
    ]
)
