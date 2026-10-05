// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import XCTest

@testable import DuetCLI

/// The DTCG 2025.10 source (`parity/design-tokens.yaml` version 2) and
/// `duet design-tokens migrate`.
///
/// `Resources/tokens/dtcg/` is the golden config migrated: a version-2
/// config, a resolver and four token files, valid against the format's
/// official JSON schemas. It generates the same files as the golden version-1
/// config, `Resources/tokens/expected/`, except the line naming the source.
final class DesignTokensDTCGTests: XCTestCase {
  typealias JSON = DTCGSource.JSON

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

  private func text(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
  }

  private static let fixtureFiles = [
    "design-tokens.yaml",
    "design-tokens.resolver.json",
    "design-tokens/color.light.tokens.json",
    "design-tokens/color.dark.tokens.json",
    "design-tokens/type.tokens.json",
    "design-tokens/gradient.tokens.json",
  ]

  /// A repo holding the DTCG fixture under `parity/`, with no fixtures
  /// directory: `design-tokens` finds it by its config.
  private func dtcgRepo() throws -> Repo {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("duet-dtcg-\(UUID().uuidString)")
    for name in Self.fixtureFiles {
      let target = root.appendingPathComponent("parity/\(name)")
      try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: try resource("tokens/dtcg/\(name)"), to: target)
    }
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return Repo(root: root)
  }

  private func load(_ repo: Repo) throws -> DesignTokenConfig {
    try XCTUnwrap(try DesignTokenConfig.load(repo: repo))
  }

  private func read(_ repo: Repo, _ path: String) throws -> JSON {
    try DTCGSource.parseJSON(try text(repo.root.appendingPathComponent(path)), path: path)
  }

  private func write(_ repo: Repo, _ path: String, _ value: JSON) throws {
    try Data(DesignTokensJSON.render(value).utf8).write(to: repo.root.appendingPathComponent(path))
  }

  /// *value* with the member at *path* replaced (nil removes it, a missing
  /// member is appended).
  private func setting(_ value: JSON, _ path: [String], to new: JSON?) -> JSON {
    guard let key = path.first, case var .object(pairs) = value else { return value }
    let index = pairs.firstIndex { $0.0 == key }
    if path.count == 1 {
      if let new {
        if let index { pairs[index].1 = new } else { pairs.append((key, new)) }
      } else if let index {
        pairs.remove(at: index)
      }
      return .object(pairs)
    }
    guard let index else { return value }
    pairs[index].1 = setting(pairs[index].1, Array(path.dropFirst()), to: new)
    return .object(pairs)
  }

  private func edit(_ repo: Repo, _ file: String, _ path: [String], to new: JSON?) throws {
    try write(repo, file, setting(try read(repo, file), path, to: new))
  }

  private func emitted(_ repo: Repo) throws -> [String: Data] {
    Dictionary(uniqueKeysWithValues: DesignTokensEmitter.emit(config: try load(repo)).map { ($0.path, $0.bytes) })
  }

  private func assertRefused(
    _ repo: Repo, contains needle: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    do {
      _ = try DesignTokenConfig.load(repo: repo)
      XCTFail("expected an error mentioning '\(needle)'", file: file, line: line)
    } catch {
      XCTAssertTrue("\(error)".contains(needle), "error was: \(error)", file: file, line: line)
    }
  }

  private static let light = "parity/design-tokens/color.light.tokens.json"
  private static let dark = "parity/design-tokens/color.dark.tokens.json"
  private static let type = "parity/design-tokens/type.tokens.json"
  private static let gradient = "parity/design-tokens/gradient.tokens.json"
  private static let resolver = "parity/design-tokens.resolver.json"

  // MARK: - The fixture

  func testMigrateWritesTheDTCGFixtureFromTheGoldenConfig() throws {
    let golden = try DesignTokenConfig.parse(
      try text(try resource("tokens/design-tokens.yaml")), path: DesignTokenConfig.relativePath)
    let output = try DesignTokensMigrate.documents(golden)
    XCTAssertEqual(Set(output.files.map(\.path)), Set(Self.fixtureFiles.map { "parity/\($0)" }))
    for (path, content) in output.files {
      let expected = try text(try resource("tokens/dtcg/" + path.dropFirst("parity/".count)))
      XCTAssertEqual(content, expected, "\(path) drifted from the fixture")
    }
  }

  func testTheDTCGFixtureGeneratesTheGoldenFiles() throws {
    let config = try load(try dtcgRepo())
    XCTAssertEqual(config.source, "parity/design-tokens.resolver.json")
    let files = DesignTokensEmitter.emit(config: config)
    XCTAssertEqual(files.count, 10)
    for file in files {
      let name = (file.path as NSString).lastPathComponent
      let expected = try text(try resource("tokens/expected/\(name)"))
        .replacingOccurrences(of: "from parity/design-tokens.yaml —", with: "from parity/design-tokens.resolver.json —")
        .replacingOccurrences(of: #""source": "parity/design-tokens.yaml""#,
                              with: #""source": "parity/design-tokens.resolver.json""#)
      XCTAssertEqual(file.content, expected, "\(name) differs from the version-1 golden beyond its source line")
    }
  }

  func testTheVerbFindsARepoByItsTokenConfig() throws {
    let repo = try dtcgRepo()
    let nested = repo.root.appendingPathComponent("src-ios/Sources")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    XCTAssertNil(Repo.discover(from: nested.path), "no parity/fixtures in this tree")
    XCTAssertEqual(
      Repo.discover(marker: DesignTokenConfig.relativePath, from: nested.path)?.root.standardizedFileURL,
      repo.root.standardizedFileURL)
  }

  func testCheckIsGreenAfterGenerationFromDTCG() throws {
    let repo = try dtcgRepo()
    let config = try load(repo)
    XCTAssertEqual(try DesignTokensVerb.regenerate(repo: repo, config: config, check: false).written.count, 10)
    let checked = try DesignTokensVerb.regenerate(repo: repo, config: config, check: true)
    XCTAssertEqual(checked.upToDate, 10)
    XCTAssertFalse(checked.failed)
  }

  // MARK: - Refused: one change each, named

  func testAHexThatDisagreesWithItsComponentsIsRefused() throws {
    let repo = try dtcgRepo()
    try edit(repo, Self.light, ["color", "Labels", "labelPrimary", "$value", "hex"], to: .string("#ff0000"))
    assertRefused(repo, contains: "'hex' #ff0000 disagrees with the components")
  }

  func testAValueEditMakesTheGeneratedFilesStale() throws {
    let repo = try dtcgRepo()
    _ = try DesignTokensVerb.regenerate(repo: repo, config: try load(repo), check: false)
    try edit(repo, Self.dark, ["color", "accent", "$value"], to: .object([
      ("colorSpace", .string("srgb")), ("components", .array([.number(1), .number(0), .number(0)])),
      ("hex", .string("#ff0000")),
    ]))
    let checked = try DesignTokensVerb.regenerate(repo: repo, config: try load(repo), check: true)
    XCTAssertTrue(checked.failed)
    XCTAssertTrue(checked.stale.contains { $0.hasSuffix("MainThemePalette.swift") })
    XCTAssertTrue(checked.stale.contains { $0.hasSuffix("tokens.css") })
  }

  func testAColourOnlyInTheDarkFileIsRefused() throws {
    let repo = try dtcgRepo()
    try edit(repo, Self.dark, ["color", "accentQuiet"], to: .object([
      ("$value", .object([("colorSpace", .string("srgb")), ("components", .array([.number(0), .number(0), .number(0)]))])),
    ]))
    assertRefused(repo, contains: "'color.accentQuiet' is defined only for the dark appearance")
  }

  func testAColourMissingFromTheDarkFileIsRefused() throws {
    let repo = try dtcgRepo()
    try edit(repo, Self.dark, ["color", "accent"], to: nil)
    assertRefused(repo, contains: "color 'color.accent' has no value in the dark appearance")
  }

  func testALiteralFamilyInATypographyTokenIsRefused() throws {
    let repo = try dtcgRepo()
    try edit(repo, Self.type, ["typography", "Chrome — the sans face", "headline", "$value", "fontFamily"],
             to: .array([.string("Inter"), .string("sans-serif")]))
    assertRefused(repo, contains: "'fontFamily' must reference a fontFamily token")
  }

  func testALineHeightDimensionIsRefused() throws {
    let repo = try dtcgRepo()
    try edit(repo, Self.type, ["typography", "Chrome — the sans face", "headline", "$value", "lineHeight"],
             to: .object([("value", .number(22)), ("unit", .string("px"))]))
    assertRefused(repo, contains: "'lineHeight' must be a number, the multiple of the font size")
  }

  func testARemSizeIsRefused() throws {
    let repo = try dtcgRepo()
    try edit(repo, Self.type, ["typography", "Chrome — the sans face", "headline", "$value", "fontSize"],
             to: .object([("value", .number(1.0625)), ("unit", .string("rem"))]))
    assertRefused(repo, contains: "fontSize must be a px dimension")
  }

  func testADisplayP3ColourIsRefused() throws {
    let repo = try dtcgRepo()
    try edit(repo, Self.light, ["color", "accent", "$value"], to: .object([
      ("colorSpace", .string("display-p3")), ("components", .array([.number(0.2), .number(0.3), .number(0.5)])),
    ]))
    assertRefused(repo, contains: "the targets draw sRGB")
  }

  func testAMissingTextStyleIsRefusedWithASwiftTarget() throws {
    let repo = try dtcgRepo()
    try edit(repo, Self.type, ["typography", "Chrome — the sans face", "headline", "$extensions"], to: nil)
    assertRefused(repo, contains: "needs $extensions[\"dev.modaal.duet\"].textStyle")
  }

  func testAMisspeltExtensionKeyIsRefused() throws {
    let repo = try dtcgRepo()
    try edit(repo, Self.type,
             ["typography", "Chrome — the sans face", "headline", "$extensions", "dev.modaal.duet", "textstyle"],
             to: .string("title2"))
    assertRefused(repo, contains: "unknown key 'textstyle' in $extensions[\"dev.modaal.duet\"]")
  }

  func testAMisspeltTokenKeyIsRefused() throws {
    let repo = try dtcgRepo()
    try edit(repo, Self.light, ["color", "accent", "$valeu"], to: .string("x"))
    assertRefused(repo, contains: "token 'color.accent': unknown key '$valeu'")
  }

  func testAnAliasToAMissingTokenIsRefused() throws {
    let repo = try dtcgRepo()
    try edit(repo, Self.gradient, ["gradient", "surfaceHero", "$value"], to: .array([
      .object([("color", .string("{color.Surfaces.surfacePrimry}")), ("position", .number(0))]),
      .object([("color", .string("{color.Surfaces.surfaceRaised}")), ("position", .number(1))]),
    ]))
    assertRefused(repo, contains: "alias '{color.Surfaces.surfacePrimry}' names no token")
  }

  func testUnevenGradientStopsAreRefused() throws {
    let repo = try dtcgRepo()
    try edit(repo, Self.gradient, ["gradient", "surfaceHero", "$value"], to: .array([
      .object([("color", .string("{color.Surfaces.surfacePrimary}")), ("position", .number(0))]),
      .object([("color", .string("{color.Surfaces.surfaceRaised}")), ("position", .number(0.8))]),
    ]))
    assertRefused(repo, contains: "stop 1 must sit at 1.0")
  }

  func testANewerResolverVersionIsRefused() throws {
    let repo = try dtcgRepo()
    try edit(repo, Self.resolver, ["version"], to: .string("2026.04"))
    assertRefused(repo, contains: "'version' must be \"2025.10\"")
  }

  func testExtensionsAtTheResolverRootAreRefused() throws {
    let repo = try dtcgRepo()
    try edit(repo, Self.resolver, ["$extensions"], to: .object([("dev.modaal.duet", .object([]))]))
    assertRefused(repo, contains: "unknown key '$extensions'")
  }

  func testAConfigNamingNoResolverIsRefused() throws {
    let repo = try dtcgRepo()
    let url = DesignTokenConfig.url(in: repo)
    try Data(try text(url).replacingOccurrences(
      of: "tokens: design-tokens.resolver.json", with: "tokens: tokens.resolver.json").utf8).write(to: url)
    assertRefused(repo, contains: "'tokens' names parity/tokens.resolver.json, which does not exist")
  }

  func testAHandEditedStylesheetIsStale() throws {
    let repo = try dtcgRepo()
    let config = try load(repo)
    _ = try DesignTokensVerb.regenerate(repo: repo, config: config, check: false)
    let css = repo.root.appendingPathComponent("web/shared/tokens.css")
    try Data(try text(css).replacingOccurrences(of: "#1A1A1A", with: "#FF0000").utf8).write(to: css)
    XCTAssertEqual(try DesignTokensVerb.regenerate(repo: repo, config: config, check: true).stale,
                   ["web/shared/tokens.css"])
  }

  // MARK: - Equivalent forms: the same output

  private func assertSameOutput(
    _ change: (Repo) throws -> Void, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let baseline = try emitted(try dtcgRepo())
    let repo = try dtcgRepo()
    try change(repo)
    XCTAssertEqual(try emitted(repo), baseline, "the generated files changed", file: file, line: line)
  }

  func testADesignToolsExtensionDataIsKeptAndIgnored() throws {
    try assertSameOutput { repo in
      for file in [Self.light, Self.dark] {
        try self.edit(repo, file, ["color", "accent", "$extensions"],
                      to: .object([("com.figma.scopes", .array([.string("ALL_FILLS")]))]))
      }
    }
  }

  func testDimensionTokensOutsideTheScalesAreSkipped() throws {
    try assertSameOutput { repo in
      try self.edit(repo, Self.type, ["size"], to: .object([
        ("$type", .string("dimension")),
        ("s", .object([("$value", .object([("value", .number(8)), ("unit", .string("px"))]))])),
      ]))
    }
  }

  func testGradientsWithLiteralStopsInTheColourFiles() throws {
    try assertSameOutput { repo in
      let shared = try self.read(repo, Self.gradient)
      for file in [Self.light, Self.dark] {
        var doc = try self.read(repo, file)
        // The fixed wash is the same in both files; the hero takes each
        // appearance's own surfaces.
        let hero: [String] = file == Self.light ? ["#fbfaf7", "#ffffff"] : ["#141414", "#1e1e1e"]
        func literal(_ hex: String) -> JSON {
          let value = UInt32(hex.dropFirst(), radix: 16)!
          return DesignTokensMigrate.color(.init(rgb: value, alpha: 1))
        }
        func stopList(_ hexes: [String]) -> JSON {
          .array(hexes.enumerated().map { .object([("color", literal($1)), ("position", .number(Double($0)))]) })
        }
        let wash = self.setting(shared["gradient"]!["surfaceWash"]!, ["$value"], to: stopList(["#ffffff", "#fbfaf7"]))
        let heroToken = self.setting(shared["gradient"]!["surfaceHero"]!, ["$value"], to: stopList(hero))
        doc = self.setting(doc, ["gradient"], to: .object([
          ("$type", .string("gradient")), ("surfaceWash", wash), ("surfaceHero", heroToken),
        ]))
        try self.write(repo, file, doc)
      }
      try self.edit(repo, Self.resolver, ["sets", "styles", "sources"], to: .array([
        .object([("$ref", .string("design-tokens/type.tokens.json"))]),
      ]))
      try FileManager.default.removeItem(at: repo.root.appendingPathComponent(Self.gradient))
    }
  }

  func testAColourAliasResolvesInEachAppearance() throws {
    try assertSameOutput { repo in
      // interactivePrimary is labelPrimary's value in both appearances.
      for file in [Self.light, Self.dark] {
        try self.edit(repo, file, ["color", "Interactive", "interactivePrimary", "$value"],
                      to: .string("{color.Labels.labelPrimary}"))
      }
    }
  }

  func testUnicodeEscapesReadAsTheirCharacters() throws {
    try assertSameOutput { repo in
      for file in [Self.light, Self.dark, Self.type, Self.gradient, Self.resolver] {
        let url = repo.root.appendingPathComponent(file)
        var escaped = ""
        for scalar in try self.text(url).unicodeScalars {
          escaped += scalar.value > 0x7F ? String(format: "\\u%04x", scalar.value) : String(scalar)
        }
        try Data(escaped.utf8).write(to: url)
      }
    }
  }

  func testInlineSourcesInOneResolverFile() throws {
    try assertSameOutput { repo in
      let inline = { (path: String) throws -> JSON in try self.read(repo, path) }
      var resolver = try self.read(repo, Self.resolver)
      resolver = self.setting(resolver, ["sets", "styles", "sources"],
                              to: .array([try inline(Self.type), try inline(Self.gradient)]))
      resolver = self.setting(resolver, ["modifiers", "appearance", "contexts"], to: .object([
        ("light", .array([try inline(Self.light)])), ("dark", .array([try inline(Self.dark)])),
      ]))
      try self.write(repo, Self.resolver, resolver)
      try FileManager.default.removeItem(at: repo.root.appendingPathComponent("parity/design-tokens"))
    }
  }

  func testMinifiedFiles() throws {
    try assertSameOutput { repo in
      for file in [Self.light, Self.dark, Self.type, Self.gradient, Self.resolver] {
        let url = repo.root.appendingPathComponent(file)
        // Whitespace outside strings removed; key order kept.
        var out = ""
        var inString = false
        var escaped = false
        for character in try self.text(url) {
          if inString {
            out.append(character)
            if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
          } else if character == "\"" {
            inString = true
            out.append(character)
          } else if !character.isWhitespace {
            out.append(character)
          }
        }
        try Data(out.utf8).write(to: url)
      }
    }
  }

  // MARK: - Spacing and corner radii

  private static let dimension = "parity/design-tokens/dimension.tokens.json"

  private static func px(_ value: Double) -> JSON {
    .object([("value", .number(value)), ("unit", .string("px"))])
  }

  /// The fixture plus a dimension file in the base set: a spacing scale in two
  /// groups, one step documented and one noted, and an ungrouped radius scale.
  private func scalesRepo() throws -> Repo {
    let repo = try dtcgRepo()
    try write(repo, Self.dimension, .object([
      ("spacing", .object([
        ("$type", .string("dimension")),
        ("Stack", .object([
          ("xs", .object([("$value", Self.px(4))])),
          ("s", .object([("$description", .string("Between the lines of one block.")), ("$value", Self.px(8))])),
        ])),
        ("Inset", .object([
          ("screen", .object([
            ("$value", Self.px(16)),
            ("$extensions", .object([("dev.modaal.duet", .object([("note", .string("The system's readable margin."))]))])),
          ])),
        ])),
      ])),
      ("radius", .object([
        ("$type", .string("dimension")),
        ("card", .object([("$value", Self.px(12))])),
        ("hairline", .object([("$value", Self.px(0.5))])),
      ])),
    ]))
    try edit(repo, Self.resolver, ["sets", "styles", "sources"], to: .array([
      .object([("$ref", .string("design-tokens/type.tokens.json"))]),
      .object([("$ref", .string("design-tokens/gradient.tokens.json"))]),
      .object([("$ref", .string("design-tokens/dimension.tokens.json"))]),
    ]))
    return repo
  }

  func testTheScalesGenerateConstantsInEveryTarget() throws {
    let repo = try scalesRepo()
    let config = try load(repo)
    XCTAssertEqual(config.spacing.map(\.name), ["Stack", "Inset"])
    XCTAssertEqual(config.radii.flatMap(\.tokens).map(\.value), [12, 0.5])
    let files = DesignTokensEmitter.emit(config: config)
    XCTAssertEqual(files.count, 14, "the fixture's ten, and two scale files per language")

    XCTAssertEqual(try XCTUnwrap(files.first { $0.path.hasSuffix("/SemanticSpacing.swift") }).content, """
      // Copyright (c) 2026 Modaal.dev
      // Licensed under the MIT License. See LICENSE file for details.

      // GENERATED by `duet design-tokens` from parity/design-tokens.resolver.json —
      // do not edit. Change a value in the config and regenerate:
      // `duet design-tokens`. A hand-edit here fails `duet design-tokens --check`,
      // which regenerates in memory and compares.

      #if os(iOS)

      import CoreGraphics

      /// The app's spacing scale: padding, gaps and insets, in points. A step is
      /// chosen by what it separates, never by its size — the value is the config's
      /// to change.
      public enum SemanticSpacing {

        // MARK: - Stack

        public static let xs: CGFloat = 4

        /// Between the lines of one block.
        public static let s: CGFloat = 8

        // MARK: - Inset

        // The system's readable margin.
        public static let screen: CGFloat = 16
      }

      #endif

      """)
    XCTAssertEqual(try XCTUnwrap(files.first { $0.path.hasSuffix("/SemanticRadius.kt") }).content, """
      // Copyright (c) 2026 Modaal.dev
      // Licensed under the MIT License. See LICENSE file for details.

      // GENERATED by `duet design-tokens` from parity/design-tokens.resolver.json —
      // do not edit. Change a value in the config and regenerate:
      // `duet design-tokens`. A hand-edit here fails `duet design-tokens --check`,
      // which regenerates in memory and compares.

      package com.example.theming

      /**
       * The app's corner-radius scale, in dp — `SemanticRadius.card.dp` in Compose. A
       * radius is chosen by the surface it rounds, never by its size — the value is
       * the config's to change.
       *
       * Constants are lowerCamel, the spelling the Apple tree uses.
       */
      object SemanticRadius {
        const val card: Float = 12f
        const val hairline: Float = 0.5f
      }

      """)
    let kotlinSpacing = try XCTUnwrap(files.first { $0.path.hasSuffix("/SemanticSpacing.kt") }).content
    XCTAssertTrue(kotlinSpacing.contains("""
        // Stack
        const val xs: Float = 4f

        /**
         * Between the lines of one block.
         */
        const val s: Float = 8f
      """))
    XCTAssertTrue(kotlinSpacing.contains("  // The system's readable margin.\n  const val screen: Float = 16f\n"))

    let css = try XCTUnwrap(files.first { $0.path == "web/shared/tokens.css" }).content
    XCTAssertTrue(css.contains("""
         linear-gradient(180deg, var(--gradient-<name>)). Type: class="font-<name>".
         Spacing: var(--spacing-<name>). Corner radii: var(--radius-<name>). */
      """))
    XCTAssertTrue(css.contains("""
        /* Stack */
        --spacing-xs: 4px;
        /* Between the lines of one block. */
        --spacing-s: 8px;

        /* Inset */
        --spacing-screen: 16px;

        --radius-card: 12px;
        --radius-hairline: 0.5px;
      }
      """))
    let manifest = try DTCGSource.parseJSON(
      try XCTUnwrap(files.first { $0.path == "web/shared/tokens.json" }).content, path: "tokens.json")
    guard case let .array(spacing)? = manifest["spacing"], case let .array(radii)? = manifest["radii"] else {
      return XCTFail("the manifest lists both scales")
    }
    XCTAssertEqual(spacing.compactMap { $0["css"]?.string }, ["--spacing-xs", "--spacing-s", "--spacing-screen"])
    XCTAssertEqual(spacing[2]["group"]?.string, "Inset")
    XCTAssertEqual(spacing[2]["note"]?.string, "The system's readable margin.")
    XCTAssertEqual(radii.compactMap { $0["value"]?.number }, [12, 0.5])

    // The check covers the scale files like every other generated file.
    XCTAssertEqual(try DesignTokensVerb.regenerate(repo: repo, config: config, check: false).written.count, 14)
    XCTAssertFalse(try DesignTokensVerb.regenerate(repo: repo, config: config, check: true).failed)
  }

  func testAConfigWithoutTheScalesWritesNoScaleSurface() throws {
    let files = DesignTokensEmitter.emit(config: try load(try dtcgRepo()))
    XCTAssertFalse(files.contains { $0.path.contains("SemanticSpacing") || $0.path.contains("SemanticRadius") })
    let css = try XCTUnwrap(files.first { $0.path == "web/shared/tokens.css" }).content
    XCTAssertFalse(css.contains("--spacing-") || css.contains("--radius-") || css.contains("Corner radii"))
    let manifest = try XCTUnwrap(files.first { $0.path == "web/shared/tokens.json" }).content
    XCTAssertFalse(manifest.contains("\"spacing\"") || manifest.contains("\"radii\""))
  }

  func testADroppedScaleLeavesItsFilesOrphaned() throws {
    let repo = try scalesRepo()
    _ = try DesignTokensVerb.regenerate(repo: repo, config: try load(repo), check: false)
    try edit(repo, Self.dimension, ["radius"], to: nil)
    let checked = try DesignTokensVerb.regenerate(repo: repo, config: try load(repo), check: true)
    XCTAssertEqual(checked.orphans, [
      "src-ios/Sources/Theming/Generated/SemanticRadius.swift",
      "src-kmp/theming/src/commonMain/kotlin/com/example/theming/Generated/SemanticRadius.kt",
    ])
  }

  func testAScaleTokenThatDiffersByAppearanceIsRefused() throws {
    let repo = try dtcgRepo()
    try edit(repo, Self.light, ["spacing"], to: .object([("$type", .string("dimension")), ("m", .object([("$value", Self.px(16))]))]))
    try edit(repo, Self.dark, ["spacing"], to: .object([("$type", .string("dimension")), ("m", .object([("$value", Self.px(20))]))]))
    assertRefused(repo, contains: "a spacing token has one value in both appearances (light 16px, dark 20px)")
  }

  func testAScaleKeyThatIsNotAnIdentifierIsRefused() throws {
    let repo = try scalesRepo()
    try edit(repo, Self.dimension, ["spacing", "Stack", "2xl"], to: .object([("$value", Self.px(48))]))
    assertRefused(repo, contains: "dimension 'spacing.Stack.2xl': the key becomes a constant in every target language")
  }

  func testARemScaleTokenIsRefused() throws {
    let repo = try scalesRepo()
    try edit(repo, Self.dimension, ["radius", "card", "$value"],
             to: .object([("value", .number(0.75)), ("unit", .string("rem"))]))
    assertRefused(repo, contains: "must be a px dimension")
  }

  func testAScaleTokenNoteIsTheOnlyExtensionKey() throws {
    let repo = try scalesRepo()
    try edit(repo, Self.dimension, ["radius", "card", "$extensions"],
             to: .object([("dev.modaal.duet", .object([("textStyle", .string("body"))]))]))
    assertRefused(repo, contains: "unknown key 'textStyle' in $extensions[\"dev.modaal.duet\"] (known: note)")
  }

  // MARK: - App-declared families

  /// A config whose families are its own: `display` (with font files) and
  /// `sans`, and all three targets.
  private func familiesRepo() throws -> Repo {
    let repo = try dtcgRepo()
    try FileManager.default.createDirectory(
      at: repo.root.appendingPathComponent("fonts"), withIntermediateDirectories: true)
    try Data("variable-face".utf8).write(to: repo.root.appendingPathComponent("fonts/Brand-Variable.ttf"))
    try Data("semibold-face".utf8).write(to: repo.root.appendingPathComponent("fonts/Brand-SemiBold.woff2"))
    var type = try read(repo, Self.type)
    type = setting(type, ["fontFamily"], to: .object([
      ("$type", .string("fontFamily")),
      ("display", .object([
        ("$value", .array([.string("Brand Sans"), .string("system-ui"), .string("sans-serif")])),
        ("$extensions", .object([("dev.modaal.duet", .object([("files", .array([
          .object([("path", .string("fonts/Brand-Variable.ttf")), ("weight", .array([.number(100), .number(900)]))]),
          .object([("path", .string("fonts/Brand-SemiBold.woff2")), ("weight", .number(600))]),
        ]))]))])),
      ])),
      ("sans", .object([("$value", .array([.string("-apple-system"), .string("sans-serif")]))])),
    ]))
    // Every type token on sans, the display title on display.
    let text = DesignTokensJSON.render(type)
      .replacingOccurrences(of: "{fontFamily.serif}", with: "{fontFamily.sans}")
      .replacingOccurrences(of: "{fontFamily.mono}", with: "{fontFamily.sans}")
    type = try DTCGSource.parseJSON(text, path: Self.type)
    type = setting(type, ["typography", "Display — the serif face", "largeTitle", "$value", "fontFamily"],
                   to: .string("{fontFamily.display}"))
    try write(repo, Self.type, type)
    return repo
  }

  func testAppDeclaredFamiliesGenerateTheKotlinFamilyEnum() throws {
    let config = try load(try familiesRepo())
    XCTAssertEqual(config.families.map(\.rawValue), ["display", "sans"])
    let files = DesignTokensEmitter.emit(config: config)
    let enumFile = try XCTUnwrap(files.first { $0.path.hasSuffix("/SemanticFontFamily.kt") })
    XCTAssertEqual(enumFile.content, """
      // Copyright (c) 2026 Modaal.dev
      // Licensed under the MIT License. See LICENSE file for details.

      // GENERATED by `duet design-tokens` from parity/design-tokens.resolver.json —
      // do not edit. Change a value in the config and regenerate:
      // `duet design-tokens`. A hand-edit here fails `duet design-tokens --check`,
      // which regenerates in memory and compares.

      package com.example.theming

      import dev.modaal.duet.services.theming.FontFamilyToken

      /**
       * The app's font families, one entry per family the config declares.
       *
       * A token names a family, never a file. The app's font resolver switches over
       * this enum and maps each entry to a face from its own font resources, so a
       * family added to the config is a compile error there until it is mapped.
       */
      enum class SemanticFontFamily : FontFamilyToken {
        Display,
        Sans,
      }

      """)
    let palette = try XCTUnwrap(files.first { $0.path.hasSuffix("/MainPalette.kt") }).content
    XCTAssertTrue(palette.contains("          family = SemanticFontFamily.Display,"))
    XCTAssertTrue(palette.contains("          family = SemanticFontFamily.Sans,"))
    XCTAssertFalse(palette.contains("FontFamilyToken"), "the palette names the app's enum only")

    let swift = try XCTUnwrap(files.first { $0.path.hasSuffix("/MainThemePalette.swift") }).content
    XCTAssertTrue(swift.contains("    case display\n    case sans\n"))
  }

  func testTheEnginesThreeFamiliesKeepTheEngineEnum() throws {
    let files = DesignTokensEmitter.emit(config: try load(try dtcgRepo()))
    XCTAssertFalse(files.contains { $0.path.hasSuffix("/SemanticFontFamily.kt") })
    let palette = try XCTUnwrap(files.first { $0.path.hasSuffix("/MainPalette.kt") }).content
    XCTAssertTrue(palette.contains("import dev.modaal.duet.services.theming.FontFamilyToken"))
    XCTAssertTrue(palette.contains("family = FontFamilyToken.Serif,"))
  }

  func testAFamilysFilesAreCopiedAndDeclared() throws {
    let repo = try familiesRepo()
    let config = try load(repo)
    let files = DesignTokensEmitter.emit(config: config)
    let fonts = files.filter { $0.path.hasPrefix("web/shared/fonts/") }
    XCTAssertEqual(fonts.map(\.path), ["web/shared/fonts/Brand-Variable.ttf", "web/shared/fonts/Brand-SemiBold.woff2"])
    XCTAssertEqual(fonts.map(\.bytes), [Data("variable-face".utf8), Data("semibold-face".utf8)])
    let css = try XCTUnwrap(files.first { $0.path == "web/shared/tokens.css" }).content
    XCTAssertTrue(css.contains("""
      @font-face {
        font-family: "Brand Sans";
        src: url("fonts/Brand-Variable.ttf") format("truetype");
        font-weight: 100 900;
      }

      @font-face {
        font-family: "Brand Sans";
        src: url("fonts/Brand-SemiBold.woff2") format("woff2");
        font-weight: 600;
      }

      :root {
      """))
    XCTAssertTrue(css.contains("  --font-family-display: \"Brand Sans\", system-ui, sans-serif;"))

    // Copied files are checked like the generated text files, and a file the
    // config stops naming is reported.
    _ = try DesignTokensVerb.regenerate(repo: repo, config: config, check: false)
    try Data("edited".utf8).write(to: repo.root.appendingPathComponent("web/shared/fonts/Brand-SemiBold.woff2"))
    try Data("old".utf8).write(to: repo.root.appendingPathComponent("web/shared/fonts/Retired.ttf"))
    let checked = try DesignTokensVerb.regenerate(repo: repo, config: config, check: true)
    XCTAssertEqual(checked.stale, ["web/shared/fonts/Brand-SemiBold.woff2"])
    XCTAssertEqual(checked.orphans, ["web/shared/fonts/Retired.ttf"])
  }

  func testAFontFileThatIsMissingIsRefused() throws {
    let repo = try familiesRepo()
    try FileManager.default.removeItem(at: repo.root.appendingPathComponent("fonts/Brand-SemiBold.woff2"))
    assertRefused(repo, contains: "cannot read the font file 'fonts/Brand-SemiBold.woff2'")
  }

  // MARK: - migrate

  private func versionOneRepo(_ config: String) throws -> Repo {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("duet-migrate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("parity"), withIntermediateDirectories: true)
    try Data(config.utf8).write(to: root.appendingPathComponent(DesignTokenConfig.relativePath))
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return Repo(root: root)
  }

  func testMigrateThenGenerateChangesOnlyTheSourceLine() throws {
    let golden = try text(try resource("tokens/design-tokens.yaml"))
    let repo = try versionOneRepo(golden)
    let before = DesignTokensEmitter.emit(config: try load(repo))
    XCTAssertEqual(try DesignTokensMigrate.run(repo: repo, options: Options()), 0)
    let after = DesignTokensEmitter.emit(config: try load(repo))
    XCTAssertEqual(before.map(\.path), after.map(\.path))
    for (old, new) in zip(before, after) {
      XCTAssertEqual(
        old.content
          .replacingOccurrences(of: "from parity/design-tokens.yaml —", with: "from parity/design-tokens.resolver.json —")
          .replacingOccurrences(of: #""source": "parity/design-tokens.yaml""#,
                                with: #""source": "parity/design-tokens.resolver.json""#),
        new.content, old.path)
    }
    XCTAssertEqual(try DesignTokensMigrate.run(repo: repo, options: Options()), 1, "already version 2")
  }

  func testMigrateWritesAGradientNoColourMatchesIntoTheColourFiles() throws {
    let config = """
      version: 1
      kotlin:
        output: gen
        package: app.theming
        engine: dev.modaal.duet.services.theming
        palette: MainPalette
      colors:
        - tokens:
            - name: ground
              light: "#FFFFFF"
              dark: "#000000"
      gradients:
        - name: dusk
          light: ["#FFFFFF", "#EEEEEE"]
          dark: ["#000000", "#111111"]
      """
    let repo = try versionOneRepo(config)
    let before = DesignTokensEmitter.emit(config: try load(repo))
    XCTAssertEqual(try DesignTokensMigrate.run(repo: repo, options: Options()), 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent(Self.gradient).path))
    XCTAssertNotNil(try read(repo, Self.dark)["gradient"]?["dusk"])
    let after = DesignTokensEmitter.emit(config: try load(repo))
    for (old, new) in zip(before, after) {
      XCTAssertEqual(old.content.replacingOccurrences(of: "design-tokens.yaml", with: "design-tokens.resolver.json"),
                     new.content, old.path)
    }
  }

  func testMigrateRefusesToOverwriteATokenFile() throws {
    let repo = try versionOneRepo(try text(try resource("tokens/design-tokens.yaml")))
    try FileManager.default.createDirectory(
      at: repo.root.appendingPathComponent("parity/design-tokens"), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: repo.root.appendingPathComponent(Self.type))
    XCTAssertEqual(try DesignTokensMigrate.run(repo: repo, options: Options()), 1)
    XCTAssertEqual(try text(repo.root.appendingPathComponent(Self.type)), "{}")
  }

  // MARK: - The JSON printer

  func testThePrinterWritesScalarArraysOnOneLineAndWholeNumbersBare() {
    let value: JSON = .object([
      ("a", .array([.number(1), .number(0.102), .number(-0.34)])),
      ("b", .object([("c", .string("quote \" and \\ and \n"))])),
      ("d", .array([.object([("e", .null)])])),
      ("f", .object([])),
    ])
    XCTAssertEqual(DesignTokensJSON.render(value), """
      {
        "a": [1, 0.102, -0.34],
        "b": {
          "c": "quote \\" and \\\\ and \\n"
        },
        "d": [
          {
            "e": null
          }
        ],
        "f": {}
      }

      """)
  }
}
