// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import XCTest

@testable import DuetCLI

/// `duet doctor`'s [lanes] row — a package declaring tests that no lane has
/// ever built. Every case here is drawn from the reference repo's package set,
/// which is where both over-firing conditions were measured.
final class UnrunTestsLintTests: XCTestCase {

  private func manifest(
    testTarget: Bool = true, remoteDependency: Bool = true, extra: String = ""
  ) -> String {
    """
    // swift-tools-version:5.9
    import PackageDescription

    let package = Package(
      name: "Example",
      platforms: [.iOS(.v16)],
      products: [.library(name: "Example", targets: ["Example"])],
      dependencies: [
        .package(name: "Local", path: "../Local"),
        \(remoteDependency ? #".package(url: "https://github.com/Quick/Nimble.git", from: "14.0.0"),"# : "")
      ],
      targets: [
        .target(name: "Example"),
        \(testTarget ? #".testTarget(name: "ExampleTests", dependencies: ["Example"]),"# : "")
      ]
    )
    \(extra)
    """
  }

  // MARK: - the finding

  func testTestTargetWithRemoteDependencyAndNoLockIsAFinding() {
    XCTAssertTrue(
      Inventory.declaresUnresolvedTests(manifestText: manifest(), lockPresent: false))
  }

  func testALockClearsIt() {
    XCTAssertFalse(
      Inventory.declaresUnresolvedTests(manifestText: manifest(), lockPresent: true))
  }

  // MARK: - the two conditions that keep it from over-firing

  func testALibraryWithNoTestTargetIsNotAFinding() {
    // The normal case: plenty of packages are only ever built as dependencies.
    XCTAssertFalse(
      Inventory.declaresUnresolvedTests(
        manifestText: manifest(testTarget: false), lockPresent: false))
  }

  func testPathOnlyDependenciesAreNotAFinding() {
    // Measured on the reference repo's boundary-lane package: its tests run on
    // every push, and it has no lock because SwiftPM writes none for a package
    // whose dependencies are all local. Without this it is a false positive.
    XCTAssertFalse(
      Inventory.declaresUnresolvedTests(
        manifestText: manifest(remoteDependency: false), lockPresent: false))
  }

  func testNoDependenciesAtAllIsNotAFinding() {
    let text = """
      // swift-tools-version:5.9
      import PackageDescription

      let package = Package(
        name: "Solo",
        targets: [.target(name: "Solo"), .testTarget(name: "SoloTests")]
      )
      """
    XCTAssertFalse(Inventory.declaresUnresolvedTests(manifestText: text, lockPresent: false))
  }

  // MARK: - the declarations have to be real

  func testCommentedOutTestTargetIsNotAFinding() {
    let text = """
      // swift-tools-version:5.9
      let package = Package(
        name: "Example",
        dependencies: [.package(url: "https://github.com/Quick/Nimble.git", from: "14.0.0")],
        // .testTarget(name: "ExampleTests"),
        targets: [.target(name: "Example")]
      )
      """
    XCTAssertFalse(Inventory.declaresUnresolvedTests(manifestText: text, lockPresent: false))
  }

  func testCommentedOutRemoteDependencyIsNotAFinding() {
    let text = """
      // swift-tools-version:5.9
      let package = Package(
        name: "Example",
        // .package(url: "https://github.com/Quick/Nimble.git", from: "14.0.0"),
        dependencies: [.package(name: "Local", path: "../Local")],
        targets: [.target(name: "Example"), .testTarget(name: "ExampleTests")]
      )
      """
    XCTAssertFalse(Inventory.declaresUnresolvedTests(manifestText: text, lockPresent: false))
  }

  /// A URL inside a string literal contains `//`, which a naive comment strip
  /// would treat as the start of a comment and truncate the dependency away.
  func testAURLIsNotMistakenForAComment() {
    XCTAssertTrue(
      Inventory.declaresUnresolvedTests(manifestText: manifest(), lockPresent: false))
    let stripped = Inventory.strippingLineComments(manifest())
    XCTAssertTrue(stripped.contains("https://github.com/Quick/Nimble.git"))
  }

