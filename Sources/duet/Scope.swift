// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import Foundation

/// `duet scope <path> [--json]` — the module→gates map, both routing directions:
/// given any file or directory, report which parity gates govern it and what the
/// authoring loop for it looks like. Everything is derived from the repo's own
/// manifest (one parser, lockstep-lint's), so the verb is repo-layout-neutral —
/// it kills the inverse-routing tax ("I have a diff in this file; which gates do
/// I run?") without hardcoding any tree shape.
enum Scope {
  struct Verdict {
    var role: String
    var feature: String?
    var gates: [String]
    var notes: [String]
  }

  static func run(repo: Repo, options: Options) throws -> Int32 {
    guard let target = options.target else {
      FileHandle.standardError.write(Data("duet scope: no path given (usage: duet scope <path>)\n".utf8))
      return 2
    }
    let manifest = try Manifest.load(repo: repo)

    // Normalize: absolute or cwd-relative input → repo-root-relative. The path
    // does not need to exist (a deleted file still has a scope).
    let absolute = URL(
      fileURLWithPath: target,
      relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ).standardizedFileURL.path
    let rootPath = repo.root.standardizedFileURL.path
    guard absolute.hasPrefix(rootPath + "/") || absolute == rootPath else {
      FileHandle.standardError.write(
        Data("duet scope: \(target) is outside the repo at \(rootPath)\n".utf8))
      return 2
    }
    let relative = absolute == rootPath
      ? "" : String(absolute.dropFirst(rootPath.count + 1))

    let verdict = classify(relative, repo: repo, manifest: manifest)

    if options.json {
      var payload: [String: Any] = [
        "path": relative,
        "role": verdict.role,
        "gates": verdict.gates,
        "notes": verdict.notes,
      ]
      if let feature = verdict.feature { payload["feature"] = feature }
      Lanes.emitJSON(payload)
      return 0
    }
    print("scope: \(relative.isEmpty ? "." : relative)")
    print("  role: \(verdict.role)")
    if let feature = verdict.feature { print("  feature: \(feature)") }
    print("  gates:")
    for gate in verdict.gates { print("    \(gate)") }
    for note in verdict.notes { print("  note: \(note)") }
    return 0
  }

