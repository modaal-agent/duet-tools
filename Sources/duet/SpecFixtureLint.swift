// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import Foundation

/// The spec↔fixture cross-reference meta-check (graduated from the adopter
/// repos' parity/scripts/spec-fixture-lint.py). Feature one-pagers are prose
/// beside a byte gate: the fixtures win any disagreement, but a spec that
/// names the WRONG fixture, or claims participation in a chain that doesn't
/// include its feature, is drift the byte gate can't see. The checks,
/// verbatim from the graduated lint:
///
///   - every manifest feature has a one-pager: parity/feature-specs/<name>.md
///     (the convention IS the contract — the CLI has no config surface, so a
///     historically-named spec file renames at adoption)
///   - every manifest-declared leaf fixture is mentioned in its feature's
///     spec in BACKTICKED form: the full id (`priming.enable`), or the
///     scenario-family shorthand — a `family.*` glob plus each remaining
///     dot-segment as a `.slug` token
///   - every backticked `chain-*` token names a chain fixture that exists
///     (unbackticked "chain-…" prose is not a reference and is ignored)
///   - every chain fixture is mentioned in EVERY participating feature's
///     spec (participants = the chain fixture's initialStates keys)
///
/// Applies only when parity/feature-specs/ exists — the directory is the
/// adopter's opt-in to the prose discipline (both shipped templates carry it).
enum SpecFixtureLint {
  /// nil when the repo has no parity/feature-specs directory (the check does
  /// not apply); otherwise the violations (empty = pass).
  static func check(repo: Repo, manifest: Manifest) -> [String]? {
    let specsDir = repo.root.appendingPathComponent("parity/feature-specs")
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: specsDir.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return nil }

    var errors: [String] = []

    // Chain participants from the fixture documents themselves (a directory
    // glob, not the manifest list — an orphan chain file still gets its
    // participation check, exactly as the graduated lint did).
    var chainParticipants: [String: [String]] = [:]
    for file in
      (try? FileManager.default.contentsOfDirectory(atPath: repo.fixturesDir.path)) ?? []
    where file.hasPrefix("chain-") && file.hasSuffix(".fixture.json") {
      let name = String(file.dropLast(".fixture.json".count))
      guard
        let data = try? Data(contentsOf: repo.fixturesDir.appendingPathComponent(file)),
        let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let initialStates = document["initialStates"] as? [String: Any]
      else {
        errors.append("\(name): unreadable chain fixture (no initialStates)")
        continue
      }
      chainParticipants[name] = initialStates.keys.sorted()
    }

    var specTexts: [String: String] = [:]
    for feature in manifest.features {
      let url = specsDir.appendingPathComponent("\(feature.name).md")
      guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        errors.append(
          "\(feature.name): no one-pager (\(feature.name).md missing in parity/feature-specs)")
        continue
      }
      specTexts[feature.name] = text
    }

    // Leaf fixtures: declared in the manifest ⇒ mentioned in the feature's spec.
    for feature in manifest.features {
      guard let text = specTexts[feature.name] else { continue }
      let tokens = backtickedTokens(in: text, pattern: "`([\\w.\\-*]+)`")
      let globs = Set(tokens.filter { $0.hasSuffix(".*") }.map { String($0.dropLast(2)) })
      for fixture in feature.fixtures {
        if tokens.contains(fixture) { continue }
        if let family = globs.first(where: { fixture.hasPrefix($0 + ".") }) {
          let slugs = fixture.dropFirst(family.count + 1).split(separator: ".")
          if slugs.allSatisfy({ tokens.contains("." + String($0)) }) { continue }
        }
        errors.append(
          "\(feature.name).md: manifest fixture '\(fixture)' never mentioned "
            + "(backticked id, or family glob + `.slug` tokens)")
      }
    }

    // Backticked chain references must exist as chain fixtures.
    for (feature, text) in specTexts.sorted(by: { $0.key < $1.key }) {
      let refs = backtickedTokens(in: text, pattern: "`(chain-[\\w.\\-]+)`")
      for token in refs.sorted() where chainParticipants[token] == nil {
        errors.append("\(feature).md: references nonexistent chain '\(token)'")
      }
    }

    // Chain participation: every participant's spec mentions the chain (any form).
    for (chain, participants) in chainParticipants.sorted(by: { $0.key < $1.key }) {
      for participant in participants {
        guard let text = specTexts[participant] else {
          errors.append("\(chain): participant '\(participant)' has no spec")
          continue
        }
        if !text.contains(chain) {
          errors.append("\(chain): participant spec \(participant).md never mentions it")
        }
      }
    }
    return errors
  }

  private static func backtickedTokens(in text: String, pattern: String) -> Set<String> {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    var tokens: Set<String> = []
    regex.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) {
      match, _, _ in
      if let match, match.numberOfRanges > 1,
        let range = Range(match.range(at: 1), in: text)
      {
        tokens.insert(String(text[range]))
      }
    }
    return tokens
  }
}
