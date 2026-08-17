// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import CanonicalSumGen
import Foundation

/// `duet canonical-sum [--check]` — the Swift ceremony killer's codegen verb,
/// and the scaffold's default vehicle for it. Zero-config: scans the
/// manifest-derived package's `Sources/**` for `CanonicalSumCodable` conformers
/// and (re)generates their committed coder files. Normally nobody runs this
/// directly — regen is folded into `duet record` and drift into
/// `duet record --check`, so adopting the codegen adds no pipeline step — but
/// the standalone verb exists for a first generation on a new type, before
/// anything records.
enum CanonicalSumVerb {
  struct Regen {
    var written: [String] = []
    var stale: [String] = []
    var upToDate = 0
  }

  /// Regenerates (or, with `check`, compares in memory) every marker-annotated
  /// source's coder file. Paths in the result are repo-relative.
  static func regenerate(repo: Repo, manifest: Manifest, check: Bool) throws -> Regen {
    var regen = Regen()
    // Every package root is scanned — coder-bearing features live in more than
    // one package since the subtree re-cuts.
    for packageDir in manifest.swiftPackageDirs {
      let sourcesRoot = packageDir.appendingPathComponent("Sources")
      for source in CanonicalSumGen.scan(sourcesRoot: sourcesRoot) {
        guard let output = try CanonicalSumGen.generate(fromSource: source) else { continue }
        let existing = (try? String(contentsOf: output.outputURL, encoding: .utf8)) ?? ""
        let relative = output.outputURL.path.replacingOccurrences(
          of: repo.root.path + "/", with: "")
        if existing == output.content {
          regen.upToDate += 1
        } else if check {
          regen.stale.append(relative)
        } else {
          try Data(output.content.utf8).write(to: output.outputURL)
          regen.written.append(relative)
        }
      }
    }
    return regen
  }

  static func run(repo: Repo, options: Options) throws -> Int32 {
    let manifest = try Manifest.load(repo: repo)
    let regen = try regenerate(repo: repo, manifest: manifest, check: options.check)
    if options.json {
      Lanes.emitJSON([
        "status": regen.stale.isEmpty ? "passed" : "failed",
        "written": regen.written, "stale": regen.stale, "upToDate": regen.upToDate,
      ])
      return regen.stale.isEmpty ? 0 : 1
    }
    if options.check {
      if regen.stale.isEmpty {
        print("duet canonical-sum --check: \(regen.upToDate) generated coder file(s) up to date")
        return 0
      }
      print("duet canonical-sum --check: FAIL — stale generated coder file(s):")
      for path in regen.stale { print("  \(path)") }
      print("regenerate and commit: duet record (regen is folded in)")
      return 1
    }
    if regen.written.isEmpty {
      print("duet canonical-sum: \(regen.upToDate) generated coder file(s) up to date")
    } else {
      print("duet canonical-sum: wrote \(regen.written.count) coder file(s):")
      for path in regen.written { print("  \(path)") }
      print("review and commit the diff (generated coders are committed sources)")
    }
    return 0
  }
}
