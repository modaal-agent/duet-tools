// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import XCTest

@testable import DuetCLI

/// `record --feature X --platform P` against X's `scenario:` — the writer of
/// the feature's fixtures — and the fixture tree a refused run leaves behind.
/// The refusals return before any subprocess is launched, so `Lanes.record`
/// runs in-process here on a copy of the twins tree.
final class RecordPlatformTests: XCTestCase {

  private func record(_ repo: Repo, feature: String, platform: String? = nil) throws -> Int32 {
    var options = Options()
    options.command = "record"
    options.feature = feature
    options.platform = platform
    options.json = true
    return try Lanes.record(repo: repo, options: options)
  }

  private let swiftScenario =
    "src-ios/Subtrees/Greeter/GreeterFeature/Tests/GreeterFeatureTests/GreeterScenarioTests.swift"
  private let kotlinScenario =
    "src-android/subtrees/greeter/logic/src/test/kotlin/com/mini/greeter/GreeterScenarioTest.kt"

  // MARK: - The decision

  private func greeter(
    scenario: String?,
    kotlin: String =
      "src-android/subtrees/greeter/logic/src/main/kotlin/com/mini/greeter/GreeterFeature.kt"
  ) -> Feature {
    Feature(
      name: "greeter",
      swiftSource:
        "src-ios/Subtrees/Greeter/GreeterFeature/Sources/GreeterFeature/GreeterFeature.swift",
      kotlinSource: kotlin,
      stateType: "GreeterState", actionType: "GreeterAction",
      payloadType: "GreeterEffectPayload", scenario: scenario, fixtures: ["greeter"])
  }

  func testKotlinOnASwiftScenarioIsRefusedWithTheScenarioAndTheCommand() throws {
    let refusal = try XCTUnwrap(
      Lanes.platformScenarioMismatch(platform: "kotlin", feature: greeter(scenario: swiftScenario)))
    XCTAssertEqual(
      refusal,
      "--platform kotlin --feature greeter: the feature's scenario is Swift (\(swiftScenario)),"
        + " and the scenario is the writer of its fixtures. Record through it:"
        + " `duet record --feature greeter --platform swift`. The Kotlin twin replays the"
        + " recordings in `duet verify --feature greeter --kotlin-only`.")
  }

  func testSwiftOnAKotlinScenarioIsRefusedWithTheScenarioAndTheCommand() throws {
    let refusal = try XCTUnwrap(
      Lanes.platformScenarioMismatch(platform: "swift", feature: greeter(scenario: kotlinScenario)))
    XCTAssertEqual(
      refusal,
      "--platform swift --feature greeter: the feature's scenario is Kotlin (\(kotlinScenario)),"
        + " and the scenario is the writer of its fixtures. Record through it:"
        + " `duet record --feature greeter --platform kotlin`. The Swift twin replays the"
        + " recordings in `duet verify --feature greeter --swift-only`.")
  }

  func testTheReplayPointerIsNamedOnlyWhenTheOtherTwinExists() throws {
    // A Swift-only row has no Kotlin lane to replay in, so the refusal names
    // the recording command alone.
    let refusal = try XCTUnwrap(
      Lanes.platformScenarioMismatch(
        platform: "kotlin", feature: greeter(scenario: swiftScenario, kotlin: "pending")))
    XCTAssertTrue(refusal.hasSuffix("`duet record --feature greeter --platform swift`."), refusal)
  }

  func testAMatchingOrAbsentPlatformIsNotRefused() {
    XCTAssertNil(
      Lanes.platformScenarioMismatch(platform: "swift", feature: greeter(scenario: swiftScenario)))
    XCTAssertNil(
      Lanes.platformScenarioMismatch(platform: "kotlin", feature: greeter(scenario: kotlinScenario)))
    // No --platform: the default follows the scenario.
    XCTAssertNil(
      Lanes.platformScenarioMismatch(platform: nil, feature: greeter(scenario: swiftScenario)))
    // Unscoped: every writer records its own fixtures.
    XCTAssertNil(Lanes.platformScenarioMismatch(platform: "kotlin", feature: nil))
    // A scenario whose language the extension does not name is not judged.
    XCTAssertNil(
      Lanes.platformScenarioMismatch(platform: "kotlin", feature: greeter(scenario: nil)))
  }

  // MARK: - The verb on the twins tree

  func testKotlinOnTheSwiftWrittenTwinIsRefusedAndTheFixturesStay() throws {
    let repo = try makeMiniTree("mini-twins")
    let before = try fixtureBytes(repo)
    XCTAssertEqual(try record(repo, feature: "greeter", platform: "kotlin"), 1)
    XCTAssertEqual(try fixtureBytes(repo), before)
  }

  func testSwiftOnAKotlinWrittenTwinIsRefusedAndTheFixturesStay() throws {
    // The same row with the Kotlin scenario as the writer.
    let repo = try makeMiniTree("mini-twins")
    try rewriteMiniTree(
      repo, "parity/manifest.yaml", "scenario: \(swiftScenario)", "scenario: \(kotlinScenario)")
    let before = try fixtureBytes(repo)
    XCTAssertEqual(try record(repo, feature: "greeter", platform: "swift"), 1)
    XCTAssertEqual(try fixtureBytes(repo), before)
  }

  func testARefusalAfterTheKotlinPreDeleteRestoresTheFixtures() throws {
    // A Kotlin-written row whose Kotlin port has not landed (`kotlin:
    // pending`): the record defaults to the Kotlin path, pre-deletes the
    // row's fixtures, and then finds no Kotlin task to record through. The
    // refusal puts the deleted file back.
    let repo = try makeMiniTree("mini-twins")
    let scenario =
      "src-android/subtrees/profile/logic/src/test/kotlin/com/mini/profile/ProfileScenarioTest.kt"
    let url = repo.root.appendingPathComponent(scenario)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("package com.mini.profile\n".utf8).write(to: url)
    try rewriteMiniTree(
      repo, "parity/manifest.yaml",
      "    scenario: src-ios/Subtrees/Profile/ProfileFeature/Tests/ProfileFeatureTests/ProfileScenarioTests.swift\n",
      "    kotlin: pending\n    scenario: \(scenario)\n")
    let before = try fixtureBytes(repo)
    XCTAssertNotNil(before["profile.fixture.json"])
    XCTAssertEqual(try record(repo, feature: "profile"), 1)
    XCTAssertEqual(try fixtureBytes(repo), before)
    XCTAssertEqual(try record(repo, feature: "profile", platform: "kotlin"), 1)
    XCTAssertEqual(try fixtureBytes(repo), before)
  }
}
