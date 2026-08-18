// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import Foundation

/// The parsed parity manifest — the CLI's own reader of `parity/manifest.yaml`.
/// The grammar is the manifest's fixed shape (contracts/manifest.md), hand-rolled
/// on purpose: the family's zero-third-party-dependency rule holds, and a full
/// YAML engine would accept far more than the contract allows.
///
/// Unknown TOP-LEVEL keys are a named error: the manifest's top level routes
/// whole blocks, so a typo'd section header (a misspelled `chains:`) would
/// otherwise drop its entire block silently — a misdeclared chain is a fixture
/// nobody gates. Unknown PER-FEATURE keys are accepted and carried into the
/// plan verbatim: feature entries are extensible, and the checks read only the
/// keys they know.
struct ParsedManifest {
  struct FeatureEntry {
    var keys: [String: String] = [:]
    var fixtures: [String] = []
  }

  /// Feature declaration order (the manifest's own order — check output follows it).
  var featureOrder: [String] = []
  var features: [String: FeatureEntry] = [:]
  var chains: [String] = []
  var waivers: [[String: String]] = []
  var islands: [[String: String]] = []
  /// Known top-level scalars (`replayRunner:` today) — ride the plan verbatim.
  var scalars: [String: String] = [:]
  /// One `mocks:` generator row — the config `duet mocks` runs (grammar in
  /// contracts/manifest.md). Rows keep manifest order; generation follows it.
  struct MockGenerator {
    var name: String
    /// Row scalars (`output`, `template`, `package`; unknown keys carried —
    /// rows are extensible the same way feature entries are).
    var keys: [String: String] = [:]
    /// Explicit repo-relative scan roots, in declaration order.
    var sources: [String] = []
    /// Template args, `key=value` (`import=…`, `testable=…`).
    var args: [String] = []
  }
  /// `mocks:` section scalars (`bundle:` — the swift-sourcery-templates
  /// release tag the rows generate with).
  var mocksScalars: [String: String] = [:]
  var mockGenerators: [MockGenerator] = []
  /// Whether a `mocks:` section appeared at all. An empty section is legal —
  /// the wired-but-no-rows state a fresh scaffold starts in.
  var hasMocksSection = false
  /// `mocks:` block parse errors (shape errors found while reading it).
  var mocksParseErrors: [String] = []
  /// Strict top-level grammar errors (unknown key, unparseable line).
  var topLevelErrors: [String] = []
  /// `presentation:` block parse errors (shape errors found while reading it).
  var ledgerParseErrors: [String] = []

  func feature(named name: String) -> FeatureEntry? { features[name] }
}

enum ManifestParser {
  /// The top-level routing set. Everything else at indent 0 is an error —
  /// safe under the pin regime (the CLI version is pinned per repo, so a
  /// manifest never meets an older parser that doesn't know its keys).
  static let knownSections: Set<String> = ["features", "chains", "presentation", "mocks"]
  static let knownScalars: Set<String> = ["replayRunner"]

  static func parse(_ text: String) -> ParsedManifest {
    var parsed = ParsedManifest()
    let lines = splitLines(text)
    parseStructure(lines, into: &parsed)
    parsePresentation(lines, into: &parsed)
    parseMocks(lines, into: &parsed)
    return parsed
  }

  // MARK: - Line plumbing

  /// (indent, content) with the comment stripped at the first `#` and trailing
  /// whitespace removed; nil for blank/comment-only lines. `raw` keeps the
  /// original line for error rendering.
  private struct Line {
    let indent: Int
    let content: String
    let raw: String
  }

