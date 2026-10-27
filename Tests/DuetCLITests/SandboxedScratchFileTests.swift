// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import XCTest

@testable import DuetCLI

/// The built `duet` binary run under a sandbox profile that refuses writes to
/// the user's temporary directory, with `$TMPDIR` elsewhere: the lane log a
/// run creates is created under `$TMPDIR` and receives the lane's output.
final class SandboxedScratchFileTests: XCTestCase {

  private static let sandboxExec = "/usr/bin/sandbox-exec"

  func testALaneLogIsCreatedInASandboxThatRefusesTheUsersTemporaryDirectory() throws {
    guard FileManager.default.isExecutableFile(atPath: Self.sandboxExec) else {
      throw XCTSkip("no \(Self.sandboxExec) on this machine")
    }
    let duet = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("duet")
    XCTAssertTrue(
      FileManager.default.isExecutableFile(atPath: duet.path),
      "no built duet binary at \(duet.path)")

    let userTemp = try Self.userTemporaryDirectory()
    let profile = """
      (version 1)
      (allow default)
      (deny file-write* (subpath "\(userTemp)"))
      """

    // The profile refuses a file in the user's temporary directory; without
    // that, the run below would prove nothing.
    let probe = "\(userTemp)/duet-sandbox-probe-\(UUID().uuidString)"
    addTeardownBlock { try? FileManager.default.removeItem(atPath: probe) }
    let touch = try Self.run(
      Self.sandboxExec, ["-p", profile, "/usr/bin/touch", probe], cwd: URL(fileURLWithPath: "/"))
    XCTAssertNotEqual(touch.status, 0, "the profile let /usr/bin/touch write \(probe)")

    let tmpdir = URL(fileURLWithPath: "/private/tmp/duet-sandbox-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpdir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: tmpdir) }

    // A Kotlin tree whose `gradlew` prints its arguments and fails: the
    // protocol lane launches it to build the replay runner, with a lane log.
    let repo = try makeMiniTree("mini-kmp")
    let androidDir = repo.root.appendingPathComponent("src-kmp")
    try FileManager.default.createDirectory(
      at: androidDir.appendingPathComponent("replay-runner"), withIntermediateDirectories: true)
    let gradlew = androidDir.appendingPathComponent("gradlew")
    try Data("#!/bin/sh\necho \"stand-in gradle: $*\"\nexit 1\n".utf8).write(to: gradlew)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gradlew.path)

    let result = try Self.run(
      Self.sandboxExec, ["-p", profile, duet.path, "protocol-run", "--json"],
      cwd: repo.root, environment: ["TMPDIR": tmpdir.path])

    XCTAssertEqual(result.status, 1, result.output)
    let json = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard json.hasPrefix("{") else {
      return XCTFail("duet printed no JSON report:\n\(json)")
    }
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
    let report = try XCTUnwrap(object as? [String: Any], json)
    let log = URL(fileURLWithPath: try XCTUnwrap(report["log"] as? String, json))
    XCTAssertEqual(log.deletingLastPathComponent().path, tmpdir.path)
    XCTAssertTrue(
      try String(contentsOf: log, encoding: .utf8)
        .contains("stand-in gradle: :replay-runner:installDist"))
  }

  /// The real path of the user's temporary directory, which a sandbox profile
  /// matches against.
  private static func userTemporaryDirectory() throws -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0,
      let resolved = realpath(buffer, nil)
    else {
      throw XCTSkip("no user temporary directory")
    }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  private static func run(
    _ executable: String, _ arguments: [String], cwd: URL, environment: [String: String] = [:]
  ) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = cwd
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
    process.standardInput = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }
}