  static func classify(_ path: String, repo: Repo, manifest: Manifest) -> Verdict {
    let swiftRoots = manifest.swiftPackageDirs.map { relative($0, to: repo) }
    let androidRoot = manifest.androidDir.map { relative($0, to: repo) }

    // 1. A fixture file (or the fixtures directory): build products, owner-routed.
    if path.hasPrefix("parity/fixtures") {
      let stem = URL(fileURLWithPath: path).lastPathComponent
        .replacingOccurrences(of: ".fixture.json", with: "")
      if let feature = manifest.feature(forFixture: stem) {
        return Verdict(
          role: "leaf fixture `\(stem)` — a BUILD PRODUCT, never hand-edited",
          feature: feature.name,
          gates: ["duet verify --feature \(feature.name)", "duet record --check"],
          notes: [
            "to change it: author the scenario"
              + (feature.scenario.map { " (\($0))" } ?? "")
              + ", then `duet record --feature \(feature.name)` and review the diff",
          ])
      }
      if manifest.chains.contains(stem) {
        return Verdict(
          role: "chain fixture `\(stem)` — a BUILD PRODUCT, never hand-edited",
          feature: nil,
          gates: ["duet verify", "duet record --check"],
          notes: [
            "to change it: author the chain scenario, then an unscoped `duet record`"
              + " and review the diff",
          ])
      }
      return Verdict(
        role: "the fixture corpus (build products of `duet record`)",
        feature: nil,
        gates: ["duet verify", "duet record --check"],
        notes: ["fixtures are compiled from scenarios — never edit them by hand"])
    }

    // 2. The registry itself.
    if path == "parity/manifest.yaml" {
      return Verdict(
        role: "the parity manifest — the feature/fixture/scenario registry",
        feature: nil,
        gates: ["duet verify (the meta-check parses it on every run)"],
        notes: [
          "after declaring a fixture here, `duet record --feature <name>` writes it"
            + " (lockstep-lint is legitimately red in between)",
        ])
    }

    // 3. A feature's scenario file — the authoring surface.
    if let feature = manifest.features.first(where: { $0.scenario == path }) {
      return Verdict(
        role: "scenario source — fixtures for `\(feature.name)` compile from here",
        feature: feature.name,
        gates: [
          "duet record --feature \(feature.name)  (then review the fixture diff)",
          "duet verify --feature \(feature.name)",
        ],
        notes: ["Then/ThenEffects assertions run during record too"])
    }

    // 4. A feature's declared sources, or anything in its module directories.
    for feature in manifest.features {
      // Single-source manifests declare one side only — the undeclared side is
      // "" (or `pending`), and an empty string prefix-matches EVERY path, which
      // would classify the whole repo as this feature.
      var owned = [feature.swiftSource, feature.kotlinSource]
        .filter { !$0.isEmpty && $0 != "pending" }
      if let module = feature.swiftModule, let root = feature.swiftPackageRelative {
        owned.append("\(root)/Sources/\(module)/")
        owned.append("\(root)/Tests/\(module)Tests/")
      }
      if let modulePath = feature.kotlinModulePath, let androidRoot {
        owned.append("\(androidRoot)/\(modulePath)/")
      }
      if owned.contains(where: { path == $0 || path.hasPrefix($0) }) {
        let lockstepNote =
          feature.swiftSource.isEmpty || !feature.hasKotlinLane
          ? "single-source reducer: "
            + (feature.swiftSource.isEmpty ? feature.kotlinSource : feature.swiftSource)
          : "reducer twins move in lockstep: "
            + "\(feature.swiftSource) ↔ \(feature.kotlinSource)"
        return Verdict(
          role: "feature module source (`\(feature.name)`)",
          feature: feature.name,
          gates: [
            "duet verify --feature \(feature.name)  (lockstep-lint runs with it)",
            "duet record --feature \(feature.name)  (only if the behavior change is intended)",
            "duet verify  (full, before landing)",
          ],
          notes: [lockstepNote])
      }
    }

    // 5. Feature specs: prose beside the byte gate, cross-referenced by lint.
    if path.hasPrefix("parity/feature-specs/") {
      let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
      let feature = manifest.features.first { stem.contains($0.name) || $0.name.contains(stem) }
      return Verdict(
        role: "feature spec (the platform-agnostic porting source)",
        feature: feature?.name,
        gates: ["duet verify", "the spec↔fixture cross-reference lint (CI runs it)"],
        notes: ["every declared fixture must be mentioned here, backticked"])
    }

    // 6. Inside a Swift package root, outside any single feature.
    if let swiftRoot = swiftRoots.first(where: { path.hasPrefix($0 + "/") }) {
      return Verdict(
        role: "Swift package `\(swiftRoot)` (shared/shell code outside a single feature)",
        feature: nil,
        gates: ["duet verify  (the Swift lane runs every package root's tests)"],
        notes: ["chain scenarios record via an unscoped `duet record`"])
    }

    // 7. Inside the Android build, outside any feature module.
    if let androidRoot, path.hasPrefix(androidRoot + "/") {
      return Verdict(
        role: "Android build tree (outside any parity feature module)",
        feature: nil,
        gates: ["duet verify  (the Kotlin lane runs the gradle tests)"],
        notes: [])
    }

    // 8. The rest of parity/ — the harness itself.
    if path.hasPrefix("parity/") {
      return Verdict(
        role: "parity harness infrastructure",
        feature: nil,
        gates: ["duet verify", "duet record --check"],
        notes: [])
    }

    return Verdict(
      role: "NOT governed by the duet parity gates",
      feature: nil,
      gates: [],
      notes: [
        "app/platform trees have their own suites — see the repo's scope table"
          + " (authoring front door) for what governs this path",
      ])
  }

  private static func relative(_ url: URL, to repo: Repo) -> String {
    let rootPath = repo.root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    return path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : path
  }
}
