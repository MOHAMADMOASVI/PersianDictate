// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PersianDictate",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PersianDictate",
            path: "Sources/PersianDictate",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
