// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import Foundation

/// Repo discovery + the parity manifest model. The manifest has exactly ONE
/// parser — the CLI's own (ManifestParser.swift, grammar in
/// contracts/manifest.md) — and loading it runs the meta-checks
/// (ManifestLint.swift), so every verb gets the lint verdict for free. The
/// repo's tree shape is NOT hardcoded here: the platform roots are derived from
/// the manifest's own per-feature source paths, so the CLI is
/// repo-layout-neutral.
struct Repo {
  let root: URL

  var fixturesDir: URL { root.appendingPathComponent("parity/fixtures") }
  var runsDir: URL { root.appendingPathComponent("parity/.runs") }
  var manifestFile: URL { root.appendingPathComponent("parity/manifest.yaml") }

  /// Walks up from the working directory to the directory containing parity/fixtures —
  /// the same root convention both test runners use.
  static func discover(from start: String = FileManager.default.currentDirectoryPath) -> Repo? {
    var directory = URL(fileURLWithPath: start)
    while directory.path != "/" {
      let candidate = directory.appendingPathComponent("parity/fixtures")
      if FileManager.default.fileExists(atPath: candidate.path) {
        return Repo(root: directory)
      }
      directory.deleteLastPathComponent()
    }
    return nil
  }
}

struct Feature {
  let name: String
  let swiftSource: String
  let kotlinSource: String
  let stateType: String
  let actionType: String
  let payloadType: String
  let scenario: String?
  let fixtures: [String]

  /// `Sources/<Module>/…` → the SPM module that declares the feature.
  var swiftModule: String? {
    let parts = swiftSource.split(separator: "/").map(String.init)
    guard let index = parts.firstIndex(of: "Sources"), index + 1 < parts.count else {
      return nil
    }
    return parts[index + 1]
  }

  /// The prefix of `swift:` before /Sources/ — the feature's OWN package root,
  /// repo-relative. Since the first subtree re-cut (F5) features live in more
  /// than one package (`Subtrees/<Name>` beside the aggregator), so the root is
  /// per-feature, not per-manifest.
  var swiftPackageRelative: String? {
    let parts = swiftSource.split(separator: "/").map(String.init)
    guard let index = parts.firstIndex(of: "Sources"), index > 0 else { return nil }
    return parts[..<index].joined(separator: "/")
  }

  /// The feature's test target — the `swift test --filter` scope.
  var swiftTestTarget: String? { swiftModule.map { "\($0)Tests" } }

  /// `<androidRoot>/<module…>/src/<sourceSet>/…` → the module's directory path
  /// relative to the Android root (nested Gradle modules keep their nesting).
  /// Source sets cover both the JVM layout (main/test) and the KMP flavor's
  /// (commonMain/commonTest/jvmMain/jvmTest).
  var kotlinModulePath: String? {
    let parts = kotlinSource.split(separator: "/").map(String.init)
    let sourceSets = ["main", "test", "commonMain", "commonTest", "jvmMain", "jvmTest"]
    guard let srcIndex = parts.firstIndex(of: "src"), srcIndex >= 2,
      srcIndex + 1 < parts.count, sourceSets.contains(parts[srcIndex + 1])
    else { return nil }
    return parts[1..<srcIndex].joined(separator: "/")
  }

  /// Whether the feature lives in a KMP module (its source set is a
  /// multiplatform one). A KMP module has no aggregate `test` task — the JVM
  /// host lane is `jvmTest` — so the lane task derives from this.
  var isKmpSourceSet: Bool {
    let parts = kotlinSource.split(separator: "/").map(String.init)
    guard let srcIndex = parts.firstIndex(of: "src"), srcIndex + 1 < parts.count else {
      return false
    }
    return ["commonMain", "commonTest", "jvmMain", "jvmTest"].contains(parts[srcIndex + 1])
  }

