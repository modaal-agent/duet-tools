// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import XCTest

@testable import DuetCLI

/// `protocol-run --platform`: the values it takes, and which features and
/// chains each side's runner is checked against.
final class ProtocolLaneTests: XCTestCase {

  // MARK: - The flag

  func testThePlatformValues() {
    XCTAssertEqual(ProtocolLane.selection(platform: nil, runner: nil), .defaultRunner)
    XCTAssertEqual(ProtocolLane.selection(platform: nil, runner: "/bin/r"), .defaultRunner)
    XCTAssertEqual(ProtocolLane.selection(platform: "swift", runner: nil), .sides([.swift]))
    XCTAssertEqual(ProtocolLane.selection(platform: "kotlin", runner: "/bin/r"), .sides([.kotlin]))
    // Swift first, then Kotlin.
    XCTAssertEqual(ProtocolLane.selection(platform: "both", runner: nil), .sides([.swift, .kotlin]))
  }

  func testAnUnknownValueIsAUsageError() {
    XCTAssertEqual(
      ProtocolLane.selection(platform: "all", runner: nil),
      .usage("--platform takes swift, kotlin or both, got 'all'"))
  }

  func testRunnerWithBothIsAUsageError() {
    XCTAssertEqual(
      ProtocolLane.selection(platform: "both", runner: "/bin/r"),
      .usage(
        "--runner drives one prebuilt runner and --platform both builds the repo's two;"
          + " pass one or the other"))
  }

