// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OneShot",
    platforms: [.macOS(.v14)],
    targets: [
        // Platform-independent logic (signing, stitching, rendering, search), covered by unit tests.
        .target(
            name: "OneShotCore",
            path: "Sources/OneShotCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "OneShot",
            dependencies: ["OneShotCore"],
            path: "Sources/OneShot",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "OneShotCoreTests",
            dependencies: ["OneShotCore"],
            path: "Tests/OneShotCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
