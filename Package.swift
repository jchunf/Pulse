// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
// Pulse — macOS local-first digital self-tracking app.
// See docs/ for the product design and roadmap.
//
// Module layout (B1):
//   PulseCore         — platform-independent domain logic, protocols, rules
//   PulsePlatform     — macOS-specific adapters (CGEventTap, NSWorkspace, AX)
//   PulseApp          — SwiftUI app executable (menu bar + dashboard)
//   PulseTestSupport  — fakes / test doubles, used by tests and previews
//
// Tests live alongside the modules that need them. PulseCoreTests is the
// largest suite and is fully runnable on any platform Swift supports.
//
// B1 scope is the foundation only: protocols, pure rules, schema, fakes.
// CGEventTap / NSWorkspace live implementations arrive in B2.

import PackageDescription

let package = Package(
    name: "Pulse",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PulseCore", targets: ["PulseCore"]),
        .library(name: "PulsePlatform", targets: ["PulsePlatform"]),
        .library(name: "PulseTestSupport", targets: ["PulseTestSupport"]),
        .executable(name: "PulseApp", targets: ["PulseApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
        // swift-snapshot-testing will return when the first UI
        // snapshot-based test actually lands (docs/10-testing-and-ci.md §二).
    ],
    targets: [
        .target(
            name: "PulseCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "PulsePlatform",
            dependencies: ["PulseCore"]
        ),
        .target(
            name: "PulseTestSupport",
            dependencies: ["PulseCore"]
        ),
        .executableTarget(
            name: "PulseApp",
            dependencies: [
                "PulseCore",
                "PulsePlatform"
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "PulseCoreTests",
            dependencies: [
                "PulseCore",
                "PulseTestSupport",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .testTarget(
            name: "PulsePlatformTests",
            dependencies: [
                "PulsePlatform",
                "PulseTestSupport"
            ]
        )
    ]
)