  func testUsageErrorsExitTwoBeforeTheManifestIsRead() throws {
    // An empty directory: no manifest to load, so reaching it would throw.
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("duet-protocol-usage-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    var options = Options()
    options.command = "protocol-run"
    options.platform = "all"
    XCTAssertEqual(try ProtocolLane.run(repo: Repo(root: root), options: options), 2)
    options.platform = "both"
    options.runner = "/usr/bin/true"
    XCTAssertEqual(try ProtocolLane.run(repo: Repo(root: root), options: options), 2)
  }

  // MARK: - Coverage on the twins tree

  private func coverage(_ side: ProtocolLane.Side?, _ repo: Repo) throws -> ProtocolLane.Coverage {
    let manifest = try Manifest.load(repo: repo)
    return ProtocolLane.coverage(
      side: side, manifest: manifest,
      participants: { Lanes.chainParticipants(of: $0, in: repo) })
  }

  func testTheKotlinRunnerGetsTheKotlinTwinsOnly() throws {
    let repo = try makeMiniTree("mini-twins")
    let kotlin = try coverage(.kotlin, repo)
    XCTAssertEqual(kotlin.features.map(\.name), ["greeter"])
    XCTAssertEqual(kotlin.featuresNotSent, ["profile"])
    // The chain spans the Swift-only row, so the Kotlin runner cannot serve it.
    XCTAssertEqual(kotlin.chains, [])
    XCTAssertEqual(kotlin.chainsNotSent, ["greeter.handoff"])
  }

  func testTheSwiftRunnerGetsEveryRowWithASwiftTwin() throws {
    let repo = try makeMiniTree("mini-twins")
    let swift = try coverage(.swift, repo)
    XCTAssertEqual(swift.features.map(\.name), ["greeter", "profile"])
    XCTAssertEqual(swift.chains, ["greeter.handoff"])
    XCTAssertEqual(swift.featuresNotSent, [])
    XCTAssertEqual(swift.chainsNotSent, [])
  }

  func testTheDefaultRunnerGetsEverything() throws {
    let repo = try makeMiniTree("mini-twins")
    let all = try coverage(nil, repo)
    XCTAssertEqual(all.features.map(\.name), ["greeter", "profile"])
    XCTAssertEqual(all.chains, ["greeter.handoff"])
    XCTAssertEqual(all.featuresNotSent + all.chainsNotSent, [])
  }

  func testPendingSidesAndUnknownParticipants() {
    func feature(_ name: String, swift: String, kotlin: String) -> Feature {
      Feature(
        name: name, swiftSource: swift, kotlinSource: kotlin, stateType: "S", actionType: "A",
        payloadType: "P", scenario: nil, fixtures: [name])
    }
    let manifest = Manifest(
      features: [
        feature(
          "ported", swift: "pending",
          kotlin: "src-android/subtrees/ported/logic/src/main/kotlin/x/PortedFeature.kt"),
        feature(
          "unported", swift: "src-ios/Subtrees/Unported/UnportedFeature/Sources/UnportedFeature/U.swift",
          kotlin: "pending"),
      ],
      chains: ["ported.solo", "ported.unported"], lintOK: true, lintErrors: [],
      swiftPackageDirs: [], androidDir: URL(fileURLWithPath: "/repo/src-android"),
      replayRunnerRelative: nil, mocksBundle: nil, mockGenerators: [],
      featuresBlockEmpty: false, repoRoot: URL(fileURLWithPath: "/repo"))
    let participants: (String) -> Set<String> = {
      // `aggregate` is no feature of the manifest: it does not hold a chain
      // back (the coverage rule `verify` follows).
      $0 == "ported.solo" ? ["ported", "aggregate"] : ["ported", "unported"]
    }
    let swift = ProtocolLane.coverage(side: .swift, manifest: manifest, participants: participants)
    XCTAssertEqual(swift.features.map(\.name), ["unported"])
    XCTAssertEqual(swift.chainsNotSent, ["ported.solo", "ported.unported"])
    let kotlin = ProtocolLane.coverage(side: .kotlin, manifest: manifest, participants: participants)
    XCTAssertEqual(kotlin.features.map(\.name), ["ported"])
    XCTAssertEqual(kotlin.chains, ["ported.solo"])
    XCTAssertEqual(kotlin.chainsNotSent, ["ported.unported"])
  }

  // MARK: - The verb with a prebuilt runner

  /// A conforming runner that advertises `features` and answers nothing else
  /// — the twins tree's fixtures carry no steps, so the run sends no reduce.
  private func standInRunner(advertising features: [String]) throws -> String {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("duet-protocol-runner-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    let list = features.map { "\"\($0)\"" }.joined(separator: ",")
    let script = dir.appendingPathComponent("replay-runner")
    try Data(
      """
      #!/bin/sh
      echo '{"protocol":"duet-replay","version":1,"features":[\(list)]}'
      while read -r line; do
        case "$line" in *'"exit"'*) exit 0 ;; esac
        echo '{"error":"no reduce expected"}'
      done
      """.utf8
    ).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script.path
  }

  private func protocolRun(_ repo: Repo, platform: String?, runner: String) throws -> Int32 {
    var options = Options()
    options.command = "protocol-run"
    options.platform = platform
    options.runner = runner
    return try ProtocolLane.run(repo: repo, options: options)
  }

  func testAKotlinRunnerWithoutTheSwiftOnlyRowPasses() throws {
    // The Kotlin runner serves the Kotlin twins only; the Swift-only row and
    // the chain over it are not sent to it.
    let repo = try makeMiniTree("mini-twins")
    let runner = try standInRunner(advertising: ["greeter"])
    XCTAssertEqual(try protocolRun(repo, platform: "kotlin", runner: runner), 0)
  }

  func testTheSameRunnerAsTheSwiftSideFailsOnTheRowItLacks() throws {
    let repo = try makeMiniTree("mini-twins")
    let runner = try standInRunner(advertising: ["greeter"])
    XCTAssertEqual(try protocolRun(repo, platform: "swift", runner: runner), 1)
    // Without --platform the runner is checked against every row, as before.
    XCTAssertEqual(try protocolRun(repo, platform: nil, runner: runner), 1)
  }

  func testAKotlinRunnerMissingAKotlinTwinFails() throws {
    let repo = try makeMiniTree("mini-twins")
    let runner = try standInRunner(advertising: [])
    XCTAssertEqual(try protocolRun(repo, platform: "kotlin", runner: runner), 1)
  }

  func testTheFailureNamesTheRunnerItCameFrom() throws {
    let repo = try makeMiniTree("mini-twins")
    let executable = URL(fileURLWithPath: try standInRunner(advertising: ["profile"]))
    let client = try ProtocolLane.RunnerClient(executable: executable)
    let handshake = try XCTUnwrap(try client.readLine())
    var result = ProtocolLane.RunnerResult(
      side: .kotlin, executable: executable, version: 1,
      advertised: Set(handshake["features"] as? [String] ?? []),
      coverage: try coverage(.kotlin, repo))
    try ProtocolLane.drive(client, &result, repo: repo)
    client.exit()
    // `profile` is advertised but not sent: it declares no Kotlin side.
    XCTAssertEqual(result.failures, ["greeter: not advertised by the kotlin runner"])
    XCTAssertEqual(result.fixturesRun, 0)
    XCTAssertEqual(result.chainsRun, 0)
  }
}
