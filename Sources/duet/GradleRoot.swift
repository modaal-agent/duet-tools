// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import Foundation

/// Where a manifest's Kotlin modules are built from: the nearest ancestor of a
/// feature's `kotlin:` path that holds `settings.gradle(.kts)`. A module path
/// is taken relative to it. A repo whose Gradle build sits in a subdirectory
/// (`<root>/subtrees/<name>/logic/…`) and a repo whose build is at the
/// repository root (`subtrees/<name>/core/…`) both resolve.
enum GradleRoot {
  /// The number of leading path components of *kotlinPath* that name the
  /// Gradle root: 0 for the repository root. Nil when no ancestor below the
  /// module holds a settings file, in which case callers keep the
  /// one-component rule.
  static func depth(ofKotlinPath kotlinPath: String, repoRoot: URL) -> Int? {
    let parts = kotlinPath.split(separator: "/").map(String.init)
    guard let srcIndex = parts.firstIndex(of: "src"), srcIndex >= 1 else { return nil }
    var depth = srcIndex - 1
    while depth >= 0 {
      let dir = parts[..<depth].joined(separator: "/")
      let base = dir.isEmpty ? repoRoot : repoRoot.appendingPathComponent(dir)
      for name in ["settings.gradle.kts", "settings.gradle"]
      where FileManager.default.fileExists(atPath: base.appendingPathComponent(name).path) {
        return depth
      }
      depth -= 1
    }
    return nil
  }

  /// The depth every feature of a manifest shares: the first real `kotlin:`
  /// path decides, as the first one decided the root before.
  static func depth(ofKotlinPaths paths: [String], repoRoot: URL) -> Int {
    for path in paths where !path.isEmpty && path != "pending" {
      return depth(ofKotlinPath: path, repoRoot: repoRoot) ?? 1
    }
    return 1
  }

  /// `root/rest`, or `rest` when the root is the repository itself.
  static func join(_ root: String, _ rest: String) -> String {
    root.isEmpty ? rest : "\(root)/\(rest)"
  }
}
