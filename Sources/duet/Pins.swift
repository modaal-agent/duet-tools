// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import Foundation

/// `duet pins [<path>] [--latest] [--json]` — the Duet family pins a tree
/// declares, checked against the family's exact-pin rule. SwiftPM
/// version-solves the app and every package it reaches as one graph, and
/// duet-services pins duet `exact:`, so a tree that pins a family package by
/// range, or two pins of one package at two versions, fails to resolve.
///
/// The verb reads files only, unless `--latest` is given; it runs in any tree,
/// a parity repo or not.
enum Pins {

  struct Pin: Equatable {
    /// `duet`, `duet-services`, `duet-macros`, `duet-migration`, `duet-tools`,
    /// `mocks-processor` or `mocks-bundle`.
    let name: String
    /// The version, branch or revision, or `?` when none is written.
    let version: String
    /// `exact`, or the requirement kind that is not exact (`from`, `branch`,
    /// `revision`, `upToNextMajor`, `upToNextMinor`, `range`, `unpinned`).
    let kind: String
    /// `<path relative to the root>[:<line>]`.
    let location: String
  }

  struct Newest: Equatable {
    let repository: String
    let tag: String?
    /// The duet tag the release pins, for duet-services and duet-migration.
    let pinsDuet: String?
  }

  struct Report {
    let root: URL
    let pins: [Pin]
    let findings: [String]
    let newest: [Newest]
  }

  /// The network reads `--latest` makes. Tests pass a stub.
  protocol Remote {
    /// The newest `<prefix>MAJOR.MINOR.PATCH` tag of `modaal-agent/<repository>`.
    func newestTag(repository: String, prefix: String) -> String?
    /// The duet version `modaal-agent/<repository>`'s Package.swift pins at `tag`.
    func pinnedDuet(repository: String, tag: String) -> String?
    /// The newest release of `dev.modaal:mocks-processor` on the family's Maven host.
    func newestMocksProcessor() -> String?
  }

  static let familyRepositories = ["duet", "duet-tools", "duet-services", "duet-macros", "duet-migration"]
  /// The family repositories whose releases pin a duet tag `exact:`.
  static let duetPinners = ["duet-services", "duet-migration"]

