// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OneShot",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OneShot",
            path: "Sources/OneShot",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