  private static func splitLines(_ text: String) -> [Line] {
    text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
      var raw = String(rawLine)
      if raw.hasSuffix("\r") { raw = String(raw.dropLast()) }
      let uncommented = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        .first.map(String.init) ?? ""
      let code = String(uncommented.reversed().drop(while: \.isWhitespace).reversed())
      let stripped = code.drop(while: \.isWhitespace)
      guard !stripped.isEmpty else { return nil }
      return Line(indent: code.count - stripped.count, content: String(stripped), raw: raw)
    }
  }

  // MARK: - Pass 1: features / chains / scalars + the strict top level

  private static func parseStructure(_ lines: [Line], into parsed: inout ParsedManifest) {
    var section: String?
    var currentFeature: String?
    var inFixtures = false
    let knownList = (knownSections.union(knownScalars)).sorted().joined(separator: ", ")
    for line in lines {
      let s = line.content
      if line.indent == 0 {
        currentFeature = nil
        inFixtures = false
        if s.hasSuffix(":") {
          let name = String(s.dropLast())
          section = name
          if !knownSections.contains(name) {
            parsed.topLevelErrors.append(
              "manifest.yaml: unknown top-level key '\(name)' (known: \(knownList))")
          }
          continue
        }
        section = nil
        if let colon = s.firstIndex(of: ":") {
          let key = String(s[..<colon]).trimmingCharacters(in: .whitespaces)
          let value = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
          if knownScalars.contains(key) {
            parsed.scalars[key] = value
          } else {
            parsed.topLevelErrors.append(
              "manifest.yaml: unknown top-level key '\(key)' (known: \(knownList))")
          }
        } else {
          parsed.topLevelErrors.append("manifest.yaml: unparseable top-level line: '\(s)'")
        }
        continue
      }
      if section == "chains", line.indent == 2, s.hasPrefix("- ") {
        parsed.chains.append(String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        continue
      }
      guard section == "features" else { continue }  // presentation: has its own pass
      if line.indent == 2, s.hasSuffix(":") {
        let name = String(s.dropLast())
        if parsed.features[name] == nil { parsed.featureOrder.append(name) }
        parsed.features[name] = ParsedManifest.FeatureEntry()
        currentFeature = name
        inFixtures = false
      } else if let feature = currentFeature, line.indent == 4, s == "fixtures:" {
        inFixtures = true
        _ = feature
      } else if let feature = currentFeature, line.indent >= 6, s.hasPrefix("- "), inFixtures {
        parsed.features[feature]?.fixtures.append(
          String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces))
      } else if let feature = currentFeature, line.indent == 4, let colon = s.firstIndex(of: ":") {
        let key = String(s[..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        parsed.features[feature]?.keys[key] = value
        inFixtures = false
      }
    }
  }

  // MARK: - Pass 2: the presentation ledger

  private static func parsePresentation(_ lines: [Line], into parsed: inout ParsedManifest) {
    var inPresentation = false
    var section: String?
    // The entry under construction lives in parsed.waivers/islands at this index.
    var entryIndex: Int?
    func appendKey(_ key: String, _ value: String, to section: String, at index: Int) {
      if section == "waivers" {
        parsed.waivers[index][key] = value
      } else {
        parsed.islands[index][key] = value
      }
    }
    for line in lines {
      var s = line.content
      var indent = line.indent
      if indent == 0 {
        inPresentation = s == "presentation:"
        section = nil
        entryIndex = nil
        continue
      }
      guard inPresentation else { continue }
      if indent == 2, ["waivers", "islands"].contains(String(s.prefix(while: { $0 != ":" }))) {
        let key = String(s.prefix(while: { $0 != ":" }))
        let rest = s.dropFirst(key.count).hasPrefix(":")
          ? String(s.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces) : ""
        section = key
        entryIndex = nil
        if !rest.isEmpty, rest != "[]" {
          parsed.ledgerParseErrors.append(
            "[presentation] \(key): expected a list of entries or [], got \(pythonRepr(rest))")
        }
        continue
      }
      guard let activeSection = section else {
        parsed.ledgerParseErrors.append(
          "[presentation] line outside waivers:/islands:: \(pythonRepr(s))")
        continue
      }
      if indent == 4, s.hasPrefix("- ") {
        if activeSection == "waivers" {
          parsed.waivers.append([:])
          entryIndex = parsed.waivers.count - 1
        } else {
          parsed.islands.append([:])
          entryIndex = parsed.islands.count - 1
        }
        s = String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        indent = 6
      }
      if indent == 6, let index = entryIndex, let colon = s.firstIndex(of: ":") {
        let key = String(s[..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        appendKey(key, value, to: activeSection, at: index)
      } else {
        parsed.ledgerParseErrors.append(
          "[presentation] unparseable ledger line: \(pythonRepr(line.raw.trimmingCharacters(in: .whitespaces)))")
      }
    }
  }

  // MARK: - Pass 3: the mocks section

  private static func parseMocks(_ lines: [Line], into parsed: inout ParsedManifest) {
    var inMocks = false
    var inGenerators = false
    var currentIndex: Int?
    var listKey: String?
    for line in lines {
      let s = line.content
      if line.indent == 0 {
        inMocks = s == "mocks:"
        if inMocks { parsed.hasMocksSection = true }
        inGenerators = false
        currentIndex = nil
        listKey = nil
        continue
      }
      guard inMocks else { continue }
      if line.indent == 2 {
        currentIndex = nil
        listKey = nil
        if s == "generators:" {
          inGenerators = true
          continue
        }
        inGenerators = false
        if let colon = s.firstIndex(of: ":") {
          let key = String(s[..<colon]).trimmingCharacters(in: .whitespaces)
          let value = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
          parsed.mocksScalars[key] = value
        } else {
          parsed.mocksParseErrors.append("[mocks] unparseable line: \(pythonRepr(s))")
        }
        continue
      }
      guard inGenerators else {
        parsed.mocksParseErrors.append("[mocks] line outside generators:: \(pythonRepr(s))")
        continue
      }
      if line.indent == 4, s.hasSuffix(":") {
        parsed.mockGenerators.append(
          ParsedManifest.MockGenerator(name: String(s.dropLast())))
        currentIndex = parsed.mockGenerators.count - 1
        listKey = nil
        continue
      }
      guard let index = currentIndex else {
        parsed.mocksParseErrors.append(
          "[mocks] line outside a generator row: \(pythonRepr(s))")
        continue
      }
      if line.indent == 6 {
        if s == "sources:" || s == "args:" {
          listKey = String(s.dropLast())
          continue
        }
        listKey = nil
        if let colon = s.firstIndex(of: ":") {
          let key = String(s[..<colon]).trimmingCharacters(in: .whitespaces)
          let value = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
          parsed.mockGenerators[index].keys[key] = value
        } else {
          parsed.mocksParseErrors.append(
            "[mocks.\(parsed.mockGenerators[index].name)] unparseable line: \(pythonRepr(s))")
        }
        continue
      }
      if line.indent >= 8, s.hasPrefix("- "), let key = listKey {
        let item = String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        if key == "sources" {
          parsed.mockGenerators[index].sources.append(item)
        } else {
          parsed.mockGenerators[index].args.append(item)
        }
        continue
      }
      parsed.mocksParseErrors.append(
        "[mocks] unparseable line: \(pythonRepr(line.raw.trimmingCharacters(in: .whitespaces)))")
    }
  }

  /// python's `repr()` for the strings these messages embed — the error shapes
  /// predate this parser and are quoted in receipts, so the rendering matches.
  static func pythonRepr(_ value: String) -> String {
    value.contains("'") && !value.contains("\"") ? "\"\(value)\"" : "'\(value)'"
  }
}
