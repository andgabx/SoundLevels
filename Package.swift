// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AudioMixer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AudioMixer", targets: ["AudioMixer"]),
        .library(name: "AudioMixerKit", targets: ["AudioMixerKit"])
    ],
    targets: [
        .target(
            name: "AudioMixerKit"
        ),
        .executableTarget(
            name: "AudioMixer",
            dependencies: ["AudioMixerKit"],
            linkerSettings: [
                // Embeds Info.plist directly into the executable's Mach-O __TEXT,__info_plist
                // section so LSUIElement/NSAudioCaptureUsageDescription apply even when run via
                // `swift run` or Xcode's SwiftPM executable scheme, without a hand-built .app
                // bundle. See tasks.md T002.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/AudioMixer/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "AudioMixerKitTests",
            dependencies: ["AudioMixerKit"]
        )
    ]
)
