// swift-tools-version: 5.9
import PackageDescription

// The manifest is compiled and run on the build host, so these conditionals select
// targets per platform. DeckCore and the test suite are portable; the front ends are
// not — SwiftUI exists only on Apple platforms and GTK4 is the Linux equivalent.
//
// Note: the test suite is an executable target rather than a `.testTarget`. XCTest and
// swift-testing both ship with full Xcode; this project builds with Command Line Tools
// alone, so tests run via `swift run DeckTests`.

var targets: [Target] = [
    .target(name: "DeckCore"),
    .executableTarget(name: "DeckTests", dependencies: ["DeckCore"]),
]

var products: [Product] = [
    .library(name: "DeckCore", targets: ["DeckCore"]),
]

#if os(macOS)
targets.append(.executableTarget(name: "Deck", dependencies: ["DeckCore"]))
products.append(.executable(name: "deck", targets: ["Deck"]))
#elseif os(Linux)
targets.append(
    .systemLibrary(
        name: "CGtk4",
        path: "Sources/CGtk4",
        pkgConfig: "gtk4",
        providers: [
            .apt(["libgtk-4-dev"]),
            .yum(["gtk4-devel"]),
        ]))
targets.append(.executableTarget(name: "DeckGTK", dependencies: ["DeckCore", "CGtk4"]))
products.append(.executable(name: "deck", targets: ["DeckGTK"]))
#endif

let package = Package(
    name: "Deck",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
