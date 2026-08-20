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

  /// A git repository whose `swift/Sources/Duet/Marker.swift` names its
  /// origin, at one tag per entry in `tags` (each tag re-writes the marker, so
  /// content and tag identify each other).
  ///
  /// It is a real package, manifest included: the derivation asks a scanned
  /// dependency for its own layout, so a fixture without a manifest is a
  /// package no consumer could resolve either.
  @discardableResult
  private func makeRepository(at directory: URL, tags: [String: String]) throws -> URL {
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("swift/Sources/Duet"),
      withIntermediateDirectories: true)
    try Data("""
      // swift-tools-version: 6.0
      import PackageDescription

      let package = Package(
        name: "duet",
        products: [.library(name: "Duet", targets: ["Duet"])],
        targets: [.target(name: "Duet", path: "swift/Sources/Duet")]
      )

      """.utf8).write(to: directory.appendingPathComponent("Package.swift"))
    XCTAssertEqual(try git(["init", "--quiet", "-b", "main"], in: directory), 0)
    for (tag, marker) in tags.sorted(by: { $0.key < $1.key }) {
      try Data("let marker = \"\(marker)\"\n".utf8)
        .write(to: directory.appendingPathComponent("swift/Sources/Duet/Marker.swift"))
      XCTAssertEqual(try git(["add", "."], in: directory), 0)
      XCTAssertEqual(try git(["commit", "--quiet", "-m", tag], in: directory), 0)
      XCTAssertEqual(try git(["tag", tag], in: directory), 0)
    }
    return directory
  }

  private func marker(in clone: URL) throws -> String {
    try String(contentsOf: clone.appendingPathComponent("swift/Sources/Duet/Marker.swift"),
               encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The services package as both dependency-form fixtures declare it: two
  /// products, one target each, under the `swift/` layout the repo ships.
  private let servicesManifest = """
    // swift-tools-version: 6.0
    import PackageDescription

    let package = Package(
      name: "duet-services",
      products: [
        .library(name: "DuetTelemetry", targets: ["DuetTelemetry"]),
        .library(name: "DuetAppServices", targets: ["DuetAppServices"]),
      ],
      targets: [
        .target(name: "DuetTelemetry", path: "swift/Sources/DuetTelemetry"),
        .target(name: "DuetAppServices", path: "swift/Sources/DuetAppServices"),
      ]
    )

    """

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
      [stablePrefix.appendingPathComponent("swift/Sources/Duet").standardizedFileURL])
  }

  /// The services package keeps its Swift half under `swift/`, and the
  /// derivation scans it per LINKED product: the linked product's directory
  /// is a root, an unlinked product's is not.
  func testDerivedRootsScanTheServicesSwiftLayoutPerLinkedProduct() throws {
    let services = root.appendingPathComponent("duet-services")
    for product in ["DuetTelemetry", "DuetAppServices"] {
      let directory = services.appendingPathComponent("swift/Sources/\(product)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data("public let marker = \"\(product)\"\n".utf8)
        .write(to: directory.appendingPathComponent("Marker.swift"))
    }
    try Data(servicesManifest.utf8).write(to: services.appendingPathComponent("Package.swift"))

    let consumer = root.appendingPathComponent("consumer")
    try FileManager.default.createDirectory(
      at: consumer.appendingPathComponent("Sources/Consumer"), withIntermediateDirectories: true)
    try Data("""
      // swift-tools-version: 6.0
      import PackageDescription

      let package = Package(
        name: "Consumer",
        dependencies: [.package(path: "../duet-services")],
        targets: [
          .target(
            name: "Consumer",
            dependencies: [.product(name: "DuetTelemetry", package: "duet-services")]
          )
        ]
      )

      """.utf8).write(to: consumer.appendingPathComponent("Package.swift"))

    let roots = try Mocks.derivedRoots(packageRelative: "consumer", repo: repo)

    XCTAssertEqual(
      roots.map(\.standardizedFileURL),
      [services.appendingPathComponent("swift/Sources/DuetTelemetry").standardizedFileURL])
  }

  /// The same `swift/Sources` reading through the OTHER dependency form: a
  /// URL pin at an exact version. The scan roots land under the clone's
  /// `swift/Sources`, per linked product — the unlinked product's directory
  /// is not a root.
  ///
  /// The manifest's URL is unresolvable on purpose (as in the case above):
  /// the checkout sitting on the pin is what supplies the content, and the
  /// recorded prefix is the clone's, never the checkout's.
  func testDerivedRootsScanTheServicesSwiftLayoutForAURLPin() throws {
    let checkout = root.appendingPathComponent(
      ".build/SourcePackages/checkouts/duet-services")
    for product in ["DuetTelemetry", "DuetAppServices"] {
      try FileManager.default.createDirectory(
        at: checkout.appendingPathComponent("swift/Sources/\(product)"),
        withIntermediateDirectories: true)
      try Data("public let marker = \"\(product)\"\n".utf8)
        .write(to: checkout.appendingPathComponent("swift/Sources/\(product)/Marker.swift"))
    }
    try Data(servicesManifest.utf8).write(to: checkout.appendingPathComponent("Package.swift"))
    XCTAssertEqual(try git(["init", "--quiet", "-b", "main"], in: checkout), 0)
    XCTAssertEqual(try git(["add", "."], in: checkout), 0)
    XCTAssertEqual(try git(["commit", "--quiet", "-m", "0.4.0"], in: checkout), 0)
    XCTAssertEqual(try git(["tag", "0.4.0"], in: checkout), 0)

    let consumer = root.appendingPathComponent("consumer")
    try FileManager.default.createDirectory(
      at: consumer.appendingPathComponent("Sources/Consumer"), withIntermediateDirectories: true)
    try Data("""
      // swift-tools-version: 6.0
      import PackageDescription

      let package = Package(
        name: "Consumer",
        dependencies: [
          .package(url: "https://example.invalid/duet-services", exact: "0.4.0")
        ],
        targets: [
          .target(
            name: "Consumer",
            dependencies: [.product(name: "DuetTelemetry", package: "duet-services")]
          )
        ]
      )

      """.utf8).write(to: consumer.appendingPathComponent("Package.swift"))

    let roots = try Mocks.derivedRoots(packageRelative: "consumer", repo: repo)

    let clone = root.appendingPathComponent(".build/duet-sources/duet-services")
    XCTAssertEqual(
      roots.map(\.standardizedFileURL),
      [clone.appendingPathComponent("swift/Sources/DuetTelemetry").standardizedFileURL])
  }

  /// A path dependency's roots come from ITS manifest, not from a directory
  /// name this tool knows: the target sits at a `path:` of the package's
  /// choosing, and the test target its author parked under `Sources/` is not a
  /// root — a spec declares no port, and hashing one turns an unrelated test
  /// edit into a `mocks --check` failure in the consumer.
  func testDerivedRootsFollowADependencysOwnLayoutAndSkipItsTestTarget() throws {
    let widget = root.appendingPathComponent("widget")
    for (directory, file) in [("libs/Widget", "Widget.swift"),
                              ("Sources/WidgetTests", "WidgetSpec.swift")] {
      let url = widget.appendingPathComponent(directory)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try Data("let marker = \"\(directory)\"\n".utf8)
        .write(to: url.appendingPathComponent(file))
    }
    try Data("""
      // swift-tools-version: 6.0
      import PackageDescription

      let package = Package(
        name: "Widget",
        products: [.library(name: "Widget", targets: ["Widget"])],
        targets: [
          .target(name: "Widget", path: "libs/Widget"),
          .testTarget(name: "WidgetTests", path: "Sources/WidgetTests"),
        ]
      )

      """.utf8).write(to: widget.appendingPathComponent("Package.swift"))

    let consumer = root.appendingPathComponent("consumer")
    try FileManager.default.createDirectory(
      at: consumer.appendingPathComponent("Sources/Consumer"), withIntermediateDirectories: true)
    try Data("""
      // swift-tools-version: 6.0
      import PackageDescription

      let package = Package(
        name: "Consumer",
        dependencies: [.package(path: "../widget")],
        targets: [
          .target(name: "Consumer", dependencies: [.product(name: "Widget", package: "Widget")])
        ]
      )

      """.utf8).write(to: consumer.appendingPathComponent("Package.swift"))

    let roots = try Mocks.derivedRoots(packageRelative: "consumer", repo: repo)

    XCTAssertEqual(
      roots.map(\.standardizedFileURL),
      [widget.appendingPathComponent("libs/Widget").standardizedFileURL])
  }

  /// A dependency path that holds no package is a named failure, not a silent
  /// contribution of no roots: a mock generated over a scan that skipped a
  /// package compiles here and fails in the consumer's test target.
  ///
  /// The dependency sits INSIDE the consumer package, which is the case that
  /// bites: `swift package` searches ancestors for a manifest when the
  /// directory it is pointed at carries none, so describing this path without
  /// the check answers with the CONSUMER's own layout — a scan of the wrong
  /// tree, reported as a success.
  func testADependencyPathHoldingNoPackageIsANamedError() throws {
    let consumer = root.appendingPathComponent("consumer")
    try FileManager.default.createDirectory(
      at: consumer.appendingPathComponent("Sources/Consumer"), withIntermediateDirectories: true)
    try Data("let marker = \"consumer\"\n".utf8)
      .write(to: consumer.appendingPathComponent("Sources/Consumer/Marker.swift"))
    try FileManager.default.createDirectory(
      at: consumer.appendingPathComponent("ghost"), withIntermediateDirectories: true)
    try Data("""
      // swift-tools-version: 6.0
      import PackageDescription

      let package = Package(
        name: "Consumer",
        dependencies: [.package(name: "ghost", path: "ghost")],
        targets: [.target(name: "Consumer")]
      )

      """.utf8).write(to: consumer.appendingPathComponent("Package.swift"))

    XCTAssertThrowsError(try Mocks.derivedRoots(packageRelative: "consumer", repo: repo)) { error in
      XCTAssertTrue("\(error)".contains("no Package.swift at"), "unexpected message: \(error)")
    }
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
