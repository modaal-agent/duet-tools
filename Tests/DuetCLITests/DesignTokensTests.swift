// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import XCTest

@testable import DuetCLI

/// `duet design-tokens`' golden receipt and its schema controls.
///
/// The golden config is a fictional app's token master, sized to cover every
/// form the schema accepts rather than to be large, and the eight files under
/// `Resources/tokens/expected/` are pinned byte-for-byte. An emission change
/// updates them in the same commit, and the diff is the review.
final class DesignTokensTests: XCTestCase {

  // MARK: - Harness

  private func resource(_ path: String) throws -> URL {
    // A top-level directory literally named "Resources" makes Bundle adopt the
    // Resources-style layout, so resourceURL may already point INSIDE it.
    let base = try XCTUnwrap(Bundle.module.resourceURL)
    let candidates = [
      base.appendingPathComponent("Resources/\(path)"),
      base.appendingPathComponent(path),
    ]
    return try XCTUnwrap(
      candidates.first { FileManager.default.fileExists(atPath: $0.path) },
      "missing resource \(path) under \(base.path)")
  }

  private func goldenConfigText() throws -> String {
    try String(contentsOf: try resource("tokens/design-tokens.yaml"), encoding: .utf8)
  }

  private func goldenConfig() throws -> DesignTokenConfig {
    try DesignTokenConfig.parse(try goldenConfigText(), path: DesignTokenConfig.relativePath)
  }

