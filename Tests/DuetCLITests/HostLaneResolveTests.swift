// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import XCTest

@testable import DuetCLI

/// Check 1 of the host-lane rule on a root with no `Package.resolved`: a
/// manifest tree with no remote declaration passes without a resolve; one
/// with a remote declaration is resolved in place and the file that wrote is
/// what the check reads. The remote dependency is a local git repository
/// reached by `file://` URL, so nothing here needs the network.
final class HostLaneResolveTests: XCTestCase {

  private var scratch: URL!

  override func setUpWithError() throws {
    scratch = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("duet-resolve-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: scratch)
  }

  private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  @discardableResult
  private func git(_ arguments: [String], in dir: URL) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments =
      ["git", "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"]
      + arguments
    process.currentDirectoryURL = dir
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }

  /// A tagged library package at `<scratch>/dep`, the remote the root pins.
  private func makeDependencyRepo() throws -> URL {
    let dep = scratch.appendingPathComponent("dep")
    try write(
      """
      // swift-tools-version:5.9
      import PackageDescription
      let package = Package(
        name: "dep",
        products: [.library(name: "Dep", targets: ["Dep"])],
        targets: [.target(name: "Dep")]
      )
      """, to: dep.appendingPathComponent("Package.swift"))
    try write("public enum Dep {}\n", to: dep.appendingPathComponent("Sources/Dep/Dep.swift"))
    XCTAssertEqual(try git(["init", "-q", "-b", "main"], in: dep), 0)
    XCTAssertEqual(try git(["add", "-A"], in: dep), 0)
    XCTAssertEqual(try git(["commit", "-qm", "1.0.0"], in: dep), 0)
    XCTAssertEqual(try git(["tag", "1.0.0"], in: dep), 0)
    return dep
  }

  private func makeRoot(dependencies: String) throws -> (Repo, String) {
    let repo = scratch.appendingPathComponent("repo")
    let root = "src-ios/Subtrees/Sample/SampleFeature"
    try write(
      """
      // swift-tools-version:5.9
      import PackageDescription
      let package = Package(
        name: "SampleFeature",
        products: [.library(name: "SampleFeature", targets: ["SampleFeature"])],
        dependencies: [
          \(dependencies)
        ],
        targets: [.target(name: "SampleFeature")]
      )
      """, to: repo.appendingPathComponent(root).appendingPathComponent("Package.swift"))
    try write(
      "public enum SampleFeature {}\n",
      to: repo.appendingPathComponent(root)
        .appendingPathComponent("Sources/SampleFeature/SampleFeature.swift"))
    try FileManager.default.createDirectory(
      at: repo.appendingPathComponent("parity/fixtures"), withIntermediateDirectories: true)
    return (Repo(root: repo), root)
  }

  func testARootWithNoRemoteDeclarationIsNotResolved() throws {
    let local = scratch.appendingPathComponent("repo/src-ios/Libraries/Local")
    try write(
      """
      // swift-tools-version:5.9
      import PackageDescription
      let package = Package(name: "Local", targets: [.target(name: "Local")])
      """, to: local.appendingPathComponent("Package.swift"))
    let (repo, root) = try makeRoot(
      dependencies: #".package(name: "Local", path: "../../../Libraries/Local"),"#)

    var errors: [String] = []
    HostLane.checkSwiftRootLock(root, repo: repo, errors: &errors)

    XCTAssertEqual(errors, [])
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: repo.root.appendingPathComponent(root).appendingPathComponent("Package.resolved")
          .path))
  }

  func testARootWithARemoteDeclarationIsResolvedAndItsResolvedSetRead() throws {
    let dep = try makeDependencyRepo()
    let (repo, root) = try makeRoot(
      dependencies: #".package(url: "file://\#(dep.path)", from: "1.0.0"),"#)
    let lock = repo.root.appendingPathComponent(root).appendingPathComponent("Package.resolved")
    XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))

    var errors: [String] = []
    HostLane.checkSwiftRootLock(root, repo: repo, errors: &errors)

    XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path), "the resolve wrote the lockfile")
    XCTAssertEqual(errors.count, 1)
    XCTAssertTrue(errors[0].contains("outside the allowlist"), errors[0])
    XCTAssertTrue(errors[0].contains("\"dep\""), errors[0])
  }

  func testAResolveThatFailsIsAnErrorNamingTheResolve() throws {
    let missing = scratch.appendingPathComponent("no-such-repo").path
    let (repo, root) = try makeRoot(
      dependencies: #".package(url: "file://\#(missing)", from: "1.0.0"),"#)

    var errors: [String] = []
    HostLane.checkSwiftRootLock(root, repo: repo, errors: &errors)

    XCTAssertEqual(errors.count, 1)
    XCTAssertTrue(errors[0].contains("`swift package resolve` there failed"), errors[0])
  }
}
