// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import Foundation

/// `duet design-tokens [--check]` — the design-token codegen verb. Reads
/// `parity/design-tokens.yaml` (grammar in contracts/design-tokens.md) and writes the
/// vocabulary enums and value tables into each declared language's output
/// directory.
///
/// `--check` follows `duet canonical-sum`: regenerate in memory and compare.
/// The generator is compiled into this binary and a run costs milliseconds, so
/// there is nothing to amortize with a fingerprint block — and comparing whole
/// files means a hand-edit anywhere in a generated file is red, not just a
/// touched input.
enum DesignTokensVerb {
  struct Regen {
    var written: [String] = []
    var stale: [String] = []
    /// Files a declared target owns that the config no longer produces — a
    /// vocabulary dropped from the config leaves one behind, and it compiles.
    var orphans: [String] = []
    var upToDate = 0

    var failed: Bool { !stale.isEmpty || !orphans.isEmpty }
  }

  static func regenerate(repo: Repo, config: DesignTokenConfig, check: Bool) throws -> Regen {
    var regen = Regen()
    let files = DesignTokensEmitter.emit(config: config)
    for file in files {
      let url = repo.root.appendingPathComponent(file.path)
      let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
      if existing == file.content {
        regen.upToDate += 1
      } else if check {
        regen.stale.append(file.path)
      } else {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(file.content.utf8).write(to: url)
        regen.written.append(file.path)
      }
    }
    let emitted = Set(files.map(\.path))
    for path in DesignTokensEmitter.ownedPaths(config: config).subtracting(emitted).sorted() {
      if FileManager.default.fileExists(atPath: repo.root.appendingPathComponent(path).path) {
        regen.orphans.append(path)
      }
    }
    return regen
  }

  static func run(repo: Repo, options: Options) throws -> Int32 {
    guard let config = try DesignTokenConfig.load(repo: repo) else {
      if options.json {
        Lanes.emitJSON([
          "status": "passed", "config": DesignTokenConfig.relativePath, "declared": false,
          "written": [String](), "stale": [String](), "orphans": [String](), "upToDate": 0,
        ])
      } else {
        print("duet design-tokens: no \(DesignTokenConfig.relativePath) — this repo declares no design tokens")
      }
      return 0
    }
    let regen = try regenerate(repo: repo, config: config, check: options.check)
    if options.json {
      Lanes.emitJSON([
        "status": regen.failed ? "failed" : "passed",
        "config": DesignTokenConfig.relativePath, "declared": true,
        "written": regen.written, "stale": regen.stale, "orphans": regen.orphans,
        "upToDate": regen.upToDate,
      ])
      return regen.failed ? 1 : 0
    }
    if options.check {
      if !regen.failed {
        print("duet design-tokens --check: \(regen.upToDate) generated token file(s) up to date")
        return 0
      }
      print("duet design-tokens --check: FAIL")
      for path in regen.stale {
        print("  stale: \(path) — regenerate, or restore the hand-edit into \(DesignTokenConfig.relativePath)")
      }
      for path in regen.orphans {
        print("  orphaned: \(path) — the config no longer declares it; delete the file")
      }
      print("regenerate and commit: duet design-tokens")
      return 1
    }
    if regen.written.isEmpty {
      print("duet design-tokens: \(regen.upToDate) generated token file(s) up to date")
    } else {
      print("duet design-tokens: wrote \(regen.written.count) token file(s):")
      for path in regen.written { print("  \(path)") }
      print("review and commit the diff (generated token sources are committed build products)")
    }
    for path in regen.orphans {
      print("  orphaned: \(path) — the config no longer declares it; delete the file")
    }
    return regen.orphans.isEmpty ? 0 : 1
  }
}
