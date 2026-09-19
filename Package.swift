// swift-tools-version: 5.10
import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let infoPlistPath = packageRoot
    .appendingPathComponent("Sources/SoundLevels/Info.plist")
    .path

let package = Package(
    name: "SoundLevels",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SoundLevels", targets: ["SoundLevels"]),
        .library(name: "AudioMixerKit", targets: ["AudioMixerKit"])
    ],
    targets: [
        .target(
            name: "AudioMixerKit"
        ),
        .executableTarget(
            name: "SoundLevels",
            dependencies: ["AudioMixerKit"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlistPath
                ])
            ]
        ),
        .testTarget(
            name: "AudioMixerKitTests",
            dependencies: ["AudioMixerKit"]
        )
    ]
)
