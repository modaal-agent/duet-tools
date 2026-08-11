// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import Foundation

/// `duet doctor` — the declaration-vs-disk cross-check, two rows:
///
/// **[declarations]** — `.modaal/project.json` is the repo's declaration
/// layer: which app targets exist, on which platform, emitted from which
/// template, paired across platforms how. Nothing else validates it (the
/// byte gates read `parity/manifest.yaml`, never the declarations), so a
/// target claiming a template whose shape the repo does not have — or a
/// template name nothing models — stays green everywhere. Doctor reads the
/// declarations and answers: "this repo says X; here is what X implies;
/// here is what is on disk." This is the CLI's only `.modaal` consumer —
/// gate derivation stays manifest-only.
///
/// **[workers]** — the worker-isolation lint: a `Working` conformer
/// (directly, via a refining protocol, or via a superclass) declared
/// `@unchecked Sendable` in non-test sources. The compiler cannot catch
/// this — under complete concurrency checking a `@MainActor` class is
/// already implicitly `Sendable`, so the redundant `@unchecked` stamp
/// compiles with no diagnostic while silencing the checking on every
/// worker that is NOT isolated. Test sources are out of scope: a test
/// double conforming to a `@MainActor` protocol infers isolation whatever
/// `Sendable` conformance it declares.
///
/// Exit 0 with a scan summary when both rows are clean; exit 1 listing
/// findings otherwise. Doctor never rewrites anything.
enum Doctor {

  // MARK: - [declarations] — .modaal/project.json vs the manifest's shape

  /// The template names this toolchain models, with the repo shape each
  /// implies. Grows with the family's catalog; an unmodeled name in a
  /// declaration is a finding (the mis-declaration case: gates ran green
  /// for two specs with a nonexistent name in this field).
  static let knownTemplates: Set<String> = [
    "duet-kmp", "duet-swift-ios", "duet-swift-scene",
  ]

  /// Templates whose repo shape carries a Kotlin lane. The others are
  /// single-core Swift: pure SwiftPM, no Kotlin twin.
  static let kotlinShapedTemplates: Set<String> = ["duet-kmp"]

  /// Templates with an Android target arm.
  static let androidCapableTemplates: Set<String> = ["duet-kmp"]

  /// What the declarations are checked against. `fileExists` takes a
  /// repo-relative path — injected so the checks stay pure.
  struct Geometry {
    var kotlinShaped: Bool
    var fileExists: (String) -> Bool
  }

