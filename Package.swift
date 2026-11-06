// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AudioEditor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AudioEditor", targets: ["AudioEditor"]),
        .library(name: "EditorCore", targets: ["EditorCore"]),
    ],
    targets: [
        // libmp3lame 3.100, vendored unmodified (LGPL, see Sources/CLame/COPYING).
        .target(
            name: "CLame",
            path: "Sources/CLame",
            exclude: ["COPYING"],
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .headerSearchPath("."),
                .unsafeFlags(["-w"]),
            ]
        ),
        // Platform-independent engine: model, session import, mixing, loudness, MP3/ID3 export.
        .target(name: "EditorCore", dependencies: ["CLame"]),
        // The macOS app (SwiftUI + AppKit + AVFoundation).
        .executableTarget(name: "AudioEditor", dependencies: ["EditorCore"]),
        .testTarget(name: "EditorCoreTests", dependencies: ["EditorCore"], resources: [.copy("Fixtures")]),
    ]
)
