// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import Foundation

/// The lane-task shape lint (A29 R4), run in `verify`'s meta phase. A KMP
/// migration swaps a module's lane task from `test` to `jvmTest`; the CLI models
/// that in `unscopedGradleTasks` while every hand-written `gradlew` invocation
/// keeps its old task list and silently stops reaching the migrated modules. The
/// lint scans the repo's own automation (`.github/workflows/*.yml`,
/// `parity/scripts/*.sh`) for unqualified lane-family tasks and WARNS — never
/// fails — when a line runs fewer lane tasks than the manifest derives.
///
/// Only unqualified `test`/`jvmTest` tokens are matched: a `:module:test` task is
/// a deliberate module-scoped run, not a lane claim. Extra tasks beyond the
/// manifest's set are fine (they run more, not less) — the warning fires only on
/// MISSING tasks, the direction that loses modules.
enum LaneTaskLint {
  static let laneFamily: Set<String> = ["test", "jvmTest"]

  /// Unqualified lane-family task tokens in one line (empty when the line does
  /// not invoke gradlew).
  static func laneTokens(in line: String) -> [String] {
    guard line.contains("gradlew") else { return [] }
    return line.split(whereSeparator: { $0 == " " || $0 == "\t" })
      .map(String.init)
      .filter { laneFamily.contains($0) }
  }

  /// Warnings for one file's lines against the manifest-derived task set.
  /// Comment lines are skipped — a workflow's prose about `./gradlew test` is
  /// not an invocation.
  static func warnings(named file: String, lines: [String], expected: [String]) -> [String] {
    var found: [String] = []
    for (index, rawLine) in lines.enumerated() {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("#") || line.hasPrefix("//") { continue }
      let tokens = laneTokens(in: line)
      guard !tokens.isEmpty else { continue }
      let missing = expected.filter { !tokens.contains($0) }
      guard !missing.isEmpty else { continue }
      found.append(
        "\(file):\(index + 1): runs `\(tokens.joined(separator: " "))` but the manifest derives"
          + " `\(expected.joined(separator: " "))` — modules whose lane task is"
          + " `\(missing.joined(separator: " "))` run nothing there")
    }
    return found
  }

  /// Scans the repo's automation for stale lane-task invocations. No Kotlin
  /// lane → nothing to lint.
  static func warnings(repo: Repo, manifest: Manifest) -> [String] {
    guard manifest.androidDir != nil else { return [] }
    let expected = manifest.unscopedGradleTasks
    var results: [String] = []
    let dirs = [
      repo.root.appendingPathComponent(".github/workflows"),
      repo.root.appendingPathComponent("parity/scripts"),
    ]
    for dir in dirs {
      let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") || $0.hasSuffix(".sh") }
        .sorted()
      for name in names {
        let url = dir.appendingPathComponent(name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        results += warnings(
          named: Lanes.relativePath(url, in: repo), lines: lines, expected: expected)
      }
    }
    return results
  }
}
