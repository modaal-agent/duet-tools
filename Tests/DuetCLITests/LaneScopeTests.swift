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
    XCTAssertEqual(manifest.unscopedGradleTasks, ["test", "jvmTest"])
  }

  func testAScopeWithAKotlinTwinDerivesItsOwnTask() throws {
    let manifest = mixedManifest()
    let crossed = try XCTUnwrap(manifest.feature(named: "capture"))
    XCTAssertEqual(manifest.gradleTasks(scope: crossed), [":subtrees:capture:logic:jvmTest"])
  }

  func testAnUnscopedRunKeepsTheManifestsTaskSet() {
    XCTAssertEqual(mixedManifest().gradleTasks(scope: nil), ["test", "jvmTest"])
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
