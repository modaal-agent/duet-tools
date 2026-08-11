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
    /// The subset of the above whose tests have never run anywhere — see
    /// `declaresUnresolvedTests`. Narrow by construction, so unlike the list
    /// above it is meant to be acted on rather than acknowledged.
    let swiftPackagesWithUnrunTests: [String]
  }

  /// Does this package declare tests that no lane has ever built?
  ///
  /// The signal is the absence of a `Package.resolved`. A package acquires one
  /// the first time anything resolves it as a ROOT — `swift test`, `xcodebuild`
  /// against its scheme — and never from being consumed as a dependency, since
  /// the consumer's lock is the one that gets written. So no lock means no lane
  /// has ever built this package standalone, and a test target it declares has
  /// never run.
  ///
  /// Two conditions keep it from over-firing, both measured on the reference
  /// repo:
  ///
  /// - **It must declare a test target.** A pure library that no lane builds
  ///   standalone is the normal case, not a finding.
  /// - **It must declare at least one REMOTE dependency.** SwiftPM writes no
  ///   lock for a package whose dependencies are all local paths, however often
  ///   it is built — the reference repo's boundary-lane package runs on every
  ///   push and has no lock, because its only dependency is a path-local
  ///   binary target. Without this condition that package is a false positive.
  ///
  /// `lockPresent` is existence on disk. In CI — a fresh checkout, which is
  /// where this gates — that is exactly "committed". A local tree can hold an
  /// untracked lock from a one-off build, which makes the check silent there;
  /// it under-reports rather than misreports.
  ///
  /// A package aggregated by an `.xcworkspace` never reaches here — see
  /// `workspaceMemberPaths`. Measured: a workspace resolves its members as
  /// roots and writes ONE lock at
  /// `<workspace>/xcshareddata/swiftpm/Package.resolved`; the members get
  /// none, so for them the absence of a lock says nothing at all.
  static func declaresUnresolvedTests(manifestText: String, lockPresent: Bool) -> Bool {
    if lockPresent { return false }
    let source = strippingLineComments(manifestText)
    guard source.contains(".testTarget(") else { return false }
    return source.range(of: #"\.package\([^)]*url:"#, options: .regularExpression) != nil
  }

  /// Package directories aggregated by an `.xcworkspace` anywhere in the repo,
  /// standardized absolute paths.
  ///
  /// An aggregate workspace — the "AllTests" shape, one workspace listing every
  /// package so a single scheme runs the lot — is a resolution root for its
  /// members, and it writes ONE lock of its own. Its members therefore never
  /// get a `Package.resolved`, however often their tests run, which is the
  /// second false-positive class after path-only dependencies (measured: a
  /// probe workspace over one package resolved to
  /// `AllTests.xcworkspace/xcshareddata/swiftpm/Package.resolved` and left the
  /// package's own root empty). Membership alone is the exemption, whether or
  /// not the workspace's lock is committed: the signal cannot see through a
  /// workspace, so it must not claim through one either.
  static func workspaceMemberPaths(under root: URL) -> Set<String> {
    var members: Set<String> = []
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants])
    else { return members }
    for case let url as URL in enumerator {
      let name = url.lastPathComponent
      if skippedWalkDirs.contains(name) {
        enumerator.skipDescendants()
        continue
      }
      guard name.hasSuffix(".xcworkspace") else { continue }
      enumerator.skipDescendants()
      // A project's own `project.xcworkspace` aggregates nothing — its package
      // references are dependencies of the project, not roots.
      guard url.deletingLastPathComponent().pathExtension != "xcodeproj" else { continue }
      let contents = url.appendingPathComponent("contents.xcworkspacedata")
      guard let text = try? String(contentsOf: contents, encoding: .utf8) else { continue }
      let base = url.deletingLastPathComponent()
      for reference in workspaceFileRefs(inContentsText: text) {
        members.insert(
          base.appendingPathComponent(reference).standardizedFileURL.path)
      }
    }
    return members
  }

  /// The `location` paths of a workspace's `FileRef`s, relative to the
  /// workspace's own directory. `group:` and `container:` both resolve that way
  /// for a workspace at the top of its tree; anything absolute is passed
  /// through and simply fails to match a package root.
  static func workspaceFileRefs(inContentsText text: String) -> [String] {
    var refs: [String] = []
    var rest = Substring(text)
    while let marker = rest.range(of: "location") {
      rest = rest[marker.upperBound...]
      guard let open = rest.firstIndex(of: "\"") else { break }
      rest = rest[rest.index(after: open)...]
      guard let close = rest.firstIndex(of: "\"") else { break }
      var value = String(rest[..<close])
      rest = rest[rest.index(after: close)...]
      for prefix in ["group:", "container:", "self:"] where value.hasPrefix(prefix) {
        value = String(value.dropFirst(prefix.count))
      }
      if !value.isEmpty { refs.append(value) }
    }
    return refs
  }

  /// Manifest text with `//` line comments removed, so a commented-out target
  /// or dependency does not read as a declaration. String literals in a
  /// manifest carry URLs (`https://`), so the scan tracks quotes.
  static func strippingLineComments(_ text: String) -> String {
    var out = ""
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      var inString = false
      var previous: Character?
      var cut: String.Index?
      var index = line.startIndex
      while index < line.endIndex {
        let character = line[index]
        if character == "\"", previous != "\\" { inString.toggle() }
        if !inString, character == "/", previous == "/" {
          cut = line.index(index, offsetBy: -1)
          break
        }
        previous = character
        index = line.index(after: index)
      }
      out += (cut.map { String(line[..<$0]) } ?? String(line)) + "\n"
    }
    return out
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
    let outsideRoots = swiftPackageRoots(under: repo.root)
      .filter { !declaredSwift.contains($0.standardizedFileURL.path) }
    let swiftOutside = outsideRoots.map { Lanes.relativePath($0, in: repo) }.sorted()
    // Only roots the manifest does not claim: the ones it does are what verify
    // itself runs, so their lanes are not in question.
    let workspaceMembers = workspaceMemberPaths(under: repo.root)
    let unrun = outsideRoots.filter { root in
      guard !workspaceMembers.contains(root.standardizedFileURL.path) else { return false }
      guard
        let text = try? String(
          contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
      else { return false }
      let lock = FileManager.default.fileExists(
        atPath: root.appendingPathComponent("Package.resolved").path)
      return declaresUnresolvedTests(manifestText: text, lockPresent: lock)
    }
    .map { Lanes.relativePath($0, in: repo) }
    .sorted()
    return Coverage(
      gradleModulesOutsideManifest: gradleOutside,
      swiftPackagesOutsideManifest: swiftOutside,
      swiftPackagesWithUnrunTests: unrun)
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

  /// Build products, VCS internals, and dependency checkouts — skipped by every
  /// walk here, so scanning an app-scale tree stays cheap.
  static let skippedWalkDirs: Set<String> = [
    ".git", ".build", "build", ".swiftpm", ".gradle", "node_modules", "Pods",
    "DerivedData", "checkouts", ".runs",
    // The adopter wrapper's managed family checkouts — toolchain, not repo code.
    ".duet-family",
  ]

  /// Every directory holding a Package.swift, bounded by `skippedWalkDirs`.
  static func swiftPackageRoots(under root: URL) -> [URL] {
    let skip = skippedWalkDirs
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
          "swiftPackagesWithUnrunTests": coverage.swiftPackagesWithUnrunTests,
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
    if !coverage.swiftPackagesWithUnrunTests.isEmpty {
      print("  tests that have never run — these declare a test target and have no lock:")
      for path in coverage.swiftPackagesWithUnrunTests { print("    \(path)") }
      print("    (`duet doctor` fails on these)")
    }
    return 0
  }
}