  /// A repo whose only content is the config — enough for the verb, which
  /// reads the manifest not at all.
  private func makeRepo(config: String) throws -> Repo {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("duet-design-tokens-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("parity/fixtures"), withIntermediateDirectories: true)
    try Data(config.utf8).write(to: root.appendingPathComponent(DesignTokenConfig.relativePath))
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return Repo(root: root)
  }

  private func assertThrows(
    _ config: String, contains needle: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    do {
      _ = try DesignTokenConfig.parse(config, path: "design-tokens.yaml")
      XCTFail("expected a schema error mentioning '\(needle)'", file: file, line: line)
    } catch {
      XCTAssertTrue("\(error)".contains(needle),
                    "error was: \(error)", file: file, line: line)
    }
  }

  /// The smallest config that parses — every control below starts from it.
  private let minimal = """
    version: 1
    swift:
      output: Sources/Theming/Generated
      engine: DuetTheming
      theme: MainTheme
    colors:
      - tokens:
          - name: labelPrimary
            light: "#14130F"
            dark: "#ECE9E0"
    fonts:
      - tokens:
          - name: bodyRegular
            family: serif
            weight: 400
            size: 17
            lineHeight: 26
            swift:
              textStyle: body
    """

  // MARK: - The golden

  func testGoldenConfigGeneratesTheExpectedFiles() throws {
    let config = try goldenConfig()
    let files = DesignTokensEmitter.emit(config: config)
    XCTAssertEqual(files.count, 8, "four files per declared language")
    for file in files {
      let name = (file.path as NSString).lastPathComponent
      let expected = try String(contentsOf: try resource("tokens/expected/\(name)"), encoding: .utf8)
      if file.content != expected {
        let dump = FileManager.default.temporaryDirectory
          .appendingPathComponent("duet-design-tokens-actual-\(name)")
        try? Data(file.content.utf8).write(to: dump)
        print("DesignTokensTests: actual \(name) dumped to \(dump.path)")
      }
      XCTAssertEqual(file.content, expected, "\(name) drifted from the golden")
    }
  }

  func testGoldenConfigCarriesTheWholeVocabulary() throws {
    let config = try goldenConfig()
    XCTAssertEqual(config.colorTokens.count, 20)
    XCTAssertEqual(config.fontTokens.count, 9)
    XCTAssertEqual(config.gradients.count, 2, "one per gradient form")
    XCTAssertEqual(config.colors.count, 6, "colour groups, the last of them unheaded")
    XCTAssertEqual(config.fonts.count, 4, "type groups")
  }

  /// The two languages read one input, so the case lists cannot diverge — the
  /// pin the mirror design needed is this equality, held by construction.
  func testBothLanguagesEmitTheSameCaseListInTheSameOrder() throws {
    let config = try goldenConfig()
    let files = DesignTokensEmitter.emit(config: config)
    func names(_ file: String, _ pattern: String) throws -> [String] {
      let content = try XCTUnwrap(files.first { $0.path.hasSuffix(file) }).content
      let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
      return regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
        .map { String(content[Range($0.range(at: 1), in: content)!]) }
    }
    let declared = config.colorTokens.map(\.name)
    XCTAssertEqual(try names("Generated/SemanticColor.swift", #"^  case (\w+)$"#), declared)
    XCTAssertEqual(try names("Generated/SemanticColor.kt", #"^  (\w+),$"#), declared)
  }

  // MARK: - Colour values

  /// Alpha is authored as the fraction and stored as a byte, and the byte is
  /// the fraction rounded half away from zero — the rule Android's own
  /// float-to-byte conversion uses, so a value lands where the platform would
  /// put it.
  func testAlphaBecomesTheRoundedByte() throws {
    let config = try goldenConfig()
    func color(_ name: String) throws -> DesignTokenConfig.ColorToken {
      try XCTUnwrap(config.colorTokens.first { $0.name == name })
    }
    guard case let .auto(opaqueLight, _) = try color("labelPrimary").appearance else {
      return XCTFail("labelPrimary is a two-appearance token")
    }
    XCTAssertEqual(opaqueLight.rgb, 0x1A_1A_1A)
    XCTAssertEqual(opaqueLight.argb, 0xFF_1A_1A_1A)

    guard case let .auto(scrim, _) = try color("surfaceScrim").appearance else {
      return XCTFail("surfaceScrim is a two-appearance token")
    }
    XCTAssertEqual(scrim.alpha, 0.24)
    XCTAssertEqual(scrim.argb, 0x3D_1A_1A_1A)

    // 0.3 × 255 is 76.5 — the one alpha that lands between two bytes.
    guard case let .auto(disabled, _) = try color("interactiveDisabledLabel").appearance
    else { return XCTFail("interactiveDisabledLabel is a two-appearance token") }
    XCTAssertEqual(disabled.alpha, 0.3)
    XCTAssertEqual(disabled.argb, 0x4D_1A_1A_1A)

    guard case let .fixed(onAccent) = try color("labelOnAccent").appearance else {
      return XCTFail("labelOnAccent is a one-value token")
    }
    XCTAssertEqual(onAccent.argb, 0xFF_FF_FF_FF)
  }

  func testFixedColourIsOneValueInBothAppearances() throws {
    let fixed = minimal
      .replacingOccurrences(of: ##"        light: "#14130F""##, with: ##"        value: "#FFFFFF""##)
      .replacingOccurrences(of: ##"        dark: "#ECE9E0""##, with: "        alpha: 0.5")
    let config = try DesignTokenConfig.parse(fixed, path: "design-tokens.yaml")
    guard case let .fixed(value) = config.colorTokens[0].appearance else {
      return XCTFail("expected the one-value form")
    }
    XCTAssertEqual(value.argb, 0x80_FF_FF_FF)
  }

  // MARK: - Schema controls

  func testUnknownKeyIsNamedAgainstItsToken() {
    assertThrows(minimal.replacingOccurrences(of: "dark:", with: "darkk:"),
                 contains: "color 'labelPrimary': unknown key 'darkk'")
  }

  func testUnknownTopLevelKeyIsAnError() {
    assertThrows(minimal + "\nshadows: []\n", contains: "top level: unknown key 'shadows'")
  }

  func testSchemaVersionIsChecked() {
    assertThrows(minimal.replacingOccurrences(of: "version: 1", with: "version: 2"),
                 contains: "version 2 is not a schema this toolchain reads")
  }

  func testColourNeedsSixHexDigits() {
    assertThrows(minimal.replacingOccurrences(of: ##""#14130F""##, with: ##""#141""##),
                 contains: "must be '#RRGGBB'")
    assertThrows(minimal.replacingOccurrences(of: ##""#14130F""##, with: ##""14130F""##),
                 contains: "must start with '#'")
  }

  func testTheTwoColourFormsAreAlternatives() {
    assertThrows(minimal.replacingOccurrences(of: "light:", with: "value:"),
                 contains: "'value' and 'dark' are alternatives")
  }

  func testTextStyleIsRequiredWhenASwiftTargetIsDeclared() {
    assertThrows(minimal.replacingOccurrences(
      of: """
                swift:
                  textStyle: body
        """, with: ""),
      contains: "font 'bodyRegular': a 'swift:' target is declared")
  }

  func testFamilyIsOneOfTheEngineThree() {
    assertThrows(minimal.replacingOccurrences(of: "family: serif", with: "family: cursive"),
                 contains: "family 'cursive' is not one of: serif, sans, mono")
  }

  func testDuplicateTokenNameIsAnError() {
    let twice = minimal.replacingOccurrences(
      of: "      - name: labelPrimary",
      with: """
              - name: labelPrimary
                light: "#000000"
                dark: "#FFFFFF"
              - name: labelPrimary
        """)
    assertThrows(twice, contains: "'labelPrimary' is declared twice")
  }

  func testTokenNameMustBeALegalCaseInBothLanguages() {
    assertThrows(minimal.replacingOccurrences(of: "name: labelPrimary", with: "name: label_primary"),
                 contains: "must be lowerCamelCase")
  }

  /// `minimal` plus a `gradients:` block, so a gradient rule is drilled
  /// against a config that is otherwise legal.
  private func withGradient(_ body: String) -> String {
    minimal + "\ngradients:\n  - name: backgroundHero\n" + body
  }

  func testAGradientDeclaresOneStopFormOrTheOther() {
    assertThrows(
      withGradient(
        """
            stops: ["#FFFFFF", "#000000"]
            light: ["#FFFFFF", "#000000"]
        """),
      contains: "declare either 'stops' or both 'light' and 'dark'")
  }

  func testATwoAppearanceGradientNeedsBothHalves() {
    assertThrows(
      withGradient(
        """
            light: ["#FFFFFF", "#000000"]
        """),
      contains: "needs both 'light' and 'dark'")
  }

  func testAGradientStopListNeedsTwoColours() {
    assertThrows(
      withGradient(
        """
            light: ["#FFFFFF"]
            dark: ["#000000", "#FFFFFF"]
        """),
      contains: "'light' needs at least two colours")
  }

  func testAConfigWithNoTargetIsAnError() {
    let noTarget = minimal.replacingOccurrences(of: """
      swift:
        output: Sources/Theming/Generated
        engine: DuetTheming
        theme: MainTheme
      """, with: "")
    assertThrows(noTarget, contains: "declare at least one of 'swift:' or 'kotlin:'")
  }

  func testAKotlinOnlyConfigEmitsOnlyKotlinFiles() throws {
    let kotlinOnly = minimal
      .replacingOccurrences(of: """
        swift:
          output: Sources/Theming/Generated
          engine: DuetTheming
          theme: MainTheme
        """, with: """
        kotlin:
          output: src/commonMain/kotlin/app/theming
          package: app.theming
          engine: dev.modaal.duet.services.theming
          palette: MainPalette
        """)
      .replacingOccurrences(of: """
                swift:
                  textStyle: body
        """, with: "")
    let config = try DesignTokenConfig.parse(kotlinOnly, path: "design-tokens.yaml")
    let files = DesignTokensEmitter.emit(config: config)
    XCTAssertEqual(files.map(\.path), [
      "src/commonMain/kotlin/app/theming/SemanticColor.kt",
      "src/commonMain/kotlin/app/theming/SemanticFont.kt",
      "src/commonMain/kotlin/app/theming/MainPalette.kt",
    ], "no gradients declared, and no Swift target")
  }

  // MARK: - The verb

  func testRepoWithNoConfigGeneratesNothingAndPasses() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("duet-design-tokens-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("parity/fixtures"), withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    XCTAssertNil(try DesignTokenConfig.load(repo: Repo(root: root)))
  }

  func testCheckIsGreenRightAfterGeneration() throws {
    let repo = try makeRepo(config: try goldenConfigText())
    let config = try XCTUnwrap(try DesignTokenConfig.load(repo: repo))
    let written = try DesignTokensVerb.regenerate(repo: repo, config: config, check: false)
    XCTAssertEqual(written.written.count, 8)
    XCTAssertFalse(written.failed)

    let checked = try DesignTokensVerb.regenerate(repo: repo, config: config, check: true)
    XCTAssertEqual(checked.upToDate, 8)
    XCTAssertFalse(checked.failed)
  }

  func testCheckNamesAHandEditedFile() throws {
    let repo = try makeRepo(config: try goldenConfigText())
    let config = try XCTUnwrap(try DesignTokenConfig.load(repo: repo))
    _ = try DesignTokensVerb.regenerate(repo: repo, config: config, check: false)

    let edited = repo.root.appendingPathComponent(
      "src-kmp/theming/src/commonMain/kotlin/com/example/theming/Generated/MainPalette.kt")
    let text = try String(contentsOf: edited, encoding: .utf8)
      .replacingOccurrences(of: "0xFF1A1A1A", with: "0xFF000000")
    try Data(text.utf8).write(to: edited)

    let checked = try DesignTokensVerb.regenerate(repo: repo, config: config, check: true)
    XCTAssertEqual(checked.stale, [
      "src-kmp/theming/src/commonMain/kotlin/com/example/theming/Generated/MainPalette.kt"
    ])
    XCTAssertTrue(checked.failed)
  }

  /// The staleness pair's other half: editing the config leaves every file it
  /// touches stale until the generator runs again.
  func testCheckNamesFilesLeftBehindByAConfigEdit() throws {
    let repo = try makeRepo(config: try goldenConfigText())
    _ = try DesignTokensVerb.regenerate(
      repo: repo, config: try XCTUnwrap(try DesignTokenConfig.load(repo: repo)), check: false)

    let configURL = DesignTokenConfig.url(in: repo)
    let edited = try String(contentsOf: configURL, encoding: .utf8)
      .replacingOccurrences(of: ##"light: "#1A1A1A""##, with: ##"light: "#010203""##)
    try Data(edited.utf8).write(to: configURL)

    let checked = try DesignTokensVerb.regenerate(
      repo: repo, config: try XCTUnwrap(try DesignTokenConfig.load(repo: repo)), check: true)
    XCTAssertEqual(checked.stale.count, 2, "both palettes carry the value")
    XCTAssertTrue(checked.stale.contains { $0.hasSuffix("MainThemePalette.swift") })
    XCTAssertTrue(checked.stale.contains { $0.hasSuffix("MainPalette.kt") })
  }

  /// A vocabulary dropped from the config leaves a file behind that still
  /// compiles, so the check reports it by name rather than by silence.
  func testCheckReportsAFileTheConfigNoLongerDeclares() throws {
    let repo = try makeRepo(config: try goldenConfigText())
    _ = try DesignTokensVerb.regenerate(
      repo: repo, config: try XCTUnwrap(try DesignTokenConfig.load(repo: repo)), check: false)

    let configURL = DesignTokenConfig.url(in: repo)
    var text = try String(contentsOf: configURL, encoding: .utf8)
    text = String(text[text.startIndex..<text.range(of: "gradients:")!.lowerBound])
    try Data(text.utf8).write(to: configURL)

    let checked = try DesignTokensVerb.regenerate(
      repo: repo, config: try XCTUnwrap(try DesignTokenConfig.load(repo: repo)), check: true)
    XCTAssertEqual(checked.orphans, [
      "src-ios/Sources/Theming/Generated/SemanticGradient.swift",
      "src-kmp/theming/src/commonMain/kotlin/com/example/theming/Generated/SemanticGradient.kt",
    ])
    XCTAssertTrue(checked.failed)
  }
}
