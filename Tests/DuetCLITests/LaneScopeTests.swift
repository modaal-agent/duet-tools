// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import XCTest

@testable import DuetCLI

/// What a scoped run derives: the Gradle tasks a `--feature` scope owns, and
/// the lane flags checked against that scope rather than against the whole
/// manifest.
final class LaneScopeTests: XCTestCase {

  private func feature(name: String, swift: String, kotlin: String) -> Feature {
    Feature(
      name: name, swiftSource: swift, kotlinSource: kotlin,
      stateType: "\(name.capitalized)State", actionType: "\(name.capitalized)Action",
      payloadType: "\(name.capitalized)EffectPayload",
      scenario: nil, fixtures: ["\(name).save"])
  }

  /// A mixed manifest — the per-feature migration window: one row already
  /// crossed, one still Swift-only.
  private func mixedManifest() -> Manifest {
    let crossed = feature(
      name: "capture", swift: "",
      kotlin: "src-kmp/subtrees/capture/logic/src/commonMain/kotlin/com/x/CaptureFeature.kt")
    let uncrossed = feature(
      name: "traillog",
      swift: "src-ios/Subtrees/TrailLog/Sources/TrailLog/TrailLogFeature.swift", kotlin: "")
    return Manifest(
      features: [crossed, uncrossed], chains: [], lintOK: true, lintErrors: [],
      swiftPackageDirs: [URL(fileURLWithPath: "/repo/src-ios/Subtrees/TrailLog")],
      androidDir: URL(fileURLWithPath: "/repo/src-kmp"),
      replayRunnerRelative: nil, mocksBundle: nil, mockGenerators: [],
      repoRoot: URL(fileURLWithPath: "/repo"))
  }

  // MARK: - The scope's Gradle tasks

  func testAScopeWithNoKotlinTwinDerivesNoGradleTask() throws {
    let manifest = mixedManifest()
    let uncrossed = try XCTUnwrap(manifest.feature(named: "traillog"))
    // The defect this pins: the fallback ran the unscoped set here, so
    // `verify --feature traillog` ran every Kotlin module's suites — including
    // `:app`'s, which needs an Android SDK location.
    XCTAssertEqual(manifest.gradleTasks(scope: uncrossed), [])
    XCTAssertEqual(manifest.unscopedGradleTasks, [":subtrees:capture:logic:jvmTest"])
  }

  func testAScopeWithAKotlinTwinDerivesItsOwnTask() throws {
    let manifest = mixedManifest()
    let crossed = try XCTUnwrap(manifest.feature(named: "capture"))
    XCTAssertEqual(manifest.gradleTasks(scope: crossed), [":subtrees:capture:logic:jvmTest"])
  }

  func testAnUnscopedRunTakesEveryFeaturesOwnModuleTask() {
    // The unqualified names this used to run (`test jvmTest`) reach every
    // module in the tree, declared or not: on a repo carrying an Android
    // application module, `test` reaches `:app:testDebugUnitTest`, which
    // cannot configure without an SDK location.
    XCTAssertEqual(
      mixedManifest().gradleTasks(scope: nil), [":subtrees:capture:logic:jvmTest"])
  }

  func testTheLaneFamilyStaysUnqualifiedForTheLint() {
    // The family a repo's own `./gradlew` line must name to reach every
    // declared module — the shape lint's expectation, unchanged.
    XCTAssertEqual(mixedManifest().laneFamilyTasks, ["test", "jvmTest"])
  }

  func testAFeaturelessManifestDerivesNoUnscopedTask() {
    let manifest = Manifest(
      features: [], chains: [], lintOK: true, lintErrors: [],
      swiftPackageDirs: [], androidDir: URL(fileURLWithPath: "/repo/src-kmp"),
      replayRunnerRelative: nil, mocksBundle: nil, mockGenerators: [],
      repoRoot: URL(fileURLWithPath: "/repo"))
    // A Kotlin-shaped repo's day-0 state: nothing to replay, so the lane is
    // skipped. The family pick returned `test` here, which is `:app`'s.
    XCTAssertEqual(manifest.unscopedGradleTasks, [])
    XCTAssertEqual(manifest.laneFamilyTasks, ["test"])
  }