  /// Findings for the declaration layer. `projectJSON` is the raw file
  /// content, nil when the file is absent. Deny-nothing like every reader
  /// of this file: keys and targets the check has no name for produce no
  /// finding — only named keys with the wrong shape, and declarations
  /// whose implications the disk contradicts, are findings.
  static func declarationFindings(projectJSON: Data?, geometry: Geometry) -> [String] {
    let file = ".modaal/project.json"
    guard let projectJSON else {
      return ["[declarations] \(file): missing — the repo declares no targets"]
    }
    guard let root = try? JSONSerialization.jsonObject(with: projectJSON),
      let metadata = root as? [String: Any]
    else {
      return ["[declarations] \(file): not a JSON object"]
    }

    var findings: [String] = []

    if let duet = metadata["duet"], !(duet is [String: Any]) {
      findings.append("[declarations] \(file): `duet` is not an object")
    }
    if let duet = metadata["duet"] as? [String: Any] {
      if let flavor = duet["flavor"] as? String, flavor != "swift", flavor != "kmp" {
        findings.append(
          "[declarations] \(file): `duet.flavor` is '\(flavor)' — this toolchain models 'swift' and 'kmp'")
      }
      if let template = duet["template"] as? String, !knownTemplates.contains(template) {
        findings.append(
          "[declarations] \(file): `duet.template` names no template this toolchain models: '\(template)'")
      }
    }

    guard let targetsAny = metadata["targets"] else { return findings }
    guard let targets = targetsAny as? [String: Any] else {
      findings.append("[declarations] \(file): `targets` is not an object")
      return findings
    }

    let xcodegenRoot = metadata["xcodegen_root"] as? String ?? "src-ios/App"
    var templateByPair: [String: [String: [String]]] = [:]

    for name in targets.keys.sorted() {
      guard let entry = targets[name] as? [String: Any] else {
        findings.append("[declarations] \(file): target '\(name)' is not an object")
        continue
      }
      let platform = (entry["platform"] as? String)?
        .trimmingCharacters(in: .whitespaces) ?? ""
      if platform.isEmpty {
        findings.append("[declarations] \(file): target '\(name)' declares no `platform`")
      }
      let template = entry["template"] as? String
      if entry["template"] != nil, template == nil {
        findings.append("[declarations] \(file): target '\(name)': `template` is not a string")
      }
      if let pair = entry["pair"] {
        guard let pair = pair as? String, !pair.isEmpty else {
          findings.append(
            "[declarations] \(file): target '\(name)': `pair` is not a non-empty string")
          continue
        }
        guard let template else {
          findings.append(
            "[declarations] \(file): target '\(name)' declares `pair` without `template` — "
              + "`pair` is the cross-platform group id of template-emitted targets")
          continue
        }
        templateByPair[pair, default: [:]][template, default: []].append(name)
      }
      guard let template else { continue }  // unmarked target: not this row's jurisdiction

      guard knownTemplates.contains(template) else {
        findings.append(
          "[declarations] \(file): target '\(name)' names no template this toolchain models: "
            + "'\(template)' (models: \(knownTemplates.sorted().joined(separator: ", ")))")
        continue
      }
      let kotlinTemplate = kotlinShapedTemplates.contains(template)
      if kotlinTemplate, !geometry.kotlinShaped {
        findings.append(
          "[declarations] target '\(name)' declares '\(template)' but the parity manifest "
            + "derives no Kotlin lane")
      }
      if !kotlinTemplate, geometry.kotlinShaped {
        findings.append(
          "[declarations] target '\(name)' declares '\(template)' but the parity manifest "
            + "derives a Kotlin lane — that template's shape has none")
      }
      if platform.lowercased() == "android", !androidCapableTemplates.contains(template) {
        findings.append(
          "[declarations] target '\(name)': platform 'Android' with template '\(template)' — "
            + "that template has no Android target shape")
      }
      if platform.lowercased() == "ios" {
        let spec = "\(xcodegenRoot)/xcodegen.yml"
        if !geometry.fileExists(spec) {
          findings.append(
            "[declarations] target '\(name)' declares an iOS target but \(spec) is absent")
        }
      }
    }

    for pair in templateByPair.keys.sorted() {
      let byTemplate = templateByPair[pair] ?? [:]
      guard byTemplate.count > 1 else { continue }
      let members = byTemplate.keys.sorted()
        .flatMap { template in (byTemplate[template] ?? []).map { "\($0) → '\(template)'" } }
        .joined(separator: ", ")
      findings.append(
        "[declarations] pair '\(pair)': members disagree on `template` (\(members)) — "
          + "both members of a pair are emitted from one template")
    }
    return findings
  }

  // MARK: - [workers] — Working conformers stamped @unchecked Sendable

  /// One parsed declaration header: everything between the introducer
  /// keyword and the body's `{`, with the generic parameter list and any
  /// `where` clause stripped.
  struct Declaration {
    var name: String
    var line: Int
    /// Top-level entries of the inheritance clause, each reduced to its
    /// last dotted identifier with generic arguments stripped
    /// (`DuetShells.Working` → `Working`, `Store<S>` → `Store`).
    var conformances: [String]
    var declaresUncheckedSendable: Bool
  }

