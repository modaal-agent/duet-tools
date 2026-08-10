// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import XCTest

@testable import DuetCLI

/// The manifest-side helpers of the lockless host-lane sweep: `.package(path:`
/// extraction (both declaration forms, comments stripped) — the edges the
/// no-lockfile recursion walks.
final class HostLaneManifestTests: XCTestCase {

  func testExtractsBareAndNamedPathForms() {
    let manifest = """
      let package = Package(
        dependencies: [
          .package(name: "modaal-agent-duet", path: "/Volumes/DATA01/Projects/modaal-agent-duet"),
          .package(path: "../../../Libraries/Telemetry"),
        ]
      )
      """
    XCTAssertEqual(
      HostLane.pathDependencyPaths(inManifest: HostLane.strippedOfLineComments(manifest)),
      ["/Volumes/DATA01/Projects/modaal-agent-duet", "../../../Libraries/Telemetry"])
  }

  func testExtractsMultiLineDeclaration() {
    let manifest = """
      .package(
        name: "modaal-agent-duet",
        path: "../duet")
      """
    XCTAssertEqual(
      HostLane.pathDependencyPaths(inManifest: HostLane.strippedOfLineComments(manifest)),
      ["../duet"])
  }

  func testCommentedDeclarationsAreStripped() {
    let manifest = """
      // .package(path: "../commented-out"),
      .package(path: "../real")  // trailing note: .package(url: "https://x")
      """
    let uncommented = HostLane.strippedOfLineComments(manifest)
    XCTAssertEqual(HostLane.pathDependencyPaths(inManifest: uncommented), ["../real"])
    XCTAssertFalse(uncommented.contains(".package(url:"))
  }

  func testRemoteDeclarationIsNotAPathEdge() {
    let manifest = """
      .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
      """
    let uncommented = HostLane.strippedOfLineComments(manifest)
    XCTAssertEqual(HostLane.pathDependencyPaths(inManifest: uncommented), [])
    XCTAssertTrue(uncommented.contains(".package(url:"))
  }
}
