// swift-tools-version:6.0

// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import PackageDescription

// The open `duet` CLI (doc-15 §6.1's tools/ half). Its OWN repo — SwiftPM
// resolves one URL package per repository root, and library consumers of
// `duet` must never resolve the toolchain: the swift-syntax pin below stays in
// the TOOL's graph only — FC3-b's verdict, the reason the codegen arm beat the
// macro as the scaffold default. The CLI orchestrates `swift test` / `gradlew`
// as subprocesses and reads the machine artifacts the runners write
// (parity/.runs/*). Framework dependency: DuetReplay — the canonical writers
// the CLI byte-gates and materializes with ARE the writers the replay servers
// run (G1 — no CLI/flavor drift by construction).
//
// CanonicalSumEmission is exported: the `@CanonicalSum` macro opt-in
// (modaal-agent/duet-macros) assembles its expansion from the same rule-set,
// so the byte-dialect-critical emission cannot fork between the two vehicles.
let package = Package(
  name: "duet-tools",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .executable(name: "duet", targets: ["DuetCLI"]),
    .library(name: "CanonicalSumEmission", targets: ["CanonicalSumEmission"]),
  ],
  dependencies: [
    // The published framework, pinned EXACTLY: the CLI links DuetReplay — the
    // byte-gate writer — so the toolchain rides a known framework tag, and
    // pre-1.0 minors are breaking by family convention (upgrades are
    // deliberate re-pin commits, never floating ranges).
    .package(url: "https://github.com/modaal-agent/duet.git", exact: "0.1.0"),
    .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"700.0.0"),
  ],
  targets: [
    .target(
      name: "CanonicalSumEmission",
      path: "Sources/CanonicalSumEmission"
    ),
    .target(
      name: "CanonicalSumGen",
      dependencies: [
        .target(name: "CanonicalSumEmission"),
        .product(name: "SwiftParser", package: "swift-syntax"),
        .product(name: "SwiftSyntax", package: "swift-syntax"),
      ],
      path: "Sources/CanonicalSumGen"
    ),
    // The MODULE is DuetCLI while the PRODUCT stays `duet` (the binary name,
    // `swift run duet`, and the adopter wrapper are all product-named). A
    // module literally named `duet` collides case-insensitively with the
    // framework's `Duet` library module — build layouts key intermediates by
    // module name, so on a default (case-insensitive) APFS volume the two
    // clobber each other and the package cannot build at all. Caught only
    // when building off a case-sensitive dev volume; do not rename back.
    .executableTarget(
      name: "DuetCLI",
      dependencies: [
        .target(name: "CanonicalSumGen"),
        .product(name: "DuetReplay", package: "duet"),
      ],
      path: "Sources/duet"
    ),
    .testTarget(
      name: "CanonicalSumGenTests",
      dependencies: [
        .target(name: "CanonicalSumEmission"),
        .target(name: "CanonicalSumGen"),
      ],
      path: "Tests/CanonicalSumGenTests"
    ),
    // Tests the CLI's pure derivations (summary parsing, lane-task lint, the
    // dual-writer predicate, settings parsing) by importing the executable
    // module directly — SwiftPM links it into the test bundle without running
    // its top-level code.
    .testTarget(
      name: "DuetCLITests",
      dependencies: [
        .target(name: "DuetCLI")
      ],
      path: "Tests/DuetCLITests"
    ),
  ]
)