  func testTrailingCommentOnADeclarationLineIsRemoved() {
    let stripped = Inventory.strippingLineComments(
      #".package(name: "Local", path: "../Local"), // the sibling"#)
    XCTAssertFalse(stripped.contains("the sibling"))
    XCTAssertTrue(stripped.contains(#"path: "../Local""#))
  }

  // MARK: - the aggregate-workspace exemption

  /// The "AllTests" shape: one workspace listing every package so a single
  /// scheme runs the lot. Measured on a probe workspace — resolution writes ONE
  /// lock, at `<workspace>/xcshareddata/swiftpm/Package.resolved`, and the
  /// member packages' own roots stay empty. Their missing lock says nothing.
  func testWorkspaceFileRefsAreParsed() {
    let contents = """
      <?xml version="1.0" encoding="UTF-8"?>
      <Workspace
         version = "1.0">
         <FileRef
            location = "group:SharedLibraries/AppServices">
         </FileRef>
         <FileRef
            location = "group:SharedLibraries/CombineExtensions">
         </FileRef>
         <FileRef
            location = "container:Libraries/Theming">
         </FileRef>
      </Workspace>
      """
    XCTAssertEqual(
      Inventory.workspaceFileRefs(inContentsText: contents),
      [
        "SharedLibraries/AppServices", "SharedLibraries/CombineExtensions",
        "Libraries/Theming",
      ])
  }

  func testAWorkspaceWithNoFileRefsYieldsNothing() {
    let contents = """
      <?xml version="1.0" encoding="UTF-8"?>
      <Workspace version = "1.0">
      </Workspace>
      """
    XCTAssertEqual(Inventory.workspaceFileRefs(inContentsText: contents), [])
  }

  func testWorkspaceMembersAreExempt() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("duet-ws-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appendingPathComponent("SharedLibraries/Alpha")
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try manifest().write(
      to: package.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

    // Without a workspace the package is a finding; the workspace is the only
    // variable between the two halves of this test.
    XCTAssertTrue(Inventory.workspaceMemberPaths(under: root).isEmpty)

    let workspace = root.appendingPathComponent("AllTests.xcworkspace")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try """
      <?xml version="1.0" encoding="UTF-8"?>
      <Workspace version = "1.0">
         <FileRef location = "group:SharedLibraries/Alpha"></FileRef>
      </Workspace>
      """.write(
        to: workspace.appendingPathComponent("contents.xcworkspacedata"),
        atomically: true, encoding: .utf8)

    XCTAssertEqual(
      Inventory.workspaceMemberPaths(under: root),
      [package.standardizedFileURL.path])
  }

  /// A project's own `project.xcworkspace` is not an aggregate: the packages it
  /// references are dependencies of the project, not resolution roots, so being
  /// listed there does not mean anything ran their tests.
  func testAProjectsOwnWorkspaceIsNotAnAggregate() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("duet-proj-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = root.appendingPathComponent("App.xcodeproj/project.xcworkspace")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try """
      <?xml version="1.0" encoding="UTF-8"?>
      <Workspace version = "1.0">
         <FileRef location = "group:SharedLibraries/Alpha"></FileRef>
      </Workspace>
      """.write(
        to: workspace.appendingPathComponent("contents.xcworkspacedata"),
        atomically: true, encoding: .utf8)

    XCTAssertTrue(Inventory.workspaceMemberPaths(under: root).isEmpty)
  }

  // MARK: - the dependency spellings a manifest actually uses

  func testNamedRemoteDependencyIsRecognised() {
    let text = """
      let package = Package(
        name: "Example",
        dependencies: [
          .package(name: "Nimble", url: "https://github.com/Quick/Nimble.git", from: "14.0.0")
        ],
        targets: [.target(name: "Example"), .testTarget(name: "ExampleTests")]
      )
      """
    XCTAssertTrue(Inventory.declaresUnresolvedTests(manifestText: text, lockPresent: false))
  }

  func testRemoteDependencyBrokenOverLinesIsRecognised() {
    let text = """
      let package = Package(
        name: "Example",
        dependencies: [
          .package(
            url: "https://github.com/Quick/Quick.git",
            from: "7.6.2")
        ],
        targets: [.target(name: "Example"), .testTarget(name: "ExampleTests")]
      )
      """
    XCTAssertTrue(Inventory.declaresUnresolvedTests(manifestText: text, lockPresent: false))
  }
}
