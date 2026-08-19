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
        // Tiny ObjC shim to read NSXPCConnection's audit token (for unforgeable
        // client validation in the helper — PIDs can be reused, tokens can't).
        .target(
            name: "XPCAuditToken",
            path: "Sources/XPCAuditToken"
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
            dependencies: ["SDRGBShared", "XPCAuditToken"],
            path: "Sources/SDRGBHelper"
        ),
        // Pure-logic tests: volume matching, program measurement, and the parsers
        // for the firmware's own files. Nothing here touches a device.
        .testTarget(
            name: "SDRGBTests",
            dependencies: ["SDRGB"],
            path: "Tests/SDRGBTests"
        )
    ]
)
