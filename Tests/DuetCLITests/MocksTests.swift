// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import Foundation
import XCTest

@testable import DuetCLI

/// `duet mocks` source-root derivation for a family URL pin.
///
/// The subject is `familyClone`: it decides both WHERE a pinned family
/// package is scanned from (the path the fingerprint records) and WHETHER a
/// checkout already on disk may supply the content. Those two are separable
/// and were once conflated, so each has its own case here.
final class MocksTests: XCTestCase {

  // MARK: - Harness

  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("duet-mocks-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root!) }
  }

  private var repo: Repo { Repo(root: root) }

  private var stablePrefix: URL { root.appendingPathComponent(".build/duet-sources/duet") }

  private var checkout: URL {
    root.appendingPathComponent(".build/SourcePackages/checkouts/duet")
  }

  @discardableResult
  private func git(_ arguments: [String], in directory: URL) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    // Identity and signing on the command line: the suite must not depend on
    // whatever the developer's or runner's global git config carries.
    process.arguments = ["git", "-c", "user.name=duet", "-c", "user.email=duet@example.com",
                         "-c", "commit.gpgsign=false", "-C", directory.path] + arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }

  /// A git repository whose `swift/Sources/Marker.swift` names its origin, at
  /// one tag per entry in `tags` (each tag re-writes the marker, so content
  /// and tag identify each other).
  @discardableResult
  private func makeRepository(at directory: URL, tags: [String: String]) throws -> URL {
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("swift/Sources"), withIntermediateDirectories: true)
    XCTAssertEqual(try git(["init", "--quiet", "-b", "main"], in: directory), 0)
    for (tag, marker) in tags.sorted(by: { $0.key < $1.key }) {
      try Data("let marker = \"\(marker)\"\n".utf8)
        .write(to: directory.appendingPathComponent("swift/Sources/Marker.swift"))
      XCTAssertEqual(try git(["add", "."], in: directory), 0)
      XCTAssertEqual(try git(["commit", "--quiet", "-m", tag], in: directory), 0)
      XCTAssertEqual(try git(["tag", tag], in: directory), 0)
    }
    return directory
  }

  private func marker(in clone: URL) throws -> String {
    try String(contentsOf: clone.appendingPathComponent("swift/Sources/Marker.swift"),
               encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// A path no clone can reach — the assertion that an origin went unused.
  private var unreachableRemote: String { root.appendingPathComponent("no-such-remote").path }

  // MARK: - Cases

  func testClonesThePinIntoTheStablePrefixWhenNoCheckoutExists() throws {
    let remote = try makeRepository(
      at: root.appendingPathComponent("remote"), tags: ["0.1.0": "from-remote"])

    let source = try Mocks.familyClone(
      identity: "duet", url: remote.path, version: "0.1.0", repo: repo)

    XCTAssertEqual(source.standardizedFileURL, stablePrefix.standardizedFileURL)
    XCTAssertEqual(try marker(in: source), "let marker = \"from-remote\"")
  }

  /// The checkout supplies the content — no remote is reachable — and the
  /// scan root is still the recorded prefix. Scanning the checkout in place
  /// would key the fingerprint's input paths to whether the repo happened to
  /// have been built locally.
  func testCheckoutAtThePinIsTheCloneOriginNotTheScanRoot() throws {
    try makeRepository(at: checkout, tags: ["0.1.0": "from-checkout"])

    let source = try Mocks.familyClone(
      identity: "duet", url: unreachableRemote, version: "0.1.0", repo: repo)

    XCTAssertEqual(source.standardizedFileURL, stablePrefix.standardizedFileURL)
    XCTAssertEqual(try marker(in: source), "let marker = \"from-checkout\"")
  }

  /// A checkout left behind by an older resolve carries different content
  /// under the same path, so the pin — not the directory's existence — is
  /// what decides.
  func testCheckoutOffThePinIsIgnored() throws {
    try makeRepository(at: checkout, tags: ["0.1.0": "from-checkout"])
    let remote = try makeRepository(
      at: root.appendingPathComponent("remote"),
      tags: ["0.1.0": "remote-0.1.0", "0.2.0": "remote-0.2.0"])

    let source = try Mocks.familyClone(
      identity: "duet", url: remote.path, version: "0.2.0", repo: repo)

    XCTAssertEqual(source.standardizedFileURL, stablePrefix.standardizedFileURL)
    XCTAssertEqual(try marker(in: source), "let marker = \"remote-0.2.0\"")
  }

  func testCloneAlreadyAtThePinIsReusedWithoutAnOrigin() throws {
    let remote = try makeRepository(
      at: root.appendingPathComponent("remote"), tags: ["0.1.0": "from-remote"])
    _ = try Mocks.familyClone(identity: "duet", url: remote.path, version: "0.1.0", repo: repo)
    try FileManager.default.removeItem(at: remote)

    let source = try Mocks.familyClone(
      identity: "duet", url: remote.path, version: "0.1.0", repo: repo)

    XCTAssertEqual(source.standardizedFileURL, stablePrefix.standardizedFileURL)
    XCTAssertEqual(try marker(in: source), "let marker = \"from-remote\"")
  }

  func testCloneOffThePinIsReplaced() throws {
    let remote = try makeRepository(
      at: root.appendingPathComponent("remote"),
      tags: ["0.1.0": "remote-0.1.0", "0.2.0": "remote-0.2.0"])
    _ = try Mocks.familyClone(identity: "duet", url: remote.path, version: "0.1.0", repo: repo)

    let source = try Mocks.familyClone(
      identity: "duet", url: remote.path, version: "0.2.0", repo: repo)

    XCTAssertEqual(try marker(in: source), "let marker = \"remote-0.2.0\"")
  }

  func testUnreachablePinIsANamedError() throws {
    XCTAssertThrowsError(
      try Mocks.familyClone(
        identity: "duet", url: unreachableRemote, version: "0.1.0", repo: repo)
    ) { error in
      XCTAssertTrue(
        "\(error)".contains("could not clone duet@0.1.0"), "unexpected message: \(error)")
    }
  }

  /// The whole path, manifest to scan root: a repo that has been built
  /// locally carries a resolved checkout, and the roots must not move to it.
  /// This is what fired in a consumer — every recorded input read as
  /// `unlisted` because the enumeration had shifted prefix.
  ///
  /// The manifest's URL is unresolvable on purpose: reaching it would mean
  /// the checkout at the pin had not been used as the clone origin.
  func testDerivedRootsIgnoreAResolvedCheckoutForThePath() throws {
    try makeRepository(at: checkout, tags: ["0.1.0": "pinned"])
    let consumer = root.appendingPathComponent("consumer")
    try FileManager.default.createDirectory(
      at: consumer.appendingPathComponent("Sources/Consumer"), withIntermediateDirectories: true)
    try Data("""
      // swift-tools-version: 6.0
      import PackageDescription

      let package = Package(
        name: "Consumer",
        dependencies: [.package(url: "https://example.invalid/duet", exact: "0.1.0")],
        targets: [.target(name: "Consumer")]
      )

      """.utf8).write(to: consumer.appendingPathComponent("Package.swift"))

    let roots = try Mocks.derivedRoots(packageRelative: "consumer", repo: repo)

    XCTAssertEqual(
      roots.map(\.standardizedFileURL),
      [stablePrefix.appendingPathComponent("swift/Sources").standardizedFileURL])
  }

  func testExactTagAnswersNilForANonRepository() throws {
    XCTAssertNil(Mocks.exactTag(at: root.appendingPathComponent("nowhere"), repo: repo))
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("plain"), withIntermediateDirectories: true)
    XCTAssertNil(Mocks.exactTag(at: root.appendingPathComponent("plain"), repo: repo))
  }

  func testExactTagAnswersNilForAnUntaggedCommit() throws {
    let repository = try makeRepository(
      at: root.appendingPathComponent("remote"), tags: ["0.1.0": "tagged"])
    try Data("let extra = 1\n".utf8)
      .write(to: repository.appendingPathComponent("swift/Sources/Extra.swift"))
    XCTAssertEqual(try git(["add", "."], in: repository), 0)
    XCTAssertEqual(try git(["commit", "--quiet", "-m", "untagged"], in: repository), 0)

    XCTAssertNil(Mocks.exactTag(at: repository, repo: repo))
  }
}
