// swift-tools-version:5.10
// VibeChard — Apple-only parallel worktree orchestrator for AI coding agents.
//
// Three products in one package:
//   • VibeChardCore (library) — all logic, single-target test friendly.
//   • vch (executable)        — ArgumentParser CLI shell, depends on Core.
//   • vch-xcodebuild-shim     — minimal standalone binary placed on PATH inside
//                               worktrees to transparently isolate xcodebuild.
//
// Layout, deps, and platform floor follow the locked v1 plan.

import PackageDescription

let package = Package(
    name: "VibeChard",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "VibeChardCore", targets: ["VibeChardCore"]),
        .executable(name: "vch", targets: ["vch"]),
        .executable(name: "vch-xcodebuild-shim", targets: ["vch-xcodebuild-shim"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-system",          from: "1.4.0"),
    ],
    targets: [
        .target(
            name: "VibeChardCore",
            dependencies: [
                .product(name: "SystemPackage", package: "swift-system"),
            ]
        ),
        .executableTarget(
            name: "vch",
            dependencies: [
                "VibeChardCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "vch-xcodebuild-shim",
            // Intentionally NO dependencies. The shim must stay tiny and start
            // fast: every xcodebuild call inside a vch worktree forks it once.
            dependencies: []
        ),
        .testTarget(
            name: "VibeChardCoreTests",
            dependencies: ["VibeChardCore"]
        ),
        // Shim integration tests. Built against the actual shim binary
        // (a separate executable target — Swift cannot @testable import
        // an executable target's symbols, and the AGENTS.md "three
        // targets, fixed" rule forbids extracting a library). These
        // tests exec the binary under controlled env to verify argv
        // injection end-to-end.
        //
        // Declaring the executable as a dependency makes SwiftPM build
        // it automatically before running tests; the test then locates
        // it next to its own xctest bundle. We do NOT shell out to
        // `swift build` from inside the test (would deadlock on the
        // package build lock).
        .testTarget(
            name: "ShimIntegrationTests",
            dependencies: ["vch-xcodebuild-shim"]
        ),
        // CLI smoke tests. Forks the real `vch` binary and asserts:
        //   1. Every name registered as a top-level subcommand is also
        //      in `TaskName.reserved` (reverse drift — a registered
        //      command leaking into the sugar path because nobody added
        //      it to the reserved set).
        //   2. Every name in `TaskName.reserved` resolves to a real
        //      subcommand (forward drift — `vch <name>` errors when it
        //      should dispatch). This is the load-bearing #82 regression.
        //   3. `vch <name> --help` exits 0 for every subcommand (catches
        //      ArgumentParser configuration mistakes).
        // Same Process-based pattern as ShimIntegrationTests; the vch
        // executable target is declared as a dependency so SwiftPM
        // builds it before the test bundle.
        .testTarget(
            name: "VchCLISmokeTests",
            dependencies: ["vch", "VibeChardCore"]
        ),
    ]
)
