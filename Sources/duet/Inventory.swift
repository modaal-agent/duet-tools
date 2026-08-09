// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import Foundation

/// `duet lanes [--json]` — the lane inventory as a queryable contract (A29 R1):
/// every lane task, package root, and filter the manifest derives, plus what the
/// verify gate deliberately does NOT cover. The CLI already computes all of it to
/// run `verify`; this verb exposes the same derivation so a workflow or fallback
/// runner is GENERATED from the manifest instead of re-derived by hand — the two
/// measured re-derivations both went stale silently (a fallback runner whose
/// `./gradlew test` reached no feature module; a CI comment asserting coverage
/// that `jvmTest` did not provide).
enum Inventory {
  /// What an unscoped `duet verify` run makes no claim about: build units that
  /// exist in the repo but are outside the manifest's derivation. Silence reads
  /// as coverage, so verify prints this and `lanes` exposes it machine-readably.
  struct Coverage {
    /// Gradle modules in settings.gradle(.kts) not declared by any feature.
    let gradleModulesOutsideManifest: [String]
    /// Swift package roots in the repo not among the manifest's lane roots.
    let swiftPackagesOutsideManifest: [String]
  }

  static func coverage(repo: Repo, manifest: Manifest) -> Coverage {
    var gradleOutside: [String] = []
    if let androidDir = manifest.androidDir {
      let declared = Set(
        manifest.features.compactMap { feature in
          feature.kotlinModulePath.map { ":" + $0.replacingOccurrences(of: "/", with: ":") }
        })
      let all = gradleModules(inSettingsAt: androidDir)
      gradleOutside = all.filter { !declared.contains($0) }.sorted()
    }
    let declaredSwift = Set(manifest.swiftPackageDirs.map(\.standardizedFileURL.path))
    let swiftOutside = swiftPackageRoots(under: repo.root)
      .filter { !declaredSwift.contains($0.standardizedFileURL.path) }
      .map { Lanes.relativePath($0, in: repo) }
      .sorted()
    return Coverage(
      gradleModulesOutsideManifest: gradleOutside,
      swiftPackagesOutsideManifest: swiftOutside)
  }

  /// Module paths from the Gradle settings file (`:a:b` form). Both dialects'
  /// include statements are matched; a settings file the parse cannot read
  /// yields the empty list (coverage then reports nothing, never wrongly).
  static func gradleModules(inSettingsAt androidDir: URL) -> [String] {
    for name in ["settings.gradle.kts", "settings.gradle"] {
      let url = androidDir.appendingPathComponent(name)
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
      return gradleModules(inSettingsText: text)
    }
    return []
  }

