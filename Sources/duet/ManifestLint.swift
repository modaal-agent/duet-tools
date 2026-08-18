// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import Foundation

/// The manifest meta-checks (`duet lint`, and every verb's `Manifest.load`):
/// scenario existence, fixture symmetry, the module-name mirror pin, the
/// presentation-ledger shape, and — for features declaring BOTH sources — the
/// declaration-parity cross-check, the migration-window check every
/// swift→kotlin wave passes through.
///
/// Which rules apply to a feature is derived from the manifest itself — which
/// per-feature keys exist (`swift:`/`kotlin:`) and which source set the Kotlin
/// path names (`commonMain` = single-source) — the same derivation the lane
/// code performs. No config file, and no "absent marker means legacy" keying.
///
/// The error strings predate this file (they are quoted in receipts and docs),
/// so the ported checks keep their shapes verbatim; extraction is regex-level
/// on purpose — symmetric regexes keep the two sides' extraction comparable,
/// and the brace/paren body scanners are scanners, not regexes.
struct ManifestLintResult {
  let parsed: ParsedManifest
  /// Every violation, in check order; empty = the meta-check is green.
  let errors: [String]
  let fixturesOnDisk: Int
  let pendingCount: Int
  let singleSourceCount: Int
}

enum ManifestLint {
  enum LintError: Error, CustomStringConvertible {
    case manifestUnreadable(String)
    var description: String {
      switch self {
      case let .manifestUnreadable(path):
        return "no readable parity/manifest.yaml at \(path) — a parity repo declares its features there"
      }
    }
  }

