// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SDRGB",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "SDRGB",
            path: "Sources/SDRGB"
        )
    ]
)