  static func run(options: Options, remote: Remote = NetworkRemote()) -> Int32 {
    let start = options.target ?? FileManager.default.currentDirectoryPath
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: start, isDirectory: &isDirectory), isDirectory.boolValue
    else {
      FileHandle.standardError.write(Data("duet pins: \(start) is not a directory\n".utf8))
      return 2
    }
    let startURL = URL(fileURLWithPath: start).standardizedFileURL
    let root = Repo.discover(from: startURL.path)?.root ?? startURL
    let result = report(root: root, latest: options.latest, remote: remote)
    if options.json {
      Lanes.emitJSON(json(result))
    } else {
      print(render(result, latest: options.latest), terminator: "")
    }
    return result.findings.isEmpty ? 0 : 1
  }

  // MARK: - The report

  static func report(root: URL, latest: Bool, remote: Remote) -> Report {
    let pins = read(root: root)
    var findings = localFindings(pins)
    var newest: [Newest] = []
    if latest {
      for repository in duetPinners {
        guard let tag = distinctVersions(pins, repository).first,
          let duet = distinctVersions(pins, "duet").first
        else { continue }
        guard let wanted = remote.pinnedDuet(repository: repository, tag: tag) else {
          findings.append("could not read the duet pin of \(repository) \(tag) (network?)")
          continue
        }
        if wanted != duet {
          findings.append(
            "\(repository) \(tag) pins duet \(wanted); the tree pins duet \(duet) — move both pins together")
        }
      }
      for repository in familyRepositories {
        let tag = remote.newestTag(repository: repository, prefix: "")
        let pinsDuet = tag.flatMap { tag in
          duetPinners.contains(repository) ? remote.pinnedDuet(repository: repository, tag: tag) : nil
        }
        newest.append(Newest(repository: repository, tag: tag, pinsDuet: pinsDuet))
      }
      newest.append(
        Newest(
          repository: "swift-sourcery-templates",
          tag: remote.newestTag(repository: "swift-sourcery-templates", prefix: "templates-"), pinsDuet: nil))
      newest.append(Newest(repository: "mocks-processor", tag: remote.newestMocksProcessor(), pinsDuet: nil))
      for entry in newest where entry.tag == nil {
        findings.append("could not read the newest release of \(entry.repository) (network?)")
      }
    }
    return Report(root: root, pins: pins, findings: findings, newest: newest)
  }

  static func localFindings(_ pins: [Pin]) -> [String] {
    var findings = pins.filter { $0.kind != "exact" }.map {
      "\($0.name) is pinned \($0.kind) \($0.version) at \($0.location) — pin it exact"
    }
    var seen: [String] = []
    for pin in pins where !seen.contains(pin.name) {
      seen.append(pin.name)
      let versions = distinctVersions(pins, pin.name)
      if versions.count > 1 {
        findings.append(
          "\(pin.name) is pinned at \(versions.joined(separator: ", ")) — move every pin of it to one version in the same change"
        )
      }
    }
    return findings
  }

  /// The distinct versions pinned for `name`, in the order they were read.
  static func distinctVersions(_ pins: [Pin], _ name: String) -> [String] {
    var versions: [String] = []
    for pin in pins where pin.name == name && !versions.contains(pin.version) {
      versions.append(pin.version)
    }
    return versions
  }

  static func render(_ report: Report, latest: Bool) -> String {
    var text = "duet pins: \(report.root.path)\n"
    if report.pins.isEmpty {
      text += "  no family pin found\n"
    }
    for pin in report.pins {
      text += "  " + [
        pin.name.padding(toLength: max(16, pin.name.count), withPad: " ", startingAt: 0),
        pin.version.padding(toLength: max(10, pin.version.count), withPad: " ", startingAt: 0),
        pin.kind.padding(toLength: max(9, pin.kind.count), withPad: " ", startingAt: 0),
        pin.location,
      ].joined(separator: " ") + "\n"
    }
    for finding in report.findings {
      text += "  ✗ \(finding)\n"
    }
    if latest {
      text += "  newest releases:\n"
      for entry in report.newest {
        guard let tag = entry.tag else { continue }
        let suffix = entry.pinsDuet.map { " (pins duet \($0))" } ?? ""
        text += "    \(entry.repository) \(tag)\(suffix)\n"
      }
    }
    text +=
      report.findings.isEmpty
      ? "duet pins: OK\n" : "duet pins: \(report.findings.count) disagreement(s)\n"
    return text
  }

  static func json(_ report: Report) -> [String: Any] {
    var object: [String: Any] = [
      "status": report.findings.isEmpty ? "passed" : "failed",
      "root": report.root.path,
      "pins": report.pins.map {
        ["name": $0.name, "version": $0.version, "kind": $0.kind, "location": $0.location]
      },
      "findings": report.findings,
    ]
    if !report.newest.isEmpty {
      object["newest"] = report.newest.map { entry -> [String: Any] in
        var row: [String: Any] = ["repository": entry.repository, "tag": entry.tag ?? NSNull()]
        if let pinsDuet = entry.pinsDuet { row["pinsDuet"] = pinsDuet }
        return row
      }
    }
    return object
  }

  // MARK: - Reading the tree

  /// Directories never read: build output, dependency checkouts and the
  /// family clones `tools/duet` keeps.
  static let prunedDirectories: Set<String> = [
    ".build", ".duet-family", "DerivedData", "checkouts", "build", ".gradle", ".git", "node_modules",
  ]

  static func read(root: URL) -> [Pin] {
    var pins: [Pin] = []
    let files = treeFiles(root: root)
    for file in files where file.lastPathComponent == "Package.swift" {
      pins += swiftManifestPins(text(file), location: relative(file, root))
    }
    for file in files where ["project.yml", "xcodegen.yml"].contains(file.lastPathComponent) {
      pins += xcodegenPins(text(file), location: relative(file, root))
    }
    for file in files where file.lastPathComponent == "libs.versions.toml" {
      pins += catalogPins(text(file), location: relative(file, root))
    }
    let ref = root.appendingPathComponent("parity/duet-tools.ref")
    if let tag = firstValueLine(text(ref)) {
      pins.append(Pin(name: "duet-tools", version: tag, kind: "exact", location: "parity/duet-tools.ref"))
    }
    let manifest = root.appendingPathComponent("parity/manifest.yaml")
    if let bundle = mocksBundle(text(manifest)) {
      pins.append(
        Pin(name: "mocks-bundle", version: bundle, kind: "exact", location: "parity/manifest.yaml (mocks.bundle)"))
    }
    return pins
  }

  static func treeFiles(root: URL) -> [URL] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [])
    else { return [] }
    var files: [URL] = []
    for case let url as URL in enumerator {
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
      if values?.isDirectory == true {
        if prunedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
        continue
      }
      if values?.isRegularFile == true { files.append(url) }
    }
    return files.sorted { $0.path < $1.path }
  }

  static func text(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? ""
  }

  static func relative(_ url: URL, _ root: URL) -> String {
    let path = url.standardizedFileURL.path
    let base = root.standardizedFileURL.path
    return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
  }

  /// `modaal-agent/duet-services.git` → `duet-services`.
  static func familyName(inURL text: String) -> String? {
    guard let match = text.range(of: #"modaal-agent/duet[a-z-]*"#, options: .regularExpression) else {
      return nil
    }
    var name = String(text[match].dropFirst("modaal-agent/".count))
    while name.hasSuffix("-") { name.removeLast() }
    return name
  }

  static func firstCapture(_ pattern: String, in text: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[range])
  }

  /// Each `.package(…)` call whose url names a family repository, read up to
  /// its closing parenthesis, so a call written over several lines is read
  /// whole.
  static func swiftManifestPins(_ source: String, location: String) -> [Pin] {
    var pins: [Pin] = []
    var searchStart = source.startIndex
    while let call = source.range(of: ".package(", range: searchStart..<source.endIndex) {
      var depth = 1
      var index = call.upperBound
      while index < source.endIndex && depth > 0 {
        switch source[index] {
        case "(": depth += 1
        case ")": depth -= 1
        default: break
        }
        index = source.index(after: index)
      }
      let body = String(source[call.upperBound..<index])
      searchStart = index
      guard body.contains("url:"), let name = familyName(inURL: body) else { continue }
      let line = source[..<call.lowerBound].filter { $0 == "\n" }.count + 1
      let (version, kind) = swiftRequirement(body)
      pins.append(Pin(name: name, version: version, kind: kind, location: "\(location):\(line)"))
    }
    return pins
  }

  static func swiftRequirement(_ body: String) -> (String, String) {
    if let exact = firstCapture(#"exact:\s*"([^"]*)""#, in: body)
      ?? firstCapture(#"\.exact\(\s*"([^"]*)""#, in: body)
    {
      return (exact, "exact")
    }
    // `.upToNextMajor(from: "…")` carries a `from:` too, so the named ranges are read first.
    for kind in ["upToNextMajor", "upToNextMinor", "branch", "revision", "from"] {
      if let value = firstCapture(kind + #"[:(]\s*(?:from:\s*)?"([^"]*)""#, in: body) {
        return (value, kind)
      }
    }
    if let lower = firstCapture(#""([^"]*)"\s*\.\.[.<]"#, in: body) {
      return (lower, "range")
    }
    return ("?", "range")
  }

  /// Each package of an XcodeGen spec whose `url:` names a family repository,
  /// with its requirement read from the keys beside the url, before or after
  /// it.
  static func xcodegenPins(_ source: String, location: String) -> [Pin] {
    let lines = source.components(separatedBy: "\n")
    func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
    func isBlank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }
    var pins: [Pin] = []
    for (number, line) in lines.enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("url:"), let name = familyName(inURL: trimmed) else { continue }
      let level = indent(line)
      var siblings: [String] = []
      var above = number - 1
      while above >= 0, isBlank(lines[above]) || indent(lines[above]) >= level {
        if !isBlank(lines[above]) && indent(lines[above]) == level { siblings.append(lines[above]) }
        above -= 1
      }
      var below = number + 1
      while below < lines.count, isBlank(lines[below]) || indent(lines[below]) >= level {
        if !isBlank(lines[below]) && indent(lines[below]) == level { siblings.append(lines[below]) }
        below += 1
      }
      var pin = Pin(name: name, version: "?", kind: "unpinned", location: "\(location):\(number + 1)")
      for field in ["exactVersion", "version", "from", "minorVersion", "majorVersion", "branch", "revision"] {
        guard
          let sibling = siblings.first(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(field + ":")
          })
        else { continue }
        var value = sibling.trimmingCharacters(in: .whitespaces).dropFirst(field.count + 1)
          .trimmingCharacters(in: .whitespaces)
        if let comment = value.range(of: " #") { value = String(value[..<comment.lowerBound]) }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        let kind = (field == "exactVersion" || field == "version") ? "exact" : field
        pin = Pin(name: name, version: value, kind: kind, location: pin.location)
        break
      }
      pins.append(pin)
    }
    return pins
  }

  /// The `duet`, `duetServices` and `mocksProcessor` keys of a Gradle version
  /// catalog. A catalog version is one version, so each is exact.
  static func catalogPins(_ source: String, location: String) -> [Pin] {
    let keys = [("duet", "duet"), ("duetServices", "duet-services"), ("mocksProcessor", "mocks-processor")]
    var pins: [Pin] = []
    for (key, name) in keys {
      guard let value = firstCapture(#"(?m)^"# + key + #"\s*=\s*"?([^"\s#]*)"?"#, in: source), !value.isEmpty
      else { continue }
      pins.append(Pin(name: name, version: value, kind: "exact", location: location))
    }
    return pins
  }

  /// The first line that is neither blank nor a comment, trimmed.
  static func firstValueLine(_ source: String) -> String? {
    source.components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty && !$0.hasPrefix("#") }
  }

  /// The manifest's `mocks: bundle:` value.
  static func mocksBundle(_ source: String) -> String? {
    guard var value = firstCapture(#"(?m)^[ \t]+bundle:[ \t]*(.*)$"#, in: source) else { return nil }
    if let comment = value.range(of: "#") { value = String(value[..<comment.lowerBound]) }
    value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
    return value.isEmpty ? nil : value
  }

  // MARK: - The network

  struct NetworkRemote: Remote {
    func newestTag(repository: String, prefix: String) -> String? {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = [
        "git", "ls-remote", "--tags", "--refs", "https://github.com/modaal-agent/\(repository).git",
      ]
      var environment = ProcessInfo.processInfo.environment
      environment["GIT_TERMINAL_PROMPT"] = "0"
      process.environment = environment
      let output = Pipe()
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      process.standardInput = FileHandle.nullDevice
      guard (try? process.run()) != nil else { return nil }
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
      return Pins.newestSemver(inLsRemote: text, prefix: prefix)
    }

    func pinnedDuet(repository: String, tag: String) -> String? {
      guard
        let data = get("https://raw.githubusercontent.com/modaal-agent/\(repository)/\(tag)/Package.swift"),
        let text = String(data: data, encoding: .utf8)
      else { return nil }
      return Pins.swiftManifestPins(text, location: "Package.swift")
        .first { $0.name == "duet" && $0.kind == "exact" }?.version
    }

    func newestMocksProcessor() -> String? {
      guard
        let data = get("https://modaal-agent.github.io/maven/dev/modaal/mocks-processor/maven-metadata.xml"),
        let text = String(data: data, encoding: .utf8)
      else { return nil }
      return Pins.firstCapture(#"<release>([^<]*)</release>"#, in: text)
    }

    /// The body of a 200 response, or nil.
    func get(_ address: String) -> Data? {
      guard let url = URL(string: address) else { return nil }
      let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
      let done = DispatchSemaphore(value: 0)
      let box = ResponseBox()
      URLSession.shared.dataTask(with: request) { data, response, _ in
        if (response as? HTTPURLResponse)?.statusCode == 200 { box.data = data }
        done.signal()
      }.resume()
      done.wait()
      return box.data
    }
  }

  final class ResponseBox: @unchecked Sendable {
    var data: Data?
  }

  /// The newest `<prefix>MAJOR.MINOR.PATCH` tag in `git ls-remote --tags --refs` output.
  static func newestSemver(inLsRemote output: String, prefix: String) -> String? {
    let versions = output.components(separatedBy: "\n").compactMap { line -> [Int]? in
      guard let range = line.range(of: "refs/tags/" + prefix) else { return nil }
      let parts = line[range.upperBound...].split(separator: ".", omittingEmptySubsequences: false)
      let numbers = parts.compactMap { Int($0) }
      return parts.count == 3 && numbers.count == 3 ? numbers : nil
    }
    guard let newest = versions.max(by: { $0.lexicographicallyPrecedes($1) }) else { return nil }
    return newest.map(String.init).joined(separator: ".")
  }
}
