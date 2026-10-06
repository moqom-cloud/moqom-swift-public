// swift-tools-version: 6.2
//
// 6.2 rather than 6.0 because `.v26` is not a platform SwiftPM 6.0 can name.

import Foundation
import PackageDescription

// The SDK's core ships as prebuilt, signed XCFrameworks attached to each GitHub
// release. Everything in this repository is source; the binaries are licensed
// separately (see LICENSE-BINARY.md).
let version = "0.1.0"
let releases = "https://github.com/moqom-cloud/moqom-swift/releases/download/\(version)"

// Filled in by Scripts/build-xcframeworks.sh (checksums.txt) for each release.
let checksums: [String: String] = [
    "MoqomCore": "136b0e1101ec0ab9446ae40faba69c1f9b98e00a967ccf8e68d480a847c830f1",
    "MoqomWire": "13a75cadda84f61c9b552004c94dcf75a8fc1905255a52aa9879d6111d5058e1",
    "MoqomKit": "502d45155c9b13ebbd97fa109b5771aa5c51cc13a41575b1b2d988595a62099b",
    "MoqomLoopback": "885d1d52d338a1131d47caf78a72ba239e07c7f7cb8ac907af8a4b5afaf9d780",
]

// Local mode: binaries from ./Frameworks instead of the release, for working on
// the shell against a core you built yourself:
//
//   LOCAL_XCFRAMEWORKS=$PWD/Frameworks Scripts/build-xcframeworks.sh
//
// Used when MOQOM_LOCAL_BINARIES=1, or automatically when
// Frameworks/MoqomKit.xcframework exists (Frameworks/ is gitignored, so a clone
// never has it).
let packageDirectory = Context.packageDirectory
let useLocalBinaries =
    Context.environment["MOQOM_LOCAL_BINARIES"] == "1"
    || FileManager.default.fileExists(
        atPath: "\(packageDirectory)/Frameworks/MoqomKit.xcframework"
    )

func core(_ name: String) -> Target {
    if useLocalBinaries {
        return .binaryTarget(name: name, path: "Frameworks/\(name).xcframework")
    }
    return .binaryTarget(
        name: name,
        url: "\(releases)/\(name).xcframework.zip",
        checksum: checksums[name]!
    )
}

let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "MoqomKit",
    platforms: [.iOS(.v26), .macOS(.v26), .visionOS(.v26), .tvOS(.v26)],
    products: [
        // Rooms, publishing, subscribing, and the SwiftUI views.
        .library(name: "MoqomKit", targets: ["MoqomCore", "MoqomWire", "MoqomKit", "MoqomUI"]),
        // An in-memory relay and transport, for previews, tests and offline demos.
        .library(
            name: "MoqomLoopback",
            targets: ["MoqomCore", "MoqomWire", "MoqomKit", "MoqomLoopback"]
        ),
        // The MoQ Transport message codec on its own.
        .library(name: "MoqomWire", targets: ["MoqomCore", "MoqomWire"]),
    ],
    targets: [
        core("MoqomCore"),
        core("MoqomWire"),
        core("MoqomKit"),
        core("MoqomLoopback"),
        .target(
            name: "MoqomUI",
            dependencies: ["MoqomCore", "MoqomWire", "MoqomKit"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "MoqomUITests",
            dependencies: ["MoqomUI", "MoqomCore", "MoqomWire", "MoqomKit", "MoqomLoopback"],
            swiftSettings: strict
        ),
    ]
)
