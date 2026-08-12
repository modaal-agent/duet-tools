// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import XCTest

@testable import DuetCLI

/// The manifest grammar (contracts/manifest.md) — pure text-in, structure-out.
/// Tree-level behavior (checks against files on disk) lives in
/// ManifestLintTests; these pin the parser alone.
final class ManifestParserTests: XCTestCase {

  // MARK: - Structure goldens

  func testFeaturesChainsScalarsAndPresentationParse() {
    let parsed = ManifestParser.parse(
      """
      # header comment
      replayRunner: src-ios/Replay

      features:
        greeter:
          swift: src-ios/Sources/GreeterFeature/GreeterFeature.swift  # trailing comment
          state: GreeterState
          fixtures:
            - greeter
            - greeter.reset
        counter:
          kotlin: src-kmp/subtrees/counter/logic/src/commonMain/kotlin/C.kt
          fixtures:
            - counter

      chains:
        - greeter.wave

      presentation:
        waivers:
          - kind: greeter.banner-fade
            feature: greeter
            platform: ios
        islands: []
      """)
    XCTAssertEqual(parsed.featureOrder, ["greeter", "counter"])
    XCTAssertEqual(
      parsed.features["greeter"]?.keys["swift"],
      "src-ios/Sources/GreeterFeature/GreeterFeature.swift")
    XCTAssertEqual(parsed.features["greeter"]?.keys["state"], "GreeterState")
    XCTAssertEqual(parsed.features["greeter"]?.fixtures, ["greeter", "greeter.reset"])
    XCTAssertEqual(parsed.features["counter"]?.fixtures, ["counter"])
    XCTAssertEqual(parsed.chains, ["greeter.wave"])
    XCTAssertEqual(parsed.scalars, ["replayRunner": "src-ios/Replay"])
    XCTAssertEqual(parsed.waivers.count, 1)
    XCTAssertEqual(parsed.waivers.first?["kind"], "greeter.banner-fade")
    XCTAssertEqual(parsed.waivers.first?["platform"], "ios")
    XCTAssertTrue(parsed.islands.isEmpty)
    XCTAssertTrue(parsed.topLevelErrors.isEmpty)
    XCTAssertTrue(parsed.ledgerParseErrors.isEmpty)
  }

  func testUnknownPerFeatureKeysRideThePlanVerbatim() {
    let parsed = ManifestParser.parse(
      """
      features:
        greeter:
          swift: a/Sources/GreeterFeature/G.swift
          futureKey: some value
      """)
    XCTAssertEqual(parsed.features["greeter"]?.keys["futureKey"], "some value")
    XCTAssertTrue(parsed.topLevelErrors.isEmpty)
  }

  func testRedeclaredFeatureResetsToTheLastDeclaration() {
    let parsed = ManifestParser.parse(
      """
      features:
        greeter:
          swift: first/Sources/GreeterFeature/G.swift
          fixtures:
            - one
        greeter:
          kotlin: second/feature-greeter/src/main/kotlin/G.kt
      """)
    XCTAssertEqual(parsed.featureOrder, ["greeter"])
    XCTAssertNil(parsed.features["greeter"]?.keys["swift"])
    XCTAssertEqual(
      parsed.features["greeter"]?.keys["kotlin"], "second/feature-greeter/src/main/kotlin/G.kt")
    XCTAssertTrue(parsed.features["greeter"]?.fixtures.isEmpty ?? false)
  }

  // MARK: - The strict top level

  func testMisspelledSectionIsANamedError() {
    let parsed = ManifestParser.parse(
      """
      features:
        greeter:
          swift: a/Sources/GreeterFeature/G.swift
      chanis:
        - greeter.wave
      """)
    XCTAssertEqual(
      parsed.topLevelErrors,
      ["manifest.yaml: unknown top-level key 'chanis' (known: chains, features, presentation, replayRunner)"])
    // The misdeclared block is NOT silently adopted as chains.
    XCTAssertTrue(parsed.chains.isEmpty)
  }

  func testUnknownTopLevelScalarIsANamedError() {
    let parsed = ManifestParser.parse("raplayRunner: src-ios/Replay\n")
    XCTAssertEqual(
      parsed.topLevelErrors,
      ["manifest.yaml: unknown top-level key 'raplayRunner' (known: chains, features, presentation, replayRunner)"])
    XCTAssertTrue(parsed.scalars.isEmpty)
  }

  func testUnparseableTopLevelLineIsANamedError() {
    let parsed = ManifestParser.parse("stray words\n")
    XCTAssertEqual(
      parsed.topLevelErrors, ["manifest.yaml: unparseable top-level line: 'stray words'"])
  }

  // MARK: - The presentation ledger's parse errors

  func testInlineLedgerValueMustBeAListOrEmpty() {
    let parsed = ManifestParser.parse(
      """
      presentation:
        waivers: junk
      """)
    XCTAssertEqual(
      parsed.ledgerParseErrors,
      ["[presentation] waivers: expected a list of entries or [], got 'junk'"])
  }

  func testLedgerLineOutsideASectionIsAnError() {
    let parsed = ManifestParser.parse(
      """
      presentation:
        - kind: greeter.banner-fade
      """)
    XCTAssertEqual(
      parsed.ledgerParseErrors,
      ["[presentation] line outside waivers:/islands:: '- kind: greeter.banner-fade'"])
  }

  func testUnparseableLedgerEntryLineIsAnError() {
    let parsed = ManifestParser.parse(
      """
      presentation:
        waivers:
          - entry
      """)
    XCTAssertEqual(
      parsed.ledgerParseErrors, ["[presentation] unparseable ledger line: '- entry'"])
  }
}