  /// The Gradle test task for the feature (`:module:test`, nesting
  /// colon-joined; `jvmTest` for KMP modules).
  var gradleTestTask: String? {
    kotlinModulePath.map {
      ":\($0.replacingOccurrences(of: "/", with: ":")):\(isKmpSourceSet ? "jvmTest" : "test")"
    }
  }

  /// Whether any Kotlin lane can replay this feature: false for an empty
  /// `kotlin:` (a Swift-only manifest) and for `kotlin: pending` (declared
  /// single-sided, port not landed) — both derive no Gradle module.
  var hasKotlinLane: Bool { gradleTestTask != nil }

  /// The scenario is Kotlin-authored (the writer runs in the Gradle lane).
  var hasKotlinScenario: Bool { scenario?.hasSuffix(".kt") == true }

  /// The dual-writer window: a `swift:` twin still declared while the
  /// scenario is already Kotlin-authored — the span of a per-feature migration
  /// in which BOTH platforms hold a writer for the same fixture files. Unscoped
  /// `record` refuses while any feature is in this state: the Swift roots run
  /// every scenario under REGEN, so the retiring twin would re-record fixtures
  /// the Kotlin scenario owns.
  var isDualWriter: Bool {
    !swiftSource.isEmpty && swiftSource != "pending" && hasKotlinScenario
  }

  /// Package of the Kotlin sources (`…/kotlin/com/example/x/File.kt` → com.example.x).
  var kotlinPackage: String? {
    let parts = kotlinSource.split(separator: "/").map(String.init)
    guard let index = parts.firstIndex(of: "kotlin"), index + 1 < parts.count - 1 else {
      return nil
    }
    return parts[(index + 1)..<(parts.count - 1)].joined(separator: ".")
  }

  /// House convention: `SharePickerState` → `sharePickerReducer`.
  var reducerName: String {
    var base = stateType
    if base.hasSuffix("State") { base = String(base.dropLast("State".count)) }
    guard let first = base.first else { return "reducer" }
    return first.lowercased() + base.dropFirst() + "Reducer"
  }
}

struct Manifest {
  let features: [Feature]
  let chains: [String]
  /// Meta-check verdict from the same lockstep-lint run that produced the plan.
  let lintOK: Bool
  let lintErrors: [String]
  /// The Swift package roots (every distinct per-feature `swift:` prefix before
  /// /Sources/ — more than one since the first subtree re-cut, F5) and the
  /// Android build root (the first component of any feature's `kotlin:` path) —
  /// derived, absolute. Sorted by path for stable lane ordering. Single-source
  /// manifests carry ONE of the two: a KMP-flavor repo declares no `swift:`
  /// twins (swiftPackageDirs EMPTY — the Swift lane and the swift half of the
  /// coverage gate don't apply), and a Swift-only repo declares no `kotlin:`
  /// paths (androidDir NIL — the Kotlin lane and its gate half don't apply).
  let swiftPackageDirs: [URL]
  let androidDir: URL?
  /// Optional manifest override (`replayRunner:` top-level key): the Swift package
  /// root owning the `Sources/replay-runner` executable, for repos whose replay
  /// glue lives outside every feature package (a scaffolded all-subtrees layout
  /// has no aggregator root to probe).
  let replayRunnerRelative: String?
  /// Repo root the relative paths resolve against (for per-feature lookups).
  let repoRoot: URL

  /// The package root a feature's own Swift lane runs from.
  func swiftPackageDir(of feature: Feature) -> URL? {
    feature.swiftPackageRelative.map { repoRoot.appendingPathComponent($0) }
  }

