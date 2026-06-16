// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SDRGB",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Shared XPC protocol + constants, compiled into both the app and helper.
        .target(
            name: "SDRGBShared",
            path: "Sources/SDRGBShared"
        ),
        // The menu-bar app.
        .executableTarget(
            name: "SDRGB",
            dependencies: ["SDRGBShared"],
            path: "Sources/SDRGB"
        ),
        // The privileged root LaunchDaemon (installed via SMAppService).
        .executableTarget(
            name: "SDRGBHelper",
            dependencies: ["SDRGBShared"],
            path: "Sources/SDRGBHelper"
        )
    ]
)
