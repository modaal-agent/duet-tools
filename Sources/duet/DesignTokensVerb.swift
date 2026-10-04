// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import Foundation

/// `duet design-tokens [--check]` — the design-token codegen verb. Reads
/// `parity/design-tokens.yaml` (contracts/design-tokens.md): at version 2 the
/// DTCG token files it names, at version 1 the tokens it carries. Writes the
/// vocabulary enums and value tables into each declared language's output
/// directory, and the web target's stylesheet, manifest and font files.
/// `duet design-tokens migrate` rewrites a version-1 config as version 2.
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
      let existing = FileManager.default.contents(atPath: url.path)
      if existing == file.bytes {
        regen.upToDate += 1
      } else if check {
        regen.stale.append(file.path)
      } else {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try file.bytes.write(to: url)
        regen.written.append(file.path)
      }
    }
    let emitted = Set(files.map(\.path))
    var owned = DesignTokensEmitter.ownedPaths(config: config)
    // The web target owns its fonts directory: a file the config no longer
    // names is reported, as a dropped vocabulary's file is.
    if let target = config.css {
      let fonts = repo.root.appendingPathComponent("\(target.output)/fonts")
      for name in (try? FileManager.default.contentsOfDirectory(atPath: fonts.path)) ?? [] where !name.hasPrefix(".") {
        owned.insert("\(target.output)/fonts/\(name)")
      }
    }
    for path in owned.subtracting(emitted).sorted() {
      if FileManager.default.fileExists(atPath: repo.root.appendingPathComponent(path).path) {
        regen.orphans.append(path)
      }
    }
    return regen
  }

  static func run(repo: Repo, options: Options) throws -> Int32 {
    if let subcommand = options.target {
      guard subcommand == "migrate" else {
        FileHandle.standardError.write(Data("duet design-tokens: unknown subcommand '\(subcommand)' (known: migrate)\n".utf8))
        return 2
      }
      return try DesignTokensMigrate.run(repo: repo, options: options)
    }
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
        print("  stale: \(path) — regenerate, or restore the hand-edit into \(config.source)")
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