  /// The unscoped Gradle lane tasks. An unqualified task name runs in every
  /// project that HAS it — Gradle matches per module — so the manifest's
  /// source-set knowledge selects the SET of names: `test` for JVM modules,
  /// `jvmTest` for KMP modules (which have no aggregate `test` task — running
  /// `test` there silently replays nothing), and BOTH on a mixed tree. The
  /// earlier all-or-nothing pick (`jvmTest` only when EVERY feature was
  /// KMP-shaped) silently skipped every migrated module for as long as one
  /// unmigrated twin remained — the whole span of a per-feature migration.
  var unscopedGradleTasks: [String] {
    let kmp = features.contains(where: \.isKmpSourceSet)
    let jvm = features.contains { !$0.isKmpSourceSet }
    if kmp && jvm { return ["test", "jvmTest"] }
    return kmp ? ["jvmTest"] : ["test"]
  }

  /// The package that owns the `replay-runner` executable product (the protocol
  /// lane's driver): the manifest's explicit `replayRunner:` key when declared,
  /// else probed — because after a re-cut the aggregator hosting it is just one
  /// root among several.
  var replayRunnerPackageDir: URL? {
    if let declared = replayRunnerRelative {
      return repoRoot.appendingPathComponent(declared)
    }
    return swiftPackageDirs.first {
      FileManager.default.fileExists(
        atPath: $0.appendingPathComponent("Sources/replay-runner").path)
    }
  }

  func feature(named name: String) -> Feature? {
    features.first { $0.name == name }
  }

  /// Owner of a fixture name (chains have no owner feature).
  func feature(forFixture fixture: String) -> Feature? {
    features.first { $0.fixtures.contains(fixture) }
  }

  /// Parses parity/manifest.yaml in-process and runs the meta-checks with it
  /// (ManifestLint) — one manifest parser, no interpreter subprocess, and every
  /// CLI invocation gets the lint verdict for free.
  static func load(repo: Repo) throws -> Manifest {
    enum ManifestError: Error, CustomStringConvertible {
      case layoutUnderivable(String)
      var description: String {
        switch self {
        case let .layoutUnderivable(detail):
          return "cannot derive the repo layout from the manifest: \(detail)"
        }
      }
    }
    let result = try ManifestLint.lint(repo: repo)
    let features = result.parsed.featureOrder
      .compactMap { name -> Feature? in
        guard let entry = result.parsed.features[name] else { return nil }
        return Feature(
          name: name,
          swiftSource: entry.keys["swift"] ?? "",
          kotlinSource: entry.keys["kotlin"] ?? "",
          stateType: entry.keys["state"] ?? "",
          actionType: entry.keys["action"] ?? "",
          payloadType: entry.keys["effectPayload"] ?? "",
          scenario: entry.keys["scenario"],
          fixtures: entry.fixtures)
      }
      .sorted { $0.name < $1.name }
    // Either side may be empty — a single-source manifest declares one lane's
    // paths only (no `swift:` twins on the KMP flavor; no `kotlin:` paths on the
    // Swift-only flavor) and the CLI runs the lanes the manifest derives. BOTH
    // empty derives no lane at all, which no lane flag can repair — named here.
    // A lint-red manifest returns instead of throwing: the verbs' meta gate
    // renders the errors, which name the actual defect.
    let swiftRelatives = Set(features.compactMap(\.swiftPackageRelative)).sorted()
    let androidRelative = features.lazy
      .compactMap({ feature -> String? in
        let parts = feature.kotlinSource.split(separator: "/")
        return parts.count > 1 ? String(parts[0]) : nil
      }).first
    guard !swiftRelatives.isEmpty || androidRelative != nil || !result.errors.isEmpty else {
      throw ManifestError.layoutUnderivable(
        "no feature declares a `swift:` or `kotlin:` source path — the manifest"
          + " derives no platform lane at all")
    }
    return Manifest(
      features: features,
      chains: result.parsed.chains,
      lintOK: result.errors.isEmpty,
      lintErrors: result.errors,
      swiftPackageDirs: swiftRelatives.map(repo.root.appendingPathComponent),
      androidDir: androidRelative.map(repo.root.appendingPathComponent),
      replayRunnerRelative: result.parsed.scalars["replayRunner"],
      repoRoot: repo.root)
  }
}
