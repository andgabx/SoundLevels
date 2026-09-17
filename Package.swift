// swift-tools-version: 5.10
import PackageDescription
import Foundation

// Anchored to the manifest's own location (T061), not the build invocation's working directory —
// `-Xlinker` paths are otherwise resolved relative to wherever `swift build`/`swift run` is
// invoked from, which already caused a real, silent build failure once in this project's history
// when the shell's CWD drifted into a subdirectory.
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
            name: "AudioMixerKit",
            resources: [
                // String Catalog for user-facing UI text (T046) — the Apple-platform equivalent of
                // Android/Kotlin's strings.xml. Views pass `bundle: .module` explicitly since this
                // target's resources are NOT visible via the default `Bundle.main` lookup that
                // `Text`/`Button` use otherwise.
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "SoundLevels",
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
