// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import XCTest

@testable import DuetCLI

/// The dual-writer predicate, and the settings-file module parse the coverage
/// report rides on.
final class ManifestModelTests: XCTestCase {
  private func feature(swift: String, scenario: String?) -> Feature {
    Feature(
      name: "capture",
      swiftSource: swift,
      kotlinSource: "src-kmp/subtrees/capture/logic/src/commonMain/kotlin/com/x/CaptureFeature.kt",
      stateType: "CaptureState", actionType: "CaptureAction",
      payloadType: "CaptureEffectPayload",
      scenario: scenario,
      fixtures: ["capture.save"])
  }

  func testDualWriterNeedsBothATwinAndAKotlinScenario() {
    let kotlinScenario =
      "src-kmp/subtrees/capture/logic/src/jvmTest/kotlin/com/x/CaptureScenarioTest.kt"
    XCTAssertTrue(
      feature(swift: "src-ios/Subtrees/Capture/Sources/Capture/CaptureFeature.swift",
        scenario: kotlinScenario).isDualWriter)
    // Migrated (no twin) — the normal single-source state, not dual-writer.
    XCTAssertFalse(feature(swift: "", scenario: kotlinScenario).isDualWriter)
    // Unmigrated (Swift scenario) — one writer, the Swift one.
    XCTAssertFalse(
      feature(swift: "src-ios/Subtrees/Capture/Sources/Capture/CaptureFeature.swift",
        scenario: "src-ios/Subtrees/Capture/Tests/CaptureTests/CaptureScenario.swift")
        .isDualWriter)
  }

  func testKmpModuleDerivesJvmTestLaneTask() {
    let kmp = feature(swift: "", scenario: nil)
    XCTAssertEqual(kmp.gradleTestTask, ":subtrees:capture:logic:jvmTest")
    XCTAssertTrue(kmp.isKmpSourceSet)
  }

  func testGradleModulesParseBothSettingsDialects() {
    let kts = """
      rootProject.name = "wikimemory-kmp"
      include(":subtrees:counter:logic")
      include(":app")
      // include(":retired")
      """
    XCTAssertEqual(
      Inventory.gradleModules(inSettingsText: kts),
      [":subtrees:counter:logic", ":app"])
    let groovy = """
      include ':app', ':services'
      include ':replay-runner'
      """
    XCTAssertEqual(
      Inventory.gradleModules(inSettingsText: groovy),
      [":app", ":services", ":replay-runner"])
  }
}