  private static let declarationRegex = try! NSRegularExpression(
    pattern: #"\b(class|struct|actor|enum|protocol|extension)\s+([A-Za-z_][A-Za-z0-9_]*)"#)

  /// Parses declaration headers out of one source file. Textual on purpose
  /// — the lint runs on repos whose sources need not compile on this host.
  /// Line comments are stripped first (newlines kept, so reported lines are
  /// real); block comments and string literals are not modeled, matching
  /// the family's other source sweeps.
  static func declarations(inSource source: String) -> [Declaration] {
    let stripped = source.split(separator: "\n", omittingEmptySubsequences: false)
      .map { line -> Substring in
        if let slash = line.range(of: "//") { return line[..<slash.lowerBound] }
        return line
      }
      .joined(separator: "\n")

    var results: [Declaration] = []
    let ns = stripped as NSString
    for match in declarationRegex.matches(
      in: stripped, range: NSRange(location: 0, length: ns.length))
    {
      let name = ns.substring(with: match.range(at: 2))
      let headerStart = match.range.location + match.range.length
      // Header runs to the body's `{` (or a `;`/end for bodiless protocols
      // in principle — every real declaration this lint targets has a body).
      var headerEnd = headerStart
      while headerEnd < ns.length {
        let ch = ns.character(at: headerEnd)
        if ch == UInt16(UnicodeScalar("{").value) { break }
        headerEnd += 1
      }
      var header = ns.substring(with: NSRange(location: headerStart, length: headerEnd - headerStart))
      header = strippingGenericParameters(header)
      if let whereRange = header.range(of: #"\bwhere\b"#, options: .regularExpression) {
        header = String(header[..<whereRange.lowerBound])
      }
      guard let colon = header.firstIndex(of: ":") else { continue }
      let clause = String(header[header.index(after: colon)...])

      var conformances: [String] = []
      var unchecked = false
      for part in splitTopLevelCommas(clause) {
        let entry = part.trimmingCharacters(in: .whitespacesAndNewlines)
          .replacingOccurrences(of: "\n", with: " ")
        if entry.replacingOccurrences(
          of: #"\s+"#, with: " ", options: .regularExpression
        ).hasPrefix("@unchecked Sendable") {
          unchecked = true
          conformances.append("Sendable")
          continue
        }
        let base = entry.split(separator: "<").first.map(String.init) ?? entry
        if let last = base.split(separator: ".").last {
          let identifier = last.trimmingCharacters(in: .whitespacesAndNewlines)
          if !identifier.isEmpty { conformances.append(identifier) }
        }
      }
      let line = ns.substring(to: match.range.location)
        .reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
      results.append(
        Declaration(
          name: name, line: line, conformances: conformances,
          declaresUncheckedSendable: unchecked))
    }
    return results
  }

  private static func strippingGenericParameters(_ header: String) -> String {
    var out = ""
    var depth = 0
    for ch in header {
      if ch == "<" { depth += 1; continue }
      if ch == ">" { if depth > 0 { depth -= 1 }; continue }
      if depth == 0 { out.append(ch) }
    }
    return out
  }

  private static func splitTopLevelCommas(_ text: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var depth = 0
    for ch in text {
      switch ch {
      case "<", "(", "[": depth += 1; current.append(ch)
      case ">", ")", "]": depth = max(0, depth - 1); current.append(ch)
      case "," where depth == 0:
        parts.append(current)
        current = ""
      default: current.append(ch)
      }
    }
    if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      parts.append(current)
    }
    return parts
  }

