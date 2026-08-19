// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import Foundation

/// The host-lane meta-check: what a gated unit RESOLVES, on both build systems.
///
/// The invariant — "the feature core carries no platform dependencies" — used to
/// be enforced at the build-product layer and silently unenforced above it:
/// SwiftPM's `condition: .when(platforms:)` gates LINKING only, while version
/// resolution and build-tool-plugin planning walk straight through it. An app
/// library reachable from a host-lane root therefore puts its whole toolchain
/// surface (codegen plugins included) inside the parity gate's blast radius —
/// the gate then breaks on tooling the gate does not test. The split-subtree
/// geometry fixes the graph (the gated feature package resolves the Duet family
/// only; app deps live in the sibling node package no host lane roots); these
/// checks are what keep it fixed.
///
/// Toolchain-owned so every adopter repo gets the gate without copying a lint,
/// and root-scoped so coverage is total by construction: the gated units derive
/// from the manifest exactly as the lanes do, so a new feature package arrives
/// pre-gated the moment its manifest entry lands.
///
/// Three checks:
///  1. Every Swift host-lane root's `Package.resolved` pins the Duet family
///     only (a local-path family dependency resolves nothing remotely — a repo
///     with no remote deps legitimately has no lockfile). With no lockfile the
///     manifest TREE is the receipt instead: the root's manifest and every
///     `.package(path:` child, recursed, must declare no `.package(url:` —
///     this check runs before the lanes, so on a fresh checkout a remote dep
///     behind a path dep has no lockfile to show up in.
///  2. Every gated Kotlin module declares the family plugin/dependency
///     allowlist only, recursing through `project(...)` edges — Gradle resolves
///     per-configuration so the SwiftPM leak class cannot arise the same way,
///     but "cannot arise today" is construction, not a gate.
///  3. Kernel-shape declarations (reducers, and the manifest's
///     State/Action/EffectPayload types) live in gated packages only — outside
///     a lane a declaration is invisible to both declaration-parity and the
///     fixture gate.
enum HostLane {

  // The allowlists are the invariant written down, family-owned: short reviewed
  // lists, never patterns, growing only when the family does. App-local growth
  // needs no entry here by construction — Swift path deps never enter a
  // lockfile, and Gradle `project(...)` deps recurse instead of matching — so
  // only a new EXTERNAL artifact in a gated unit is a family decision.

  /// `duet` ships the framework, DuetShells, DuetTesting and DuetReplay in one
  /// package; `duet-services` ships the services and telemetry tier. When the
  /// family grows again, this list is where it is declared.
  static let swiftFamilyAllowlist: Set<String> = ["duet", "duet-services"]

  /// A gated Kotlin module is a plain Kotlin module: the JVM or multiplatform
  /// plugin plus serialization. An AGP plugin here is the same violation as an
  /// app library in a Swift host root.
  static let gradlePluginAllowlist: Set<String> = [
    "libs.plugins.kotlin.jvm",
    "libs.plugins.kotlin.multiplatform",
    "libs.plugins.kotlin.serialization",
    // KSP carries the family mock engine (dev.modaal:mocks-processor) into
    // the TEST compilation. The plugin is admitted; where a processor may be
    // wired is checked per configuration below (kspTest/kspJvmTest only).
    "libs.plugins.ksp",
  ]

  /// The kernel, its serialization dialect, and the test bracket.
  static let gradleDependencyAllowlist: Set<String> = [
    "libs.duet.kernel",
    "libs.duet.kernel.test",
    "libs.kotlinx.serialization.json",
    "libs.kotlinx.coroutines.test",
    "kotlin(\"test\")",
  ]

  /// Symbol processors a gated module may wire into its TEST compilation
  /// (`kspTest`/`kspJvmTest`): the family mock engine only. Any other `ksp*`
  /// configuration — `ksp(...)`, `kspJvm(...)`, a native target's — is a
  /// placement violation regardless of artifact: generated code must never
  /// reach a main/commonMain classpath, and generated mocks are host-lane
  /// (JVM-test) products only.
  static let gradleKspAllowlist: Set<String> = [
    "libs.mocks.processor"
  ]

  /// Build products and tool state the declaration sweep never enters.
  static let sweepSkipDirs: Set<String> = [
    ".build", ".swiftpm", ".index-build", ".gradle", ".git", "build", "DerivedData",
  ]

