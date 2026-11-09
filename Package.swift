// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MIDIRouter",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RouterCore", targets: ["RouterCore"]),
        .library(name: "RouterMIDI", targets: ["RouterMIDI"]),
        .executable(name: "midi-router", targets: ["MIDIRouterApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/lexfrei/ascii-ui.git", exact: "0.1.0-rc.1")
    ],
    targets: [
        .target(name: "RouterCore"),
        .target(name: "RouterMIDI", dependencies: ["RouterCore"]),
        .executableTarget(
            name: "MIDIRouterApp",
            dependencies: ["RouterCore", "RouterMIDI", .product(name: "ASCIIUI", package: "ascii-ui")],
            path: "App/Sources"),
        .testTarget(name: "RouterMIDITests", dependencies: ["RouterCore", "RouterMIDI"]),
        .testTarget(
            name: "RouterAppTests", dependencies: ["MIDIRouterApp", .product(name: "ASCIIUI", package: "ascii-ui")]),
        .testTarget(name: "RouterCoreTests", dependencies: ["RouterCore"]),
    ]
)
