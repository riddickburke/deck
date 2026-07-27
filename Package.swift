// swift-tools-version: 5.9
import PackageDescription

// Note: the test suite is an executable target rather than a `.testTarget`.
// XCTest and swift-testing both ship with full Xcode; this project is built with
// Command Line Tools only, so tests run via `swift run DeckTests`.
let package = Package(
    name: "Deck",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "deck", targets: ["Deck"]),
        .library(name: "DeckCore", targets: ["DeckCore"]),
    ],
    targets: [
        .target(name: "DeckCore"),
        .executableTarget(name: "Deck", dependencies: ["DeckCore"]),
        .executableTarget(name: "DeckTests", dependencies: ["DeckCore"]),
    ]
)