  /// Runs all three checks; returns human-readable errors (empty = green).
  static func check(repo: Repo, manifest: Manifest) -> [String] {
    var errors: [String] = []
    let swiftRoots = Set(manifest.features.compactMap(\.swiftPackageRelative)).sorted()
    let kotlinRoots = Set(manifest.features.compactMap(kotlinModuleRoot)).sorted()

    for root in swiftRoots {
      checkSwiftRootLock(root, repo: repo, errors: &errors)
    }
    var seen: Set<String> = []
    for module in kotlinRoots {
      checkGatedGradleModule(
        module, seen: &seen, gradleRoot: String(module.split(separator: "/")[0]),
        via: [], repo: repo, errors: &errors)
    }
    checkDeclarationScope(
      manifest: manifest, swiftRoots: swiftRoots, kotlinRoots: kotlinRoots,
      repo: repo, errors: &errors)
    return errors
  }

  /// The Gradle module directory a feature's `kotlin:` path belongs to — the
  /// repo-relative prefix before /src/ (skipped for `kotlin: pending` twins).
  static func kotlinModuleRoot(_ feature: Feature) -> String? {
    let parts = feature.kotlinSource.split(separator: "/").map(String.init)
    guard let index = parts.firstIndex(of: "src"), index > 0 else { return nil }
    return parts[..<index].joined(separator: "/")
  }

  // MARK: - 1. Swift host-root lockfiles

