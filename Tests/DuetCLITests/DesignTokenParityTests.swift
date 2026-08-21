// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import XCTest

@testable import DuetCLI

/// The two emitters, read against each other.
///
/// `DesignTokensTests` pins each generated file to a golden, which catches a
/// change to either emitter. This suite asserts the property the goldens are
/// meant to hold: for every token in the config, the Swift table and the Kotlin
/// table carry the same value in the same appearance. The comparison runs on
/// the GENERATED TEXT of both languages rather than on the config model, so an
/// emitter that drops an appearance, rounds an alpha differently, or emits a
/// stop list in the wrong order fails here even when both goldens are updated
/// to match it.
final class DesignTokenParityTests: XCTestCase {

  // MARK: - Harness

  private func resource(_ path: String) throws -> URL {
    let base = try XCTUnwrap(Bundle.module.resourceURL)
    let candidates = [
      base.appendingPathComponent("Resources/\(path)"),
      base.appendingPathComponent(path),
    ]
    return try XCTUnwrap(
      candidates.first { FileManager.default.fileExists(atPath: $0.path) },
      "missing resource \(path) under \(base.path)")
  }

  private func goldenConfig() throws -> DesignTokenConfig {
    let text = try String(contentsOf: try resource("tokens/design-tokens.yaml"), encoding: .utf8)
    return try DesignTokenConfig.parse(text, path: DesignTokenConfig.relativePath)
  }

  private func generated(_ suffix: String, from files: [GeneratedDesignTokenFile]) throws -> String {
    try XCTUnwrap(files.first { $0.path.hasSuffix(suffix) }, "no generated file ending \(suffix)")
      .content
  }

  /// The slice of a generated file between two literal markers — one table,
  /// so a token name shared by two vocabularies cannot be read from the wrong
  /// one.
  private func slice(_ content: String, from opener: String, to closer: String?) throws -> String {
    let start = try XCTUnwrap(content.range(of: opener), "no '\(opener)' in the generated file")
    let rest = content[start.upperBound...]
    guard let closer, let end = rest.range(of: closer) else { return String(rest) }
    return String(rest[..<end.lowerBound])
  }

  /// Each entry's body, keyed by token name: the text from its opening marker
  /// to the next entry's, in declaration order.
  private func entries(_ table: String, opener: (String) -> String, names: [String]) throws
    -> [String: String]
  {
    var ranges: [(String, Range<String.Index>)] = []
    var cursor = table.startIndex
    for name in names {
      let marker = opener(name)
      let found = try XCTUnwrap(table.range(of: marker, range: cursor..<table.endIndex),
                                "no entry '\(marker)'")
      ranges.append((name, found))
      cursor = found.upperBound
    }
    var out: [String: String] = [:]
    for (index, entry) in ranges.enumerated() {
      let end = index + 1 < ranges.count ? ranges[index + 1].1.lowerBound : table.endIndex
      out[entry.0] = String(table[entry.1.upperBound..<end])
    }
    return out
  }

  /// One token's value, in the one form both languages have to agree on: the
  /// ARGB stops it takes in each appearance. A colour is a one-stop gradient
  /// for this purpose.
  private struct Resolved: Equatable {
    var light: [UInt32]
    var dark: [UInt32]
  }

