// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import XCTest

@testable import DuetCLI

/// Lane logs and scratch files go under `$TMPDIR` when it is set, so a sandbox
/// that allows writes only there still receives them.
final class ScratchDirectoryTests: XCTestCase {

  func testATmpdirIsTheScratchDirectory() {
    let directory = Lanes.scratchDirectory(environment: ["TMPDIR": "/tmp/duet-sandbox"])
    XCTAssertEqual(directory.path, "/tmp/duet-sandbox")
  }

  func testWithoutATmpdirTheUsersTemporaryDirectoryIsUsed() {
    let fallback = FileManager.default.temporaryDirectory.standardizedFileURL.path
    XCTAssertEqual(Lanes.scratchDirectory(environment: [:]).standardizedFileURL.path, fallback)
    XCTAssertEqual(
      Lanes.scratchDirectory(environment: ["TMPDIR": ""]).standardizedFileURL.path, fallback)
  }

  /// The log a lane writes lands under the process's `$TMPDIR`.
  func testALaneLogIsWrittenUnderTmpdir() throws {
    let tmpdir = FileManager.default.temporaryDirectory
      .appendingPathComponent("duet-scratch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpdir, withIntermediateDirectories: true)
    let previous = ProcessInfo.processInfo.environment["TMPDIR"]
    setenv("TMPDIR", tmpdir.path, 1)
    addTeardownBlock {
      if let previous { setenv("TMPDIR", previous, 1) } else { unsetenv("TMPDIR") }
      try? FileManager.default.removeItem(at: tmpdir)
    }

    let result = Lanes.finish(
      try Lanes.launch(["sh", "-c", "echo lane-output"], cwd: tmpdir, logName: "scratch-test"))

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(
      result.logURL.deletingLastPathComponent().standardizedFileURL.path,
      tmpdir.standardizedFileURL.path)
    XCTAssertEqual(
      try String(contentsOf: result.logURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      "lane-output")
  }
}
