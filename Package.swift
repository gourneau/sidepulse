// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SidePulse",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Shared XPC protocol + constants, compiled into both the app and helper.
        .target(
            name: "SidePulseShared",
            path: "Sources/SidePulseShared"
        ),
        // Tiny ObjC shim to read NSXPCConnection's audit token (for unforgeable
        // client validation in the helper — PIDs can be reused, tokens can't).
        .target(
            name: "XPCAuditToken",
            path: "Sources/XPCAuditToken"
        ),
        // The menu-bar app.
        .executableTarget(
            name: "SidePulse",
            dependencies: ["SidePulseShared"],
            path: "Sources/SidePulse"
        ),
        // The privileged root LaunchDaemon (installed via SMAppService).
        .executableTarget(
            name: "SidePulseHelper",
            dependencies: ["SidePulseShared", "XPCAuditToken"],
            path: "Sources/SidePulseHelper"
        ),
        // Pure-logic tests: volume matching, program measurement, and the parsers
        // for the firmware's own files. Nothing here touches a device.
        .testTarget(
            name: "SidePulseTests",
            dependencies: ["SidePulse"],
            path: "Tests/SidePulseTests"
        )
    ]
)