  static func gradleModules(inSettingsText text: String) -> [String] {
    var modules: [String] = []
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard line.hasPrefix("include"), !line.hasPrefix("#"), !line.hasPrefix("//") else {
        continue
      }
      // include(":a:b") · include ':a', ':b' — pull every quoted :path token.
      var rest = Substring(line)
      while let quote = rest.firstIndex(where: { $0 == "\"" || $0 == "'" }) {
        let quoteChar = rest[quote]
        rest = rest[rest.index(after: quote)...]
        guard let end = rest.firstIndex(of: quoteChar) else { break }
        let token = String(rest[..<end])
        if token.hasPrefix(":") { modules.append(token) }
        rest = rest[rest.index(after: end)...]
      }
    }
    return modules
  }

  /// Every directory holding a Package.swift, bounded: build products, VCS
  /// internals, and dependency checkouts are skipped, so the walk is cheap even
  /// on an app-scale tree.
  static func swiftPackageRoots(under root: URL) -> [URL] {
    let skip: Set<String> = [
      ".git", ".build", "build", ".swiftpm", ".gradle", "node_modules", "Pods",
      "DerivedData", "checkouts", ".runs",
      // The adopter wrapper's managed family checkouts — toolchain, not repo code.
      ".duet-family",
    ]
    var roots: [URL] = []
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: nil,
        options: [.skipsPackageDescendants])
    else { return roots }
    for case let url as URL in enumerator {
      let name = url.lastPathComponent
      if skip.contains(name) {
        enumerator.skipDescendants()
        continue
      }
      if name == "Package.swift" {
        roots.append(url.deletingLastPathComponent())
      }
    }
    return roots
  }

  /// `duet lanes [--json]`
  static func run(repo: Repo, options: Options) throws -> Int32 {
    let manifest = try Manifest.load(repo: repo)
    let coverage = coverage(repo: repo, manifest: manifest)

    var featureRows: [[String: Any]] = []
    for feature in manifest.features {
      var row: [String: Any] = ["name": feature.name, "fixtures": feature.fixtures]
      if let task = feature.gradleTestTask { row["gradleTask"] = task }
      if !feature.swiftSource.isEmpty, feature.swiftSource != "pending" {
        if let package = feature.swiftPackageRelative { row["swiftPackage"] = package }
        if let target = feature.swiftTestTarget { row["swiftTestFilter"] = target }
      }
      featureRows.append(row)
    }
    let chainRows: [[String: Any]] = manifest.chains.map { chain in
      [
        "name": chain,
        "participants": Lanes.chainParticipants(of: chain, in: repo).sorted(),
      ]
    }
    var protocolLane: [String: Any] = ["command": "duet protocol-run"]
    if let runner = manifest.replayRunnerPackageDir {
      protocolLane["runnerPackage"] = Lanes.relativePath(runner, in: repo)
    } else if manifest.androidDir != nil {
      protocolLane["runnerPackage"] = ":replay-runner (Kotlin installDist)"
    }

    if options.json {
      var payload: [String: Any] = [
        "unscopedGradleTasks": manifest.androidDir != nil ? manifest.unscopedGradleTasks : [],
        "swiftPackages": manifest.swiftPackageDirs.map { Lanes.relativePath($0, in: repo) },
        "features": featureRows,
        "chains": chainRows,
        "protocolLane": protocolLane,
        "uncovered": [
          "gradleModules": coverage.gradleModulesOutsideManifest,
          "swiftPackages": coverage.swiftPackagesOutsideManifest,
          "lanes": ["the protocol lane (duet protocol-run)"],
        ] as [String: Any],
      ]
      if let androidDir = manifest.androidDir {
        payload["androidRoot"] = Lanes.relativePath(androidDir, in: repo)
      }
      Lanes.emitJSON(payload)
      return 0
    }

    print("duet lanes — derived from parity/manifest.yaml")
    if manifest.swiftPackageDirs.isEmpty {
      print("  swift lane: none (no `swift:` paths)")
    } else {
      print("  swift package roots (each runs `swift test`):")
      for dir in manifest.swiftPackageDirs { print("    \(Lanes.relativePath(dir, in: repo))") }
    }
    if let androidDir = manifest.androidDir {
      print(
        "  kotlin lane: \(Lanes.relativePath(androidDir, in: repo)) — unscoped task(s): "
          + manifest.unscopedGradleTasks.joined(separator: " "))
    } else {
      print("  kotlin lane: none (no `kotlin:` paths)")
    }
    print("  per-feature:")
    for feature in manifest.features {
      var parts: [String] = []
      if let task = feature.gradleTestTask { parts.append(task) }
      if !feature.swiftSource.isEmpty, feature.swiftSource != "pending",
        let package = feature.swiftPackageRelative, let target = feature.swiftTestTarget
      {
        parts.append("\(package) --filter \(target)")
      }
      let lane = parts.isEmpty ? "NO LANE (declared sides derive no task)" : parts.joined(separator: " · ")
      print("    \(feature.name): \(lane)")
    }
    if !manifest.chains.isEmpty {
      print("  chains (record via `duet record --chain <name>`):")
      for row in chainRows {
        let participants = (row["participants"] as? [String]) ?? []
        print("    \(row["name"] ?? ""): participants \(participants.joined(separator: ", "))")
      }
    }
    let runner = (protocolLane["runnerPackage"] as? String).map { " (runner: \($0))" } ?? ""
    print("  protocol lane: duet protocol-run\(runner) — NOT run by `duet verify`")
    print("  outside the manifest — verify makes no coverage claim; run their suites in your workflow:")
    if !coverage.gradleModulesOutsideManifest.isEmpty {
      print("    gradle modules: \(coverage.gradleModulesOutsideManifest.joined(separator: " "))")
    }
    if !coverage.swiftPackagesOutsideManifest.isEmpty {
      print("    swift packages: \(coverage.swiftPackagesOutsideManifest.joined(separator: " "))")
    }
    if coverage.gradleModulesOutsideManifest.isEmpty
      && coverage.swiftPackagesOutsideManifest.isEmpty
    {
      print("    (none found)")
    }
    return 0
  }
}
