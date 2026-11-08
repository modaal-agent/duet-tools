// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import XCTest

@testable import DuetCLI

/// `duet pins` reads a tree's family pins from its package manifests and
/// checks the exact-pin rule; `--latest` adds the network reads, which these
/// tests answer from a stub.
final class PinsTests: XCTestCase {

  struct StubRemote: Pins.Remote {
    var tags: [String: String] = [:]
    var duetPins: [String: String] = [:]
    var mocksProcessor: String? = nil

    func newestTag(repository: String, prefix: String) -> String? { tags[prefix + repository] }
    func pinnedDuet(repository: String, tag: String) -> String? { duetPins["\(repository)@\(tag)"] }
    func newestMocksProcessor() -> String? { mocksProcessor }
  }

  func makeTree(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("duet-pins-\(UUID().uuidString)")
    for (path, text) in files {
      let url = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
    }
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }

  let package = """
    // swift-tools-version:6.0
    import PackageDescription

    let package = Package(
      name: "App",
      dependencies: [
        .package(url: "https://github.com/modaal-agent/duet.git", exact: "0.7.0"),
        .package(
          url: "https://github.com/modaal-agent/duet-services.git",
          exact: "0.3.0"
        ),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
      ],
      targets: [.target(name: "App", dependencies: [.product(name: "Duet", package: "duet")])]
    )
    """

  let catalog = """
    [versions]
    kotlin = "2.2.20"
    duet = "0.7.0"
    duetServices = "0.3.0"
    mocksProcessor = "0.3.1"
    """

  let xcodegen = """
    name: App
    packages:
      Duet:
        exactVersion: 0.7.0
        url: https://github.com/modaal-agent/duet
      DuetServices:
        url: https://github.com/modaal-agent/duet-services.git
        exactVersion: "0.3.0"
    targets: {}
    """

  func testReadsEveryManifestKind() throws {
    let root = try makeTree([
      "Package.swift": package,
      "src-kmp/gradle/libs.versions.toml": catalog,
      "src-ios/App/project.yml": xcodegen,
      "parity/fixtures/.keep": "",
      "parity/duet-tools.ref": "# the toolchain\n0.37.0\n",
      "parity/manifest.yaml": "mocks:\n  bundle: 0.10.2   # the templates bundle\n",
    ])
    let pins = Pins.read(root: root)
    XCTAssertEqual(
      pins,
      [
        Pins.Pin(name: "duet", version: "0.7.0", kind: "exact", location: "Package.swift:7"),
        Pins.Pin(name: "duet-services", version: "0.3.0", kind: "exact", location: "Package.swift:8"),
        Pins.Pin(name: "duet", version: "0.7.0", kind: "exact", location: "src-ios/App/project.yml:5"),
        Pins.Pin(name: "duet-services", version: "0.3.0", kind: "exact", location: "src-ios/App/project.yml:7"),
        Pins.Pin(name: "duet", version: "0.7.0", kind: "exact", location: "src-kmp/gradle/libs.versions.toml"),
        Pins.Pin(
          name: "duet-services", version: "0.3.0", kind: "exact", location: "src-kmp/gradle/libs.versions.toml"),
        Pins.Pin(
          name: "mocks-processor", version: "0.3.1", kind: "exact", location: "src-kmp/gradle/libs.versions.toml"),
        Pins.Pin(name: "duet-tools", version: "0.37.0", kind: "exact", location: "parity/duet-tools.ref"),
        Pins.Pin(
          name: "mocks-bundle", version: "0.10.2", kind: "exact", location: "parity/manifest.yaml (mocks.bundle)"),
      ])
    XCTAssertEqual(Pins.localFindings(pins), [])
  }

  func testBuildOutputAndCheckoutsAreNotRead() throws {
    let root = try makeTree([
      "Package.swift": package,
      ".build/checkouts/duet-services/Package.swift":
        ".package(url: \"https://github.com/modaal-agent/duet.git\", exact: \"0.1.0\")",
      ".duet-family/duet/Package.swift":
        ".package(url: \"https://github.com/modaal-agent/duet-macros.git\", from: \"0.1.0\")",
    ])
    XCTAssertEqual(Pins.read(root: root).map(\.location), ["Package.swift:7", "Package.swift:8"])
  }

  func testRequirementKinds() {
    func kind(_ requirement: String) -> String {
      Pins.swiftManifestPins(
        ".package(url: \"https://github.com/modaal-agent/duet.git\", \(requirement))", location: "P"
      ).first.map { "\($0.kind) \($0.version)" } ?? "none"
    }
    XCTAssertEqual(kind("exact: \"0.7.0\""), "exact 0.7.0")
    XCTAssertEqual(kind(".exact(\"0.7.0\")"), "exact 0.7.0")
    XCTAssertEqual(kind("from: \"0.7.0\""), "from 0.7.0")
    XCTAssertEqual(kind(".upToNextMajor(from: \"0.7.0\")"), "upToNextMajor 0.7.0")
    XCTAssertEqual(kind(".upToNextMinor(from: \"0.7.0\")"), "upToNextMinor 0.7.0")
    XCTAssertEqual(kind("branch: \"main\""), "branch main")
    XCTAssertEqual(kind("revision: \"abc123\""), "revision abc123")
    XCTAssertEqual(kind("\"0.7.0\"..<\"0.8.0\""), "range 0.7.0")
  }