  /// A tree whose chain replay lives in a module no feature declares — the
  /// aggregator shape. Written to a temp directory because the chain host is
  /// DISCOVERED from test sources, not declared.
  private func chainTree() throws -> Repo {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("duet-lane-scope-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    func write(_ relative: String, _ contents: String) throws {
      let url = root.appendingPathComponent(relative)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(contents.utf8).write(to: url)
    }
    try write(
      "parity/manifest.yaml",
      """
      features:
        counter:
          kotlin: src-kmp/subtrees/counter/logic/src/commonMain/kotlin/com/x/CounterFeature.kt
          state: CounterState
          action: CounterAction
          effectPayload: CounterEffectPayload
          scenario: src-kmp/subtrees/counter/logic/src/jvmTest/kotlin/com/x/CounterScenarioTest.kt
          fixtures:
            - counter

      chains:
        - counter.wave
      """)
    try write(
      "src-kmp/subtrees/counter/logic/src/commonMain/kotlin/com/x/CounterFeature.kt",
      "package com.x\n")
    try write(
      "src-kmp/subtrees/counter/logic/src/jvmTest/kotlin/com/x/CounterScenarioTest.kt",
      "package com.x\n")
    try write(
      "src-kmp/aggregator/src/jvmTest/kotlin/com/x/ChainReplayTest.kt",
      """
      package com.x

      class ChainReplayTest {
        fun waveLeaf() = replay("counter.wave")
      }
      """)
    return Repo(root: root)
  }

  func testAnUnscopedRunAddsTheModuleHostingAChainReplay() throws {
    let repo = try chainTree()
    let manifest = try Manifest.load(repo: repo)
    // The coverage gate expects a chain report from this lane, and the chain's
    // replay sits in `:aggregator`, which no feature declares — so the task
    // set is the feature modules PLUS the discovered host.
    XCTAssertEqual(
      Lanes.verifyGradleTasks(repo: repo, manifest: manifest, scope: nil),
      [":subtrees:counter:logic:jvmTest", ":aggregator:jvmTest"])
  }

  func testAScopedRunStaysOnItsOwnModule() throws {
    let repo = try chainTree()
    let manifest = try Manifest.load(repo: repo)
    let counter = try XCTUnwrap(manifest.feature(named: "counter"))
    // A `--feature` run replays that feature's fixtures; chains are unscoped
    // (`record --chain` is their own scope), so the host is not added.
    XCTAssertEqual(
      Lanes.verifyGradleTasks(repo: repo, manifest: manifest, scope: counter),
      [":subtrees:counter:logic:jvmTest"])
  }

  func testTwoFeaturesInOneModuleDeriveOneTask() {
    let first = feature(
      name: "capture", swift: "",
      kotlin: "src-kmp/subtrees/capture/logic/src/commonMain/kotlin/com/x/CaptureFeature.kt")
    let second = feature(
      name: "review", swift: "",
      kotlin: "src-kmp/subtrees/capture/logic/src/commonMain/kotlin/com/x/ReviewFeature.kt")
    let manifest = Manifest(
      features: [first, second], chains: [], lintOK: true, lintErrors: [],
      swiftPackageDirs: [], androidDir: URL(fileURLWithPath: "/repo/src-kmp"),
      replayRunnerRelative: nil, mocksBundle: nil, mockGenerators: [],
      repoRoot: URL(fileURLWithPath: "/repo"))
    XCTAssertEqual(manifest.unscopedGradleTasks, [":subtrees:capture:logic:jvmTest"])
  }

  // MARK: - Lane flags against the scope

  func testALaneFlagNamingTheScopesMissingLaneIsAMetaError() {
    let mismatch = Lanes.laneFlagMismatch(
      swiftOnly: false, kotlinOnly: true, swiftLane: true, kotlinLane: false, scope: "traillog")
    XCTAssertEqual(
      mismatch,
      "--kotlin-only --feature traillog: feature 'traillog' declares no `kotlin:` path — "
        + "there is no Kotlin lane to run")
    XCTAssertEqual(
      Lanes.laneFlagMismatch(
        swiftOnly: true, kotlinOnly: false, swiftLane: false, kotlinLane: true, scope: "capture"),
      "--swift-only --feature capture: feature 'capture' declares no `swift:` path — "
        + "there is no Swift lane to run")
  }

  func testAnUnscopedFlagMismatchNamesTheManifest() {
    XCTAssertEqual(
      Lanes.laneFlagMismatch(
        swiftOnly: false, kotlinOnly: true, swiftLane: true, kotlinLane: false, scope: nil),
      "--kotlin-only: the manifest declares no `kotlin:` path — there is no Kotlin lane to run")
  }

  func testAFlagNamingALaneTheScopeHasIsNotAMismatch() {
    XCTAssertNil(
      Lanes.laneFlagMismatch(
        swiftOnly: false, kotlinOnly: true, swiftLane: false, kotlinLane: true, scope: "capture"))
    XCTAssertNil(
      Lanes.laneFlagMismatch(
        swiftOnly: false, kotlinOnly: false, swiftLane: true, kotlinLane: true, scope: nil))
  }
}