  private func matches(_ pattern: String, in text: String) throws -> [[String?]] {
    let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
      (0..<match.numberOfRanges).map { index in
        Range(match.range(at: index), in: text).map { String(text[$0]) }
      }
    }
  }

  /// `tokenColor(0xRRGGBB)` / `tokenColor(0xRRGGBB, alpha: 0.24)` → ARGB, in
  /// source order. The alpha fraction becomes the byte the same way the Kotlin
  /// table stores it, which is the conversion under test.
  private func swiftStops(_ text: String) throws -> [UInt32] {
    try matches(#"tokenColor\(0x([0-9A-F]{6})(?:, alpha: (-?[0-9.]+))?\)"#, in: text).map { groups in
      let rgb = UInt32(groups[1]!, radix: 16)!
      let alpha = groups[2].flatMap(Double.init) ?? 1
      return (UInt32((alpha * 255).rounded()) << 24) | rgb
    }
  }

  private func kotlinStops(_ text: String) throws -> [UInt32] {
    try matches(#"0x([0-9A-F]{8})"#, in: text).map { UInt32($0[1]!, radix: 16)! }
  }

  // MARK: - Vocabularies

  /// The three case lists, both languages, in declaration order. The pin the
  /// mirror design needs: one config in, one vocabulary out, twice.
  func testEveryVocabularyIsTheSameCaseListInBothLanguages() throws {
    let config = try goldenConfig()
    let files = DesignTokensEmitter.emit(config: config)
    func swiftCases(_ file: String) throws -> [String] {
      try matches(#"(?m)^  case (\w+)$"#, in: try generated(file, from: files)).map { $0[1]! }
    }
    func kotlinCases(_ file: String) throws -> [String] {
      try matches(#"(?m)^  (\w+),$"#, in: try generated(file, from: files)).map { $0[1]! }
    }
    let colors = config.colorTokens.map(\.name)
    XCTAssertEqual(try swiftCases("Generated/SemanticColor.swift"), colors)
    XCTAssertEqual(try kotlinCases("Generated/SemanticColor.kt"), colors)

    let fonts = config.fontTokens.map(\.name)
    XCTAssertEqual(try swiftCases("Generated/SemanticFont.swift"), fonts)
    XCTAssertEqual(try kotlinCases("Generated/SemanticFont.kt"), fonts)

    let gradients = config.gradients.map(\.name)
    XCTAssertEqual(try swiftCases("Generated/SemanticGradient.swift"), gradients)
    XCTAssertEqual(try kotlinCases("Generated/SemanticGradient.kt"), gradients)
  }

  // MARK: - Values

  /// Every colour resolves to the same ARGB in both languages, in both
  /// appearances — the one-value form included, which each language spells its
  /// own way (`ColorSet(.static(…))`, `ColorToken.fixed(…)`) and both have to
  /// answer identically for light and dark.
  func testEveryColourCarriesTheSameValueInBothLanguagesAndBothAppearances() throws {
    let config = try goldenConfig()
    let files = DesignTokensEmitter.emit(config: config)
    let names = config.colorTokens.map(\.name)

    let swiftTable = try slice(try generated("Generated/MainThemePalette.swift", from: files),
                               from: "func colorSet(for asset: _ColorAsset) -> ColorSet {",
                               to: "public struct FontToken {")
    let kotlinTable = try slice(try generated("Generated/MainPalette.kt", from: files),
                                from: "fun color(token: SemanticColor): ColorToken =",
                                to: "fun font(token: SemanticFont): FontToken =")
    let swiftEntries = try entries(swiftTable, opener: { "case .\($0):" }, names: names)
    let kotlinEntries = try entries(kotlinTable, opener: { "SemanticColor.\($0) ->" }, names: names)

    for name in names {
      let swiftBody = try XCTUnwrap(swiftEntries[name])
      let kotlinBody = try XCTUnwrap(kotlinEntries[name])
      let swiftValues = try swiftStops(swiftBody)
      let kotlinValues = try kotlinStops(kotlinBody)
      let swiftResolved = swiftBody.contains(".auto(")
        ? Resolved(light: [swiftValues[0]], dark: [swiftValues[1]])
        : Resolved(light: [swiftValues[0]], dark: [swiftValues[0]])
      let kotlinResolved = kotlinBody.contains(".auto(")
        ? Resolved(light: [kotlinValues[0]], dark: [kotlinValues[1]])
        : Resolved(light: [kotlinValues[0]], dark: [kotlinValues[0]])
      XCTAssertEqual(swiftResolved, kotlinResolved, "colour '\(name)' differs between languages")
    }
  }

  /// Every gradient carries the same stops, in paint order, in both languages
  /// and both appearances.
  func testEveryGradientCarriesTheSameStopsInBothLanguagesAndBothAppearances() throws {
    let config = try goldenConfig()
    XCTAssertFalse(config.gradients.isEmpty, "the golden config declares gradients")
    let files = DesignTokensEmitter.emit(config: config)
    let names = config.gradients.map(\.name)

    let swiftTable = try slice(try generated("Generated/MainThemePalette.swift", from: files),
                               from: "func gradientSet(for asset: _GradientAsset) -> GradientSet {",
                               to: "private func tokenColor(")
    let kotlinTable = try slice(try generated("Generated/MainPalette.kt", from: files),
                                from: "fun gradient(token: SemanticGradient): GradientToken =",
                                to: nil)
    let swiftEntries = try entries(swiftTable, opener: { "case .\($0):" }, names: names)
    let kotlinEntries = try entries(kotlinTable, opener: { "SemanticGradient.\($0) ->" }, names: names)

    for name in names {
      let swiftBody = try XCTUnwrap(swiftEntries[name])
      let kotlinBody = try XCTUnwrap(kotlinEntries[name])
      let swiftResolved: Resolved
      if swiftBody.contains(".auto(") {
        let light = try slice(swiftBody, from: "light: Gradient", to: "dark: Gradient")
        let dark = try slice(swiftBody, from: "dark: Gradient", to: nil)
        swiftResolved = Resolved(light: try swiftStops(light), dark: try swiftStops(dark))
      } else {
        let stops = try swiftStops(swiftBody)
        swiftResolved = Resolved(light: stops, dark: stops)
      }
      let kotlinResolved: Resolved
      if kotlinBody.contains(".auto(") {
        let light = try slice(kotlinBody, from: "light = listOf(", to: "dark = listOf(")
        let dark = try slice(kotlinBody, from: "dark = listOf(", to: nil)
        kotlinResolved = Resolved(light: try kotlinStops(light), dark: try kotlinStops(dark))
      } else {
        let stops = try kotlinStops(kotlinBody)
        kotlinResolved = Resolved(light: stops, dark: stops)
      }
      XCTAssertEqual(swiftResolved.light.count, swiftResolved.dark.count,
                     "gradient '\(name)': the two appearances run different stop counts")
      XCTAssertEqual(swiftResolved, kotlinResolved, "gradient '\(name)' differs between languages")
    }
  }

  /// Every typography column both languages express carries the same number.
  /// `textStyle` is the one column with no Kotlin twin — Dynamic Type is an
  /// Apple mechanism — so it is asserted present on the Swift side and absent
  /// from the Kotlin side rather than compared.
  func testEveryFontCarriesTheSameMetricsInBothLanguages() throws {
    let config = try goldenConfig()
    let files = DesignTokensEmitter.emit(config: config)
    let names = config.fontTokens.map(\.name)

    let swiftTable = try slice(try generated("Generated/MainThemePalette.swift", from: files),
                               from: "func fontToken(for asset: _FontAsset) -> FontToken {",
                               to: "func gradientSet(")
    let kotlinTable = try slice(try generated("Generated/MainPalette.kt", from: files),
                                from: "fun font(token: SemanticFont): FontToken =",
                                to: "fun gradient(token: SemanticGradient): GradientToken =")
    let swiftEntries = try entries(swiftTable, opener: { "case .\($0):" }, names: names)
    let kotlinEntries = try entries(kotlinTable, opener: { "SemanticFont.\($0) ->" }, names: names)

    /// `nil` reads back as the absent value each language spells its own way.
    func number(_ body: String, _ pattern: String) throws -> Double? {
      guard let match = try matches(pattern, in: body).first else { return nil }
      guard let text = match[1], text != "nil", text != "null" else { return nil }
      return Double(text)
    }

    for name in names {
      let swiftBody = try XCTUnwrap(swiftEntries[name])
      let kotlinBody = try XCTUnwrap(kotlinEntries[name])

      let swiftFamily = try XCTUnwrap(try matches(#"family: \.(\w+),"#, in: swiftBody).first?[1])
      let kotlinFamily = try XCTUnwrap(
        try matches(#"family = FontFamilyToken\.(\w+),"#, in: kotlinBody).first?[1])
      XCTAssertEqual(swiftFamily, kotlinFamily.lowercased(), "font '\(name)': family")

      let columns: [(String, String, String)] = [
        ("weight", #"weight: (-?[0-9.]+),"#, #"weight = (-?[0-9.]+),"#),
        ("size", #"size: (-?[0-9.]+),"#, #"sizeSp = (-?[0-9.]+),"#),
        ("lineHeight", #"lineHeight: (-?[0-9.]+),"#, #"lineHeightSp = (-?[0-9.]+),"#),
        ("trackingEm", #"trackingEm: (-?[0-9.]+),"#, #"trackingEm = (-?[0-9.]+),"#),
        ("opticalSize", #"opticalSize: (\S+),"#, #"opticalSize = (\S+),"#),
        ("softness", #"softness: (\S+),"#, #"softness = (\S+),"#),
        ("width", #"width: (\S+),"#, #"width = (\S+),"#),
      ]
      for (column, swiftPattern, kotlinPattern) in columns {
        XCTAssertEqual(try number(swiftBody, swiftPattern), try number(kotlinBody, kotlinPattern),
                       "font '\(name)': \(column)")
      }

      XCTAssertTrue(swiftBody.contains("textStyle: ."), "font '\(name)': no Dynamic Type style")
      XCTAssertFalse(kotlinBody.contains("textStyle"),
                     "font '\(name)': textStyle has no Kotlin twin")
    }
  }

  /// The engine types each generated table names. A palette that imports a
  /// type it does not use, or uses one it does not import, fails its language's
  /// compile — this is the cheap half of that, run without a toolchain.
  func testTheKotlinPaletteImportsExactlyTheEngineTypesItNames() throws {
    let config = try goldenConfig()
    let palette = try generated("Generated/MainPalette.kt",
                                from: DesignTokensEmitter.emit(config: config))
    let imported = Set(try matches(#"(?m)^import [\w.]+\.(\w+)$"#, in: palette).map { $0[1]! })
    XCTAssertEqual(imported, ["ColorToken", "FontFamilyToken", "FontToken", "GradientToken"])
    // Below the import block, so a name is counted where it is USED.
    let body = try slice(palette, from: "object MainPalette {", to: nil)
    for type in imported {
      XCTAssertTrue(body.contains(type), "\(type) is imported and never named")
    }
  }

  /// A config with no gradients generates no gradient vocabulary, no gradient
  /// table, and no gradient import — in either language. The two vocabulary
  /// paths stay OWNED, which is what turns a file left over from a config that
  /// dropped its gradients into a reported orphan rather than a source file
  /// that keeps compiling against a vocabulary nothing generates.
  func testAConfigWithNoGradientsEmitsNoGradientSurfaceInEitherLanguage() throws {
    var config = try goldenConfig()
    config.gradients = []
    let files = DesignTokensEmitter.emit(config: config)
    XCTAssertEqual(files.count, 6, "three files per declared language")
    XCTAssertFalse(files.contains { $0.path.contains("SemanticGradient") })
    let swiftPalette = try generated("Generated/MainThemePalette.swift", from: files)
    XCTAssertFalse(swiftPalette.contains("gradientSet"))
    XCTAssertFalse(swiftPalette.contains("import SwiftUI"))
    let kotlinPalette = try generated("Generated/MainPalette.kt", from: files)
    XCTAssertFalse(kotlinPalette.contains("fun gradient"))
    XCTAssertFalse(kotlinPalette.contains("GradientToken"))

    let owned = DesignTokensEmitter.ownedPaths(config: config)
    XCTAssertEqual(owned.count, 8)
    XCTAssertEqual(owned.subtracting(files.map(\.path)).sorted(),
                   ["src-ios/Sources/Theming/Generated/SemanticGradient.swift",
                    "src-kmp/theming/src/commonMain/kotlin/com/example/theming/Generated/SemanticGradient.kt"])
  }
}
