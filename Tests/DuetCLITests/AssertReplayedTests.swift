// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import XCTest

@testable import DuetCLI

/// The empty-pass gate's parsing rule (A29 R3): the executed count is the
/// MAXIMUM across runner summaries, never the presence of a zero — `swift test`
/// drives XCTest and swift-testing together and always prints both summaries.
final class AssertReplayedTests: XCTestCase {
  func testXCTestSummaryCounts() {
    let log = """
      Test Suite 'All tests' passed at 2026-08-09 10:00:00.000.
      \t Executed 12 tests, with 0 failures (0 unexpected) in 0.019 (0.021) seconds
      """
    XCTAssertEqual(AssertReplayed.maxExecuted(inLog: log), 12)
  }

  func testSwiftTestingSummaryCounts() {
    let log = "✔ Test run with 5 tests passed after 0.011 seconds."
    XCTAssertEqual(AssertReplayed.maxExecuted(inLog: log), 5)
  }

  /// The dual-runner shape: a package using swift-testing shows XCTest's zero
  /// line on a perfectly green run — the maximum rule keeps it green.
  func testMaximumAcrossRunnersNotPresenceOfAZero() {
    let log = """
      Test Suite 'All tests' passed at 2026-08-09 10:00:00.000.
      \t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
      ✔ Test run with 7 tests passed after 0.031 seconds.
      """
    XCTAssertEqual(AssertReplayed.maxExecuted(inLog: log), 7)
  }

  /// The C4 control as a toolchain test (26 §24.3): an emptied test target
  /// prints both zero summaries and exits 0 — the gate must read 0, not pass.
  func testEmptiedTargetReadsZero() {
    let log = """
      Building for debugging...
      Build complete! (1.2s)
      Test Suite 'All tests' passed at 2026-08-09 10:00:00.000.
      \t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
      ◇ Test run started.
      ✔ Test run with 0 tests passed after 0.001 seconds.
      """
    XCTAssertEqual(AssertReplayed.maxExecuted(inLog: log), 0)
  }

  func testGradleCompletedSummaryCounts() {
    let log = "97 tests completed, 1 failed"
    XCTAssertEqual(AssertReplayed.maxExecuted(inLog: log), 97)
  }

  func testEmptyLogReadsZero() {
    XCTAssertEqual(AssertReplayed.maxExecuted(inLog: ""), 0)
  }
}
