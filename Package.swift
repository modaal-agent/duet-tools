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
    .executable(name: "duet", targets: ["duet"]),
    .library(name: "CanonicalSumEmission", targets: ["CanonicalSumEmission"]),
  ],
  dependencies: [
    // Pre-publication: the sibling checkout. Published form:
    // .package(url: "https://github.com/modaal-agent/duet.git", from: …)
    .package(path: "../modaal-agent-duet"),
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
    .executableTarget(
      name: "duet",
      dependencies: [
        .target(name: "CanonicalSumGen"),
        .product(name: "DuetReplay", package: "modaal-agent-duet"),
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
  ]
)