  /// The lint over a set of already-read sources. `Working`-implication is
  /// closed transitively over the scanned declarations: a protocol refining
  /// `Working`, a class subclassing a worker, or an extension adding the
  /// conformance all mark the name — that is how the reference repos'
  /// workers actually conform (seam protocols like `LocationWorking`).
  static func workerFindings(files: [(path: String, source: String)]) -> [String] {
    var declarationsByFile: [(path: String, decls: [Declaration])] = []
    var conformances: [String: Set<String>] = [:]
    for (path, source) in files {
      let decls = declarations(inSource: source)
      declarationsByFile.append((path, decls))
      for decl in decls {
        conformances[decl.name, default: []].formUnion(decl.conformances)
      }
    }

    var workingImplying: Set<String> = ["Working"]
    var changed = true
    while changed {
      changed = false
      for (name, bases) in conformances
      where !workingImplying.contains(name) && !bases.isDisjoint(with: workingImplying) {
        workingImplying.insert(name)
        changed = true
      }
    }

    var findings: [String] = []
    for (path, decls) in declarationsByFile {
      for decl in decls
      where decl.declaresUncheckedSendable && workingImplying.contains(decl.name)
        && decl.name != "Working"
      {
        findings.append(
          "[workers] \(path):\(decl.line): '\(decl.name)' conforms to Working and is declared "
            + "'@unchecked Sendable' — the stamp silences the isolation checking the worker "
            + "rule relies on (see docs/workers.md in the duet framework); isolate the worker "
            + "(@MainActor, or prove Sendable) instead")
      }
    }
    return findings.sorted()
  }

  /// Directories never scanned: build products, package checkouts, tool
  /// state. A directory component ending in `Tests` marks test sources —
  /// out of the lint's scope wherever the target puts them (`Tests/`,
  /// `Sources/<Name>Tests/`).
  static let skippedDirs: Set<String> = [
    ".build", ".swiftpm", ".index-build", ".gradle", ".git", "build",
    "DerivedData", "checkouts", "Pods", "node_modules", ".runs", ".duet-family",
  ]

  static func isScannedDirectory(_ name: String) -> Bool {
    !skippedDirs.contains(name) && !name.hasSuffix("Tests")
  }

  // MARK: - I/O wrapper

  static func run(repo: Repo, options: Options) throws -> Int32 {
    let manifest = try Manifest.load(repo: repo)
    let projectJSONURL = repo.root.appendingPathComponent(".modaal/project.json")
    let projectJSON = try? Data(contentsOf: projectJSONURL)
    let geometry = Geometry(
      kotlinShaped: manifest.androidDir != nil,
      fileExists: { relative in
        FileManager.default.fileExists(
          atPath: repo.root.appendingPathComponent(relative).path)
      })
    let declarationRows = declarationFindings(projectJSON: projectJSON, geometry: geometry)

    var sources: [(path: String, source: String)] = []
    if let enumerator = FileManager.default.enumerator(
      at: repo.root, includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles])
    {
      for case let url as URL in enumerator {
        let name = url.lastPathComponent
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
          if !isScannedDirectory(name) { enumerator.skipDescendants() }
          continue
        }
        guard name.hasSuffix(".swift") else { continue }
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
        sources.append((Lanes.relativePath(url, in: repo), source))
      }
    }
    sources.sort { $0.path < $1.path }
    let workerRows = workerFindings(files: sources)

    let findings = declarationRows + workerRows
    let targetsChecked = targetCount(projectJSON: projectJSON)

    if options.json {
      Lanes.emitJSON([
        "status": findings.isEmpty ? "passed" : "failed",
        "findings": findings,
        "targetsChecked": targetsChecked,
        "swiftSourcesScanned": sources.count,
      ])
      return findings.isEmpty ? 0 : 1
    }
    if findings.isEmpty {
      print(
        "duet doctor: PASS — \(targetsChecked) target declaration(s), "
          + "\(sources.count) Swift source file(s) scanned")
      return 0
    }
    print("duet doctor: FAIL")
    for finding in findings { print("  ✗ \(finding)") }
    print("duet doctor: \(findings.count) finding(s)")
    return 1
  }

  private static func targetCount(projectJSON: Data?) -> Int {
    guard let projectJSON,
      let root = try? JSONSerialization.jsonObject(with: projectJSON),
      let metadata = root as? [String: Any],
      let targets = metadata["targets"] as? [String: Any]
    else { return 0 }
    return targets.count
  }
}