  func testAPinThatIsNotExactIsAFinding() throws {
    let root = try makeTree([
      "Package.swift": package.replacingOccurrences(of: "exact: \"0.3.0\"", with: "from: \"0.3.0\"")
    ])
    let report = Pins.report(root: root, latest: false, remote: StubRemote())
    XCTAssertEqual(
      report.findings, ["duet-services is pinned from 0.3.0 at Package.swift:8 — pin it exact"])
    XCTAssertTrue(Pins.render(report, latest: false).hasSuffix("duet pins: 1 disagreement(s)\n"))
  }

  func testAnXcodeGenPackageWithNoVersionKeyIsUnpinned() {
    let pins = Pins.xcodegenPins(
      "packages:\n  Duet:\n    url: https://github.com/modaal-agent/duet\n    path: ../duet\n", location: "project.yml")
    XCTAssertEqual(pins, [Pins.Pin(name: "duet", version: "?", kind: "unpinned", location: "project.yml:3")])
  }

  func testTwoVersionsOfOnePackageAreAFinding() throws {
    let root = try makeTree([
      "Package.swift": package,
      "gradle/libs.versions.toml": catalog.replacingOccurrences(of: "duet = \"0.7.0\"", with: "duet = \"0.6.0\""),
    ])
    XCTAssertEqual(
      Pins.report(root: root, latest: false, remote: StubRemote()).findings,
      ["duet is pinned at 0.7.0, 0.6.0 — move every pin of it to one version in the same change"])
  }

  func testLatestChecksTheDuetPinOfTheServicesRelease() throws {
    let root = try makeTree(["Package.swift": package])
    let remote = StubRemote(
      tags: [
        "duet": "0.8.0", "duet-tools": "0.37.0", "duet-services": "0.4.0", "duet-macros": "0.2.0",
        "duet-migration": "0.1.0", "templates-swift-sourcery-templates": "0.11.0",
      ],
      duetPins: ["duet-services@0.3.0": "0.6.0", "duet-services@0.4.0": "0.8.0", "duet-migration@0.1.0": "0.8.0"],
      mocksProcessor: "0.3.2")
    let report = Pins.report(root: root, latest: true, remote: remote)
    XCTAssertEqual(
      report.findings,
      ["duet-services 0.3.0 pins duet 0.6.0; the tree pins duet 0.7.0 — move both pins together"])
    let text = Pins.render(report, latest: true)
    XCTAssertTrue(text.contains("    duet-services 0.4.0 (pins duet 0.8.0)\n"), text)
    XCTAssertTrue(text.contains("    swift-sourcery-templates 0.11.0\n"), text)
    XCTAssertTrue(text.contains("    mocks-processor 0.3.2\n"), text)
  }

  func testLatestWithoutTheNetworkFails() throws {
    let root = try makeTree(["Package.swift": package])
    let findings = Pins.report(root: root, latest: true, remote: StubRemote()).findings
    XCTAssertEqual(findings.first, "could not read the duet pin of duet-services 0.3.0 (network?)")
    XCTAssertTrue(findings.contains("could not read the newest release of mocks-processor (network?)"))
  }

  func testATreeWithNoPinPasses() throws {
    let root = try makeTree(["README.md": "no packages\n"])
    let report = Pins.report(root: root, latest: false, remote: StubRemote())
    XCTAssertEqual(report.findings, [])
    XCTAssertEqual(
      Pins.render(report, latest: false), "duet pins: \(root.path)\n  no family pin found\nduet pins: OK\n")
  }

  func testNewestSemverReadsTheLsRemoteOutput() {
    let output = """
      aaa\trefs/tags/0.9.0
      bbb\trefs/tags/0.10.2
      ccc\trefs/tags/templates-0.11.0
      ddd\trefs/tags/0.10.2-rc1
      """
    XCTAssertEqual(Pins.newestSemver(inLsRemote: output, prefix: ""), "0.10.2")
    XCTAssertEqual(Pins.newestSemver(inLsRemote: output, prefix: "templates-"), "0.11.0")
  }

  func testJSONReport() throws {
    let root = try makeTree(["parity/duet-tools.ref": "0.37.0\n"])
    let object = Pins.json(Pins.report(root: root, latest: false, remote: StubRemote()))
    XCTAssertEqual(object["status"] as? String, "passed")
    XCTAssertEqual((object["pins"] as? [[String: String]])?.first?["name"], "duet-tools")
    XCTAssertNil(object["newest"])
  }
}
