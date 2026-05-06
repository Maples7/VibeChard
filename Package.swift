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
    ]
)