  /// Parse + all checks — the one manifest entry point (`Manifest.load` and the
  /// `lint` verb both come through here).
  static func lint(repo: Repo) throws -> ManifestLintResult {
    let url = repo.manifestFile
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
      throw LintError.manifestUnreadable(url.path)
    }
    let parsed = ManifestParser.parse(text)
    return check(parsed: parsed, repo: repo)
  }

  /// `duet lint [--json]` — the meta-checks alone, no lanes: the fast
  /// authoring-loop red, and the plan (`--json`) other tools consume.
  static func run(repo: Repo, options: Options) throws -> Int32 {
    let result = try lint(repo: repo)
    if options.json {
      Lanes.emitJSON(plan(of: result))
      return result.errors.isEmpty ? 0 : 1
    }
    if !result.errors.isEmpty {
      print("lockstep-lint: FAIL")
      for error in result.errors { print("  ✗ \(error)") }
      return 1
    }
    var suffix = ""
    if result.pendingCount > 0 { suffix += ", \(result.pendingCount) pending Kotlin port" }
    if result.singleSourceCount > 0 { suffix += ", \(result.singleSourceCount) single-source" }
    let chainsNote =
      result.parsed.chains.isEmpty ? "" : ", \(result.parsed.chains.count) chain(s)"
    let ledgerNote =
      ", ledger: \(result.parsed.waivers.count) waiver(s) / \(result.parsed.islands.count) island(s)"
    let mocksNote =
      result.parsed.mockGenerators.isEmpty
      ? "" : ", mocks: \(result.parsed.mockGenerators.count) generator(s)"
    print(
      "lockstep-lint: OK (\(result.parsed.features.count) feature(s),"
        + " \(result.fixturesOnDisk) fixture(s)\(chainsNote)\(suffix)\(ledgerNote)\(mocksNote))")
    return 0
  }

  /// The machine plan — the same shape the meta-check has always emitted
  /// (status/errors/features/chains/presentation + known top-level scalars),
  /// documented in contracts/manifest.md.
  static func plan(of result: ManifestLintResult) -> [String: Any] {
    var features: [String: Any] = [:]
    for (name, entry) in result.parsed.features {
      var spec: [String: Any] = [:]
      for (key, value) in entry.keys { spec[key] = value }
      spec["fixtures"] = entry.fixtures
      features[name] = spec
    }
    var plan: [String: Any] = [
      "status": result.errors.isEmpty ? "ok" : "fail",
      "errors": result.errors,
      "features": features,
      "chains": result.parsed.chains,
      "presentation": ["waivers": result.parsed.waivers, "islands": result.parsed.islands],
    ]
    for (key, value) in result.parsed.scalars { plan[key] = value }
    if result.parsed.hasMocksSection {
      var generators: [String: Any] = [:]
      for generator in result.parsed.mockGenerators {
        var row: [String: Any] = [:]
        for (key, value) in generator.keys { row[key] = value }
        row["sources"] = generator.sources
        row["args"] = generator.args
        generators[generator.name] = row
      }
      var mocks: [String: Any] = ["generators": generators]
      if let bundle = result.parsed.mocksScalars["bundle"] { mocks["bundle"] = bundle }
      plan["mocks"] = mocks
    }
    return plan
  }

  // MARK: - The checks

  static func check(parsed: ParsedManifest, repo: Repo) -> ManifestLintResult {
    var errors: [String] = []
    errors += parsed.topLevelErrors
    if parsed.features.isEmpty { errors.append("manifest.yaml: no features parsed") }
    errors += parsed.ledgerParseErrors
    errors += presentationErrors(parsed: parsed)
    errors += mocksErrors(parsed: parsed, repo: repo)

    let fm = FileManager.default
    var listed = Set<String>()
    func fixtureExists(_ name: String) -> Bool {
      fm.fileExists(atPath: repo.fixturesDir.appendingPathComponent("\(name).fixture.json").path)
    }

    for chain in parsed.chains {
      listed.insert(chain)
      if !fixtureExists(chain) {
        errors.append(
          "[chains] fixture listed but missing on disk: \(chain)"
            + " — just declared? run: tools/duet record")
      }
    }

    var pending = 0
    var singleSource = 0
    for name in parsed.featureOrder {
      guard let entry = parsed.features[name] else { continue }
      let keys = entry.keys
      // Fixtures are compiled from scenarios — every feature names its
      // scenario source, and the file must exist.
      let scenario = keys["scenario"] ?? ""
      if scenario.isEmpty {
        errors.append("[\(name)] missing scenario: key (fixtures are compiled from scenarios)")
      } else if !fm.fileExists(atPath: repo.root.appendingPathComponent(scenario).path) {
        errors.append("[\(name)] scenario file missing on disk: \(scenario)")
      }

      checkModuleMirror(name: name, keys: keys, errors: &errors)

      let swift = keys["swift"] ?? ""
      let kotlin = keys["kotlin"] ?? ""
      // `kotlin: pending` = declared single-sided; the port has not landed, so
      // no Kotlin-side rule applies yet.
      let kotlinReal = !kotlin.isEmpty && kotlin != "pending"
      if kotlin == "pending" { pending += 1 }
      if kotlinReal && swift.isEmpty { singleSource += 1 }

      let swiftPath = repo.root.appendingPathComponent(swift)
      let kotlinPath = repo.root.appendingPathComponent(kotlin)
      if !swift.isEmpty, !fm.fileExists(atPath: swiftPath.path) {
        errors.append("[\(name)] missing source file: \(swiftPath.path)")
      }
      if kotlinReal, !fm.fileExists(atPath: kotlinPath.path) {
        errors.append("[\(name)] missing source file: \(kotlinPath.path)")
      }

      // Declaration parity — only a feature declaring BOTH sources has a twin
      // to hold in lockstep (the dual state every migration passes through).
      if !swift.isEmpty, kotlinReal,
        let swiftSrc = try? String(contentsOf: swiftPath, encoding: .utf8),
        let kotlinSrc = try? String(contentsOf: kotlinPath, encoding: .utf8)
      {
        for (kind, key) in [("State", "state"), ("Action", "action"), ("EffectPayload", "effectPayload")] {
          guard let type = keys[key], !type.isEmpty else {
            errors.append("[\(name)] missing \(key): key (declaration parity compares the declared types)")
            continue
          }
          let swiftNames =
            kind == "State"
            ? swiftStateFields(swiftSrc, type: type, path: swift, errors: &errors)
            : swiftCases(swiftSrc, type: type, path: swift, errors: &errors)
          let kotlinNames =
            kind == "State"
            ? kotlinStateFields(kotlinSrc, type: type, path: kotlin, errors: &errors)
            : kotlinCases(kotlinSrc, type: type, path: kotlin, errors: &errors)
          compare(kind, feature: name, swift: swiftNames, kotlin: kotlinNames, errors: &errors)
        }
      }

      for fixture in entry.fixtures {
        listed.insert(fixture)
        if !fixtureExists(fixture) {
          errors.append(
            "[\(name)] fixture listed but missing on disk: \(fixture)"
              + " — just declared? run: tools/duet record --feature \(name)")
        }
      }
    }

    let onDisk = ((try? fm.contentsOfDirectory(atPath: repo.fixturesDir.path)) ?? [])
      .filter { $0.hasSuffix(".fixture.json") }
      .map { String($0.dropLast(".fixture.json".count)) }
    for orphan in Set(onDisk).subtracting(listed).sorted() {
      errors.append("fixture on disk but not in manifest: \(orphan)")
    }

    return ManifestLintResult(
      parsed: parsed, errors: errors, fixturesOnDisk: onDisk.count,
      pendingCount: pending, singleSourceCount: singleSource)
  }

  // MARK: - The presentation ledger's entry shape

  static let requiredWaiverKeys = ["kind", "feature", "platform", "manner", "reason", "since"]
  static let requiredIslandKeys = ["id", "feature", "boundary", "reason", "since"]

  static func presentationErrors(parsed: ParsedManifest) -> [String] {
    var errors: [String] = []
    func checkEntry(_ section: String, _ entry: [String: String], required: [String], idKey: String) {
      let label = entry[idKey] ?? "<missing \(idKey)>"
      let missing = required.filter { entry[$0] == nil }.sorted()
      if !missing.isEmpty {
        errors.append("[presentation] \(section) entry \(label): missing keys \(pythonList(missing))")
      }
      let feature = entry["feature"] ?? ""
      if !feature.isEmpty, parsed.features[feature] == nil {
        errors.append(
          "[presentation] \(section) entry \(label): unknown feature \(ManifestParser.pythonRepr(feature))")
      }
      if !feature.isEmpty, let ident = entry[idKey], !ident.isEmpty, !ident.hasPrefix(feature + ".") {
        errors.append(
          "[presentation] \(section) entry \(label): "
            + "\(idKey) must be prefixed \(ManifestParser.pythonRepr(feature + "."))")
      }
      if let since = entry["since"], !since.isEmpty, !isDate(since) {
        errors.append(
          "[presentation] \(section) entry \(label): since must be YYYY-MM-DD, got \(ManifestParser.pythonRepr(since))")
      }
    }
    for waiver in parsed.waivers {
      checkEntry("waivers", waiver, required: requiredWaiverKeys, idKey: "kind")
      if let platform = waiver["platform"], platform != "ios", platform != "android" {
        errors.append(
          "[presentation] waiver \(waiver["kind"] ?? "?"): "
            + "platform must be ios|android, got \(ManifestParser.pythonRepr(platform))")
      }
    }
    for island in parsed.islands {
      checkEntry("islands", island, required: requiredIslandKeys, idKey: "id")
    }
    return errors
  }

  static func isDate(_ value: String) -> Bool {
    let chars = Array(value)
    guard chars.count == 10, chars[4] == "-", chars[7] == "-" else { return false }
    return chars.enumerated().allSatisfy { index, char in
      index == 4 || index == 7 || char.isNumber
    }
  }

  // MARK: - The module-name mirror pin

  /// Pin the module-name geometry — the iOS↔Android mirror:
  /// - The Swift module (Sources/<Module>/) is `<X>Feature` with lower(X) ==
  ///   the feature name; in a split subtree the gated half is the subtree
  ///   dir's own child package at `Subtrees/<Name>/<X>Feature/Sources/<X>Feature/`
  ///   — a feature-NAMED leaf, because SwiftPM derives a path dependency's
  ///   identity from the lowercased leaf dir alone, so a generic leaf collides
  ///   with the next subtree's.
  /// - The Kotlin module dir is `feature-<name>` (flat) or
  ///   `subtrees/<name>/logic` (the split-subtree shape).
  /// - Subtree geometry moves in lockstep for dual features: swift under
  ///   Subtrees/<Name>/ iff kotlin under subtrees/<name>/.
  /// - SINGLE-SOURCE features (a `commonMain` source set): the Kotlin module
  ///   is the ONE implementation — geometry lockstep is not asserted, and the
  ///   subtree shape becomes MANDATORY (every migrated wave normalizes).
  ///   A feature with no `swift:` twin must BE single-source (commonMain).
  static func checkModuleMirror(name: String, keys: [String: String], errors: inout [String]) {
    let swift = keys["swift"] ?? ""
    let kotlin = keys["kotlin"] ?? ""
    let kotlinReal = !kotlin.isEmpty && kotlin != "pending"
    var singleSource = false
    var kotlinSubtree = false
    if kotlinReal {
      let kparts = kotlin.split(separator: "/").map(String.init)
      guard let srcIndex = kparts.firstIndex(of: "src") else {
        errors.append("[\(name)] kotlin path has no <module>/src/ segment: \(kotlin)")
        return
      }
      let kmodule = Array(kparts[1..<srcIndex])
      let flat = kmodule == ["feature-\(name)"]
      kotlinSubtree = kmodule == ["subtrees", name, "logic"]
      let sourceSet = srcIndex + 1 < kparts.count ? kparts[srcIndex + 1] : ""
      singleSource = sourceSet == "commonMain"
      if singleSource, !kotlinSubtree {
        errors.append(
          "[\(name)] single-source kotlin module `\(kmodule.joined(separator: "/"))` must be"
            + " `subtrees/\(name)/logic` — every migrated wave normalizes to the"
            + " template's subtree shape")
      } else if !(flat || kotlinSubtree) {
        errors.append(
          "[\(name)] kotlin module `\(kmodule.joined(separator: "/"))` breaks the mirror pin"
            + " (want `feature-\(name)` or `subtrees/\(name)/logic`)")
      }
      if swift.isEmpty, !singleSource, !sourceSet.isEmpty {
        errors.append(
          "[\(name)] single-source feature must live in commonMain, got src/\(sourceSet)/"
            + " — a feature with no `swift:` twin is the ONE implementation")
      }
    }
    if swift.isEmpty {
      if !kotlinReal {
        errors.append("[\(name)] declares no source path (`swift:` or `kotlin:`)")
      }
      return
    }
    let parts = swift.split(separator: "/").map(String.init)
    guard let sourcesIndex = parts.firstIndex(of: "Sources"), sourcesIndex + 1 < parts.count
    else {
      errors.append("[\(name)] swift path has no Sources/<Module>/ segment: \(swift)")
      return
    }
    let module = parts[sourcesIndex + 1]
    if !(module.hasSuffix("Feature") && module.dropLast("Feature".count).lowercased() == name) {
      errors.append(
        "[\(name)] swift module `\(module)` breaks the mirror pin"
          + " (want `<X>Feature` with lower(X) == `\(name)`)")
    }
    let swiftSubtree = parts.contains("Subtrees")
    if kotlinReal, !singleSource, swiftSubtree != kotlinSubtree {
      errors.append(
        "[\(name)] subtree geometry diverges: swift"
          + " \(swiftSubtree ? "IS" : "is NOT") under Subtrees/ but kotlin"
          + " \(kotlinSubtree ? "IS" : "is NOT") under subtrees/\(name)/logic"
          + " — re-cuts move both trees in lockstep")
    }
    if swiftSubtree, let subtreesIndex = parts.firstIndex(of: "Subtrees"),
      subtreesIndex + 1 < parts.count
    {
      let subtreeDir = parts[subtreesIndex + 1]
      if subtreeDir.lowercased() != name {
        errors.append(
          "[\(name)] subtree dir `Subtrees/\(subtreeDir)` ≠ feature `\(name)` (mirror pin)")
      }
      // Split subtree: the gated half is the subtree dir's own child package,
      // and its leaf directory name IS the module (SwiftPM path-dep identity).
      if sourcesIndex != subtreesIndex + 3 || parts[sourcesIndex - 1] != module {
        errors.append(
          "[\(name)] subtree package root `\(parts[..<sourcesIndex].joined(separator: "/"))`"
            + " breaks the subtree-layout pin (want"
            + " `Subtrees/\(subtreeDir)/\(module)/Sources/\(module)/` — feature-named"
            + " leaf, one level under the subtree dir)")
      }
    }
  }

  // MARK: - Declaration extraction (regex-level, symmetric on both sides)

  /// The brace-balanced body of the first declaration matching the pattern —
  /// a scanner from the matched opening brace, not a greedy regex.
  static func blockBody(
    _ source: String, headerPattern: String, context: String, errors: inout [String]
  ) -> Substring? {
    guard let regex = try? NSRegularExpression(pattern: headerPattern),
      let match = regex.firstMatch(
        in: source, range: NSRange(source.startIndex..., in: source)),
      let range = Range(match.range, in: source)
    else {
      errors.append("\(context): declaration not found (\(headerPattern))")
      return nil
    }
    // The pattern ends with \{ — the matched range's last character is the
    // opening brace the body scan starts from.
    var depth = 0
    let start = source.index(before: range.upperBound)
    var index = start
    while index < source.endIndex {
      let char = source[index]
      if char == "{" {
        depth += 1
      } else if char == "}" {
        depth -= 1
        if depth == 0 { return source[source.index(after: start)..<index] }
      }
      index = source.index(after: index)
    }
    errors.append("\(context): unbalanced braces")
    return nil
  }

  /// The `mocks:` section shape — `duet mocks`' config. Shape only: lint
  /// stays offline, so the bundle download and the generated files' currency
  /// are the verb's own job (`duet mocks --check`), never lint's. What IS
  /// checked: parse errors, the scalar set, the bundle-tag form, each row's
  /// required keys (`output`, `template`, and `sources:` roots or a
  /// `package:` to derive them from), on-disk existence of the declared
  /// dirs, `key=value` arg form, and row-name uniqueness.
  static func mocksErrors(parsed: ParsedManifest, repo: Repo) -> [String] {
    var errors = parsed.mocksParseErrors
    let fm = FileManager.default
    for key in parsed.mocksScalars.keys.sorted() where key != "bundle" {
      errors.append("[mocks] unknown key '\(key)' (known: bundle, generators)")
    }
    let bundle = parsed.mocksScalars["bundle"]
    if let bundle,
      bundle.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) == nil
    {
      errors.append(
        "[mocks] bundle: expected a swift-sourcery-templates release tag like 0.6.0,"
          + " got \(ManifestParser.pythonRepr(bundle))")
    }
    if bundle == nil, !parsed.mockGenerators.isEmpty {
      errors.append(
        "[mocks] generator rows declared but no bundle: tag — the rows pin the"
          + " swift-sourcery-templates release they generate with")
    }
    var seen = Set<String>()
    for generator in parsed.mockGenerators {
      let label = "[mocks.\(generator.name)]"
      if !seen.insert(generator.name).inserted {
        errors.append("\(label) duplicate generator row")
      }
      if generator.keys["output"] == nil {
        errors.append("\(label) missing output: — the committed generated file, repo-relative")
      }
      if generator.keys["template"] == nil {
        errors.append("\(label) missing template: — the entry point inside the bundle's templates/")
      }
      if generator.sources.isEmpty, generator.keys["package"] == nil {
        errors.append("\(label) needs sources: roots or a package: to derive them from")
      }
      if let package = generator.keys["package"],
        !fm.fileExists(
          atPath: repo.root.appendingPathComponent(package)
            .appendingPathComponent("Package.swift").path)
      {
        errors.append("\(label) package: \(package) has no Package.swift")
      }
      for source in generator.sources
      where !fm.fileExists(atPath: repo.root.appendingPathComponent(source).path) {
        errors.append("\(label) sources: root missing on disk: \(source)")
      }
      for arg in generator.args where !arg.contains("=") {
        errors.append(
          "\(label) args: entry is not key=value: \(ManifestParser.pythonRepr(arg))")
      }
    }
    return errors
  }

  /// Group-1 captures of every match.
  static func captures(
    _ pattern: String, in text: Substring, anchorsMatchLines: Bool = false
  ) -> [String] {
    let options: NSRegularExpression.Options = anchorsMatchLines ? [.anchorsMatchLines] : []
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
      return []
    }
    let string = String(text)
    return regex.matches(in: string, range: NSRange(string.startIndex..., in: string))
      .compactMap { Range($0.range(at: 1), in: string).map { String(string[$0]) } }
  }

  static func swiftCases(
    _ source: String, type: String, path: String, errors: inout [String]
  ) -> Set<String>? {
    guard
      let body = blockBody(
        source, headerPattern: "enum\\s+\(type)\\b[^{]*\\{", context: "\(path) \(type)",
        errors: &errors)
    else { return nil }
    // Cases live at the body's top level; nested braces are not stripped —
    // the same blind spot as the regex this ports, on purpose.
    return Set(captures("^\\s*case\\s+([a-z]\\w*)", in: body, anchorsMatchLines: true))
  }

  static func swiftStateFields(
    _ source: String, type: String, path: String, errors: inout [String]
  ) -> Set<String>? {
    guard
      let body = blockBody(
        source, headerPattern: "struct\\s+\(type)\\b[^{]*\\{", context: "\(path) \(type)",
        errors: &errors)
    else { return nil }
    return Set(captures("^\\s*public\\s+var\\s+(\\w+)\\s*:", in: body, anchorsMatchLines: true))
  }

  static func kotlinCases(
    _ source: String, type: String, path: String, errors: inout [String]
  ) -> Set<String>? {
    guard
      let body = blockBody(
        source, headerPattern: "sealed\\s+interface\\s+\(type)\\b[^{]*\\{",
        context: "\(path) \(type)", errors: &errors)
    else { return nil }
    // Kotlin PascalCase case names fold to the Swift camelCase spelling.
    return Set(
      captures("data\\s+(?:object|class)\\s+(\\w+)", in: body).map { name in
        name.prefix(1).lowercased() + name.dropFirst()
      })
  }

  static func kotlinStateFields(
    _ source: String, type: String, path: String, errors: inout [String]
  ) -> Set<String>? {
    guard let regex = try? NSRegularExpression(pattern: "data\\s+class\\s+\(type)\\s*\\("),
      let match = regex.firstMatch(
        in: source, range: NSRange(source.startIndex..., in: source)),
      let range = Range(match.range, in: source)
    else {
      errors.append("\(path): data class \(type) not found")
      return nil
    }
    var depth = 0
    let start = source.index(before: range.upperBound)
    var index = start
    while index < source.endIndex {
      let char = source[index]
      if char == "(" {
        depth += 1
      } else if char == ")" {
        depth -= 1
        if depth == 0 {
          let params = source[source.index(after: start)..<index]
          return Set(captures("va[lr]\\s+(\\w+)\\s*:", in: params))
        }
      }
      index = source.index(after: index)
    }
    errors.append("\(path): unbalanced parens in \(type)")
    return nil
  }

  static func compare(
    _ kind: String, feature: String, swift: Set<String>?, kotlin: Set<String>?,
    errors: inout [String]
  ) {
    guard let swift, let kotlin, swift != kotlin else { return }
    let onlySwift = swift.subtracting(kotlin).sorted()
    let onlyKotlin = kotlin.subtracting(swift).sorted()
    errors.append(
      "[\(feature)] \(kind) lockstep violation: "
        + "swift-only=\(renderNameSet(onlySwift)) kotlin-only=\(renderNameSet(onlyKotlin))")
  }

  /// python's rendering of `sorted(set) or '∅'` — the violation shape is
  /// quoted in receipts, so the list form matches (`['a', 'b']` / `∅`).
  static func renderNameSet(_ names: [String]) -> String {
    names.isEmpty ? "∅" : pythonList(names)
  }

  static func pythonList(_ items: [String]) -> String {
    "[" + items.map(ManifestParser.pythonRepr).joined(separator: ", ") + "]"
  }
}