  private static func checkSwiftRootLock(_ root: String, repo: Repo, errors: inout [String]) {
    let rootURL = repo.root.appendingPathComponent(root)
    let lockURL = rootURL.appendingPathComponent("Package.resolved")
    guard FileManager.default.fileExists(atPath: lockURL.path) else {
      // No lockfile is legal exactly when nothing resolves remotely (a
      // manifest whose dependencies are all local paths). A manifest that declares a
      // remote dependency without a committed lock is the gap the check
      // exists for — the resolved set IS the receipt. The sweep recurses
      // through `.package(path:` edges — the mirror of the Gradle
      // `project(...)` recursion — because path deps never enter a lockfile
      // and this check runs BEFORE the lanes: a remote artifact declared
      // behind a path dep would otherwise stay invisible until a resolution
      // materializes the root's lockfile, which a fresh checkout (every CI
      // run) never has.
      var seen: Set<String> = []
      checkManifestTree(rootURL, root: root, repo: repo, via: [], seen: &seen, errors: &errors)
      return
    }
    guard let data = try? Data(contentsOf: lockURL),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      errors.append("[host-lane] \(root)/Package.resolved is not parseable JSON")
      return
    }
    // v2/v3 keep pins at the top level; v1 nested them under `object`.
    let pins =
      (object["pins"] as? [[String: Any]])
      ?? ((object["object"] as? [String: Any])?["pins"] as? [[String: Any]]) ?? []
    let identities = Set(
      pins.compactMap { ($0["identity"] as? String) ?? ($0["package"] as? String) }
        .map { $0.lowercased() })
    let outside = identities.subtracting(swiftFamilyAllowlist).sorted()
    if !outside.isEmpty {
      errors.append(
        "[host-lane] host-lane root `\(root)` resolves \(outside) — outside the allowlist"
          + " \(swiftFamilyAllowlist.sorted()). A host root's RESOLVED set is the Duet"
          + " family only. App-layer libraries (and the build-tool plugins they drag in)"
          + " belong in the sibling node package, not behind a `condition:` — conditions"
          + " gate linking, not resolution.")
    }
  }

  /// The lockless half of check 1: walks a package's manifest and every
  /// `.package(path:` child (cycle-guarded), flagging any `.package(url:`
  /// declaration in the tree — with no lockfile, the manifests ARE the only
  /// receipt of what a resolution would fetch.
  private static func checkManifestTree(
    _ packageDir: URL, root: String, repo: Repo, via: [String], seen: inout Set<String>,
    errors: inout [String]
  ) {
    let canonical = packageDir.standardizedFileURL.resolvingSymlinksInPath().path
    if seen.contains(canonical) { return }
    seen.insert(canonical)
    let manifestURL = packageDir.appendingPathComponent("Package.swift")
    guard let source = try? String(contentsOf: manifestURL, encoding: .utf8) else {
      // The root's own manifest problems surface through the lanes; a CHILD
      // the root declares but the sweep cannot read is named here — the fix
      // belongs at the declaring edge.
      if !via.isEmpty {
        errors.append(
          "[host-lane] host-lane root `\(root)` declares a path dependency with no"
            + " readable Package.swift: \(via.joined(separator: " → "))")
      }
      return
    }
    let uncommented = strippedOfLineComments(source)
    if uncommented.contains(".package(url:") {
      if via.isEmpty {
        errors.append(
          "[host-lane] host-lane root `\(root)` declares remote dependencies but has no"
            + " committed Package.resolved — the resolved set IS the receipt: run"
            + " `swift package resolve` there and commit the lock")
      } else {
        errors.append(
          "[host-lane] host-lane root `\(root)` reaches remote dependencies through a"
            + " path dependency (\(via.joined(separator: " → "))) and has no committed"
            + " Package.resolved — the resolved set IS the receipt: run"
            + " `swift package resolve` at the root and commit the lock, and expect the"
            + " resolved-set rule to gate what appears there")
      }
    }
    for path in pathDependencyPaths(inManifest: uncommented) {
      let child =
        path.hasPrefix("/")
        ? URL(fileURLWithPath: path) : packageDir.appendingPathComponent(path)
      // Label repo-local children repo-relative; a checkout outside the repo
      // (an absolute path) keeps its declared spelling.
      let childPath = child.standardizedFileURL.path
      let rootPath = repo.root.standardizedFileURL.path
      let label =
        childPath.hasPrefix(rootPath + "/")
        ? String(childPath.dropFirst(rootPath.count + 1)) : path
      checkManifestTree(
        child, root: root, repo: repo, via: via + [label], seen: &seen, errors: &errors)
    }
  }

  /// A manifest source with `//` line comments removed (the same stripping the
  /// Gradle half applies before matching).
  static func strippedOfLineComments(_ source: String) -> String {
    source.split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.components(separatedBy: "//")[0] }
      .joined(separator: "\n")
  }

  /// The `path:` values of `.package(path:)` / `.package(name:, path:)`
  /// declarations. Pass comment-stripped source.
  static func pathDependencyPaths(inManifest uncommented: String) -> [String] {
    let pattern = #"\.package\(\s*(?:name:\s*"[^"]*"\s*,\s*)?path:\s*"([^"]+)""#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(uncommented.startIndex..., in: uncommented)
    return regex.matches(in: uncommented, range: range).compactMap { match in
      Range(match.range(at: 1), in: uncommented).map { String(uncommented[$0]) }
    }
  }

  // MARK: - 2. The Gradle twin

  private static func checkGatedGradleModule(
    _ module: String, seen: inout Set<String>, gradleRoot: String, via: [String],
    repo: Repo, errors: inout [String]
  ) {
    if seen.contains(module) { return }
    seen.insert(module)
    // A module reached through project deps names the path that reached it —
    // the fix usually belongs at the edge, not at the far end of it.
    let label = (via + [module]).joined(separator: " → ")
    let buildURL = repo.root.appendingPathComponent(module).appendingPathComponent(
      "build.gradle.kts")
    guard let source = try? String(contentsOf: buildURL, encoding: .utf8) else {
      errors.append("[host-lane] gated Kotlin module `\(label)` has no build.gradle.kts")
      return
    }
    let scan = scanGatedBuildScript(label: label, source: source)
    errors.append(contentsOf: scan.errors)
    for gradlePath in scan.projectPaths {
      let child = "\(gradleRoot)/\(gradlePath.replacingOccurrences(of: ":", with: "/"))"
      checkGatedGradleModule(
        child, seen: &seen, gradleRoot: gradleRoot, via: via + [module],
        repo: repo, errors: &errors)
    }
  }

  /// One gated build script's line scan — pure on the source text so every
  /// rule is unit-testable: plugin aliases/ids against the plugin allowlist,
  /// dependency declarations against the dependency allowlist, `ksp*`
  /// processor wiring against the ksp allowlist AND its placement rule
  /// (test configurations only). Returned `projectPaths` are the
  /// root-relative `project(":a:b")` edges (`a:b`) the caller recurses into.
  static func scanGatedBuildScript(
    label: String, source: String
  ) -> (errors: [String], projectPaths: [String]) {
    var errors: [String] = []
    var projectPaths: [String] = []
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.components(separatedBy: "//")[0] }
    for line in lines {
      if let range = line.range(of: #"alias\(([\w.]+)\)"#, options: .regularExpression) {
        let alias = String(line[range].dropFirst("alias(".count).dropLast())
        if !gradlePluginAllowlist.contains(alias) {
          errors.append(pluginError(label: label, plugin: alias))
        }
      }
      if let range = line.range(of: #"\bid\("[^"]+"\)"#, options: .regularExpression) {
        let plugin = String(line[range])
        if !gradlePluginAllowlist.contains(plugin) {
          errors.append(pluginError(label: label, plugin: plugin))
        }
      }
      // Both spellings: `kspTest(...)` (type-safe accessor, plain JVM module)
      // and `"kspJvmTest"(...)` (string invoke — a multiplatform target's ksp
      // configurations exist only after the kotlin block evaluates, so the
      // accessor never does).
      if let range = line.range(
        of: #"^\s*"?ksp[A-Za-z0-9]*"?\((.+)\)\s*$"#, options: .regularExpression)
      {
        let call = String(line[range]).trimmingCharacters(in: .whitespaces)
        let configuration = String(call[call.startIndex..<call.firstIndex(of: "(")!])
          .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let dependency = String(
          call[call.index(after: call.firstIndex(of: "(")!)..<call.index(before: call.endIndex)])
        if configuration != "kspTest" && configuration != "kspJvmTest" {
          errors.append(
            "[host-lane] gated Kotlin module `\(label)` wires a symbol processor into"
              + " `\(configuration)` — processors are test-only in a gated module"
              + " (kspTest/kspJvmTest): generated code must never reach a main/commonMain"
              + " classpath.")
        } else if let projectPath = projectEdge(dependency) {
          projectPaths.append(projectPath)
        } else if !gradleKspAllowlist.contains(dependency) {
          errors.append(
            "[host-lane] gated Kotlin module `\(label)` wires `\(dependency)` into"
              + " `\(configuration)` — outside the processor allowlist"
              + " \(gradleKspAllowlist.sorted()). A gated module's test-time symbol"
              + " processors are the family mock engine only.")
        }
        continue
      }
      guard
        let range = line.range(
          of: #"^\s*(?:api|implementation|testImplementation|compileOnly|runtimeOnly|testRuntimeOnly)\((.+)\)\s*$"#,
          options: .regularExpression)
      else { continue }
      let call = String(line[range]).trimmingCharacters(in: .whitespaces)
      let dependency = String(
        call[call.index(after: call.firstIndex(of: "(")!)..<call.index(before: call.endIndex)])
      if let projectPath = projectEdge(dependency) {
        projectPaths.append(projectPath)
        continue
      }
      if !gradleDependencyAllowlist.contains(dependency) {
        errors.append(
          "[host-lane] gated Kotlin module `\(label)` declares `\(dependency)` — outside"
            + " the dependency allowlist \(gradleDependencyAllowlist.sorted()). A gated"
            + " module's external dependencies are the kernel family only; app-local"
            + " libraries arrive as project(...) deps, which are checked recursively.")
      }
    }
    return (errors, projectPaths)
  }

  /// `project(":a:b")` → `a:b` (Gradle paths are root-relative; the sweep
  /// works in repo-relative paths); nil for anything else.
  private static func projectEdge(_ dependency: String) -> String? {
    guard
      let projectRange = dependency.range(
        of: #"^project\(":[\w:.-]+"\)$"#, options: .regularExpression)
    else { return nil }
    return String(
      dependency[projectRange]
        .dropFirst(#"project(":"#.count).dropLast(#"")"#.count))
  }

  private static func pluginError(label: String, plugin: String) -> String {
    "[host-lane] gated Kotlin module `\(label)` applies `\(plugin)` — outside the plugin"
      + " allowlist \(gradlePluginAllowlist.sorted()). The gated half is a plain Kotlin"
      + " module; anything needing AGP belongs app-side."
  }

  // MARK: - 3. Kernel declaration scope

  private static func checkDeclarationScope(
    manifest: Manifest, swiftRoots: [String], kotlinRoots: [String],
    repo: Repo, errors: inout [String]
  ) {
    // Sweep the trees the manifest's own paths name (the Swift packages' tree,
    // the Gradle root) — a sweep rather than a per-file opt-in, so a new
    // un-gated directory is covered the day it lands.
    let swiftTrees = Set(swiftRoots.compactMap { $0.split(separator: "/").first.map(String.init) })
    let kotlinTrees = Set(kotlinRoots.compactMap { $0.split(separator: "/").first.map(String.init) })
    var declaredTypes: [String: String] = [:]
    for feature in manifest.features {
      for typeName in [feature.stateType, feature.actionType, feature.payloadType]
      where !typeName.isEmpty {
        declaredTypes[typeName] = feature.name
      }
    }
    let sweeps: [(trees: Set<String>, suffix: String, gated: [String], reducer: String, keyword: String)] = [
      (
        swiftTrees, ".swift", swiftRoots.map { $0 + "/" },
        #"^\s*(?:public\s+|internal\s+|private\s+|fileprivate\s+)?func\s+[A-Za-z0-9_]*[Rr]educer\s*\("#,
        #"(?:struct|enum|final\s+class|class|actor)"#
      ),
      (
        kotlinTrees, ".kt", kotlinRoots.map { $0 + "/" },
        #"^\s*(?:public\s+|internal\s+|private\s+)?fun\s+[A-Za-z0-9_]*[Rr]educer\s*\("#,
        #"(?:data\s+class|sealed\s+interface|sealed\s+class|data\s+object|class|object)"#
      ),
    ]
    let typeNames = declaredTypes.keys.sorted().map(NSRegularExpression.escapedPattern(for:))
      .joined(separator: "|")
    for sweep in sweeps {
      let typePattern =
        typeNames.isEmpty ? nil : #"^\s*(?:\w+\s+)*"# + sweep.keyword + #"\s+(\#(typeNames))\b"#
      for tree in sweep.trees.sorted() {
        sweepTree(
          tree, suffix: sweep.suffix, gatedPrefixes: sweep.gated,
          reducerPattern: sweep.reducer, typePattern: typePattern,
          declaredTypes: declaredTypes, repo: repo, errors: &errors)
      }
    }
  }

  private static func sweepTree(
    _ tree: String, suffix: String, gatedPrefixes: [String], reducerPattern: String,
    typePattern: String?, declaredTypes: [String: String], repo: Repo, errors: inout [String]
  ) {
    let treeURL = repo.root.appendingPathComponent(tree)
    guard
      let enumerator = FileManager.default.enumerator(
        at: treeURL, includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles])
    else { return }
    let rootPath = repo.root.standardizedFileURL.path
    while let entry = enumerator.nextObject() as? URL {
      if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
        if sweepSkipDirs.contains(entry.lastPathComponent) { enumerator.skipDescendants() }
        continue
      }
      guard entry.path.hasSuffix(suffix) else { continue }
      let path = entry.standardizedFileURL.path
      let relative = path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : path
      if gatedPrefixes.contains(where: relative.hasPrefix) { continue }
      guard let source = try? String(contentsOf: entry, encoding: .utf8) else { continue }
      for (number, line) in source.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      {
        if line.range(of: reducerPattern, options: .regularExpression) != nil {
          errors.append(
            "[host-lane/scope] \(relative):\(number + 1) declares a reducer outside a"
              + " gated package — reducers (and the State/Action/EffectPayload they bind)"
              + " live in feature packages, the ones `duet verify` roots. Outside a lane"
              + " a declaration is invisible to both declaration-parity and the fixture"
              + " gate.")
        }
        if let typePattern = typePattern,
          let range = line.range(of: typePattern, options: .regularExpression)
        {
          let matched = String(line[range])
          let name = declaredTypes.keys.sorted(by: { $0.count > $1.count })
            .first { matched.hasSuffix($0) || matched.contains($0) } ?? matched
          let owner = declaredTypes[name] ?? "?"
          errors.append(
            "[host-lane/scope] \(relative):\(number + 1) re-declares `\(name)` — the"
              + " kernel shape of feature `\(owner)`, which is gated elsewhere. One"
              + " declaration, in the feature package.")
        }
      }
    }
  }
}
