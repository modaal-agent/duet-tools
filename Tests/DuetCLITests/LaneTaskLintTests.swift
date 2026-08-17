// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import XCTest

@testable import DuetCLI

/// The lane-task shape lint: a `gradlew` line naming fewer unqualified
/// lane tasks than the manifest derives loses modules; extra tasks and
/// module-qualified tasks are deliberate and stay silent.
final class LaneTaskLintTests: XCTestCase {
  func testStaleSingleTaskOnMixedTreeWarns() {
    // The measured case: a fallback runner's `./gradlew test` reached no
    // KMP feature module while the manifest derived `test jvmTest`.
    let warnings = LaneTaskLint.warnings(
      named: "parity/scripts/parity-test.sh",
      lines: ["./gradlew test --console=plain"],
      expected: ["test", "jvmTest"])
    XCTAssertEqual(warnings.count, 1)
    XCTAssertTrue(warnings[0].contains("jvmTest"))
    XCTAssertTrue(warnings[0].contains("parity-test.sh:1"))
  }

  func testStaleJvmTaskOnAllKmpTreeWarns() {
    // The measured case: `test` on an all-KMP manifest runs no feature
    // module's lane at all.
    let warnings = LaneTaskLint.warnings(
      named: ".github/workflows/ci.yml",
      lines: ["          ./gradlew test --console=plain"],
      expected: ["jvmTest"])
    XCTAssertEqual(warnings.count, 1)
  }

  func testSupersetStaysSilent() {
    // Extra tasks run more, not less — the repaired parity-test.sh shape.
    let warnings = LaneTaskLint.warnings(
      named: "parity/scripts/parity-test.sh",
      lines: ["./gradlew test jvmTest --console=plain"],
      expected: ["jvmTest"])
    XCTAssertTrue(warnings.isEmpty)
  }

  func testQualifiedTasksStaySilent() {
    // `:app:testDebugUnitTest` / `:services:test` are deliberate module-scoped
    // runs, not lane claims.
    let warnings = LaneTaskLint.warnings(
      named: ".github/workflows/ci.yml",
      lines: [
        "          ./gradlew :app:testDebugUnitTest --console=plain",
        "          ./gradlew :services:test --console=plain",
      ],
      expected: ["jvmTest"])
    XCTAssertTrue(warnings.isEmpty)
  }

  func testCommentLinesAreSkipped() {
    let warnings = LaneTaskLint.warnings(
      named: ".github/workflows/ci.yml",
      lines: ["  # the parity host lane's `./gradlew test` covers every module"],
      expected: ["jvmTest"])
    XCTAssertTrue(warnings.isEmpty)
  }

  func testNonGradlewLinesYieldNoTokens() {
    XCTAssertTrue(LaneTaskLint.laneTokens(in: "swift test --filter Foo").isEmpty)
    XCTAssertEqual(
      LaneTaskLint.laneTokens(in: "./gradlew test jvmTest --console=plain"),
      ["test", "jvmTest"])
  }
}
