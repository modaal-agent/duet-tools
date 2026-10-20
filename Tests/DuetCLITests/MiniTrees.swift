// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import XCTest

@testable import DuetCLI

/// The miniature adopter trees under Tests/DuetCLITests/Resources/, copied to
/// a temp directory per test so a test can break its copy and never the
/// original.
extension XCTestCase {

  func makeMiniTree(_ name: String) throws -> Repo {
    // A top-level directory literally named "Resources" makes Bundle adopt the
    // Resources-style layout, so resourceURL may already point INSIDE the
    // copied directory — probe both spellings.
    let base = try XCTUnwrap(Bundle.module.resourceURL)
    let candidates = [
      base.appendingPathComponent("Resources/\(name)"),
      base.appendingPathComponent(name),
    ]
    let source = try XCTUnwrap(
      candidates.first { FileManager.default.fileExists(atPath: $0.path) },
      "missing mini tree \(name) under \(base.path)")
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("duet-mini-tree-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: source, to: root)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return Repo(root: root)
  }

  /// Exact-string edit of a file in the temp copy — asserts the anchor exists
  /// so a drifted mini tree fails loudly instead of testing nothing.
  func rewriteMiniTree(
    _ repo: Repo, _ path: String, _ old: String, _ new: String,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let url = repo.root.appendingPathComponent(path)
    let text = try String(contentsOf: url, encoding: .utf8)
    XCTAssertTrue(text.contains(old), "anchor '\(old)' not found in \(path)", file: file, line: line)
    try Data(text.replacingOccurrences(of: old, with: new).utf8).write(to: url)
  }

  /// Every file under parity/fixtures, by name, as bytes — the before/after
  /// snapshot a refusal must leave unchanged.
  func fixtureBytes(_ repo: Repo) throws -> [String: Data] {
    var bytes: [String: Data] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: repo.fixturesDir.path) {
      bytes[name] = try Data(contentsOf: repo.fixturesDir.appendingPathComponent(name))
    }
    return bytes
  }
}
