// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OneShot",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Platform-independent logic (signing, stitching, rendering, search), covered by unit tests.
        .target(
            name: "OneShotCore",
            path: "Sources/OneShotCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "OneShot",
            dependencies: [
                "OneShotCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/OneShot",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                // Sparkle.framework is embedded in Contents/Frameworks by scripts/build-app.sh.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
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
