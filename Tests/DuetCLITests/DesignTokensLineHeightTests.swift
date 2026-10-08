// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import XCTest

@testable import DuetCLI

/// A text style's face line height: the Swift, Kotlin and JSON targets carry
/// the declared line height, and `tokens.css` writes the face's where the
/// declared one is under it.
final class DesignTokensLineHeightTests: XCTestCase {
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

  private static let fixtureFiles = [
    "design-tokens.yaml",
    "design-tokens.resolver.json",
    "design-tokens/color.light.tokens.json",
    "design-tokens/color.dark.tokens.json",
    "design-tokens/type.tokens.json",
    "design-tokens/gradient.tokens.json",
  ]

  private static let type = "parity/design-tokens/type.tokens.json"

  /// A repo holding the DTCG fixture under `parity/`.
  private func dtcgRepo() throws -> Repo {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("duet-line-height-\(UUID().uuidString)")
    for name in Self.fixtureFiles {
      let target = root.appendingPathComponent("parity/\(name)")
      try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: try resource("tokens/dtcg/\(name)"), to: target)
    }
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return Repo(root: root)
  }

  private func read(_ repo: Repo, _ path: String) throws -> JSON {
    let text = try String(contentsOf: repo.root.appendingPathComponent(path), encoding: .utf8)
    return try DTCGSource.parseJSON(text, path: path)
  }

  private func write(_ repo: Repo, _ path: String, _ value: JSON) throws {
    try Data(DesignTokensJSON.render(value).utf8).write(to: repo.root.appendingPathComponent(path))
  }

  /// *value* with the member at *path* replaced, a missing member appended.
  private func setting(_ value: JSON, _ path: [String], to new: JSON) -> JSON {
    guard let key = path.first, case var .object(pairs) = value else { return value }
    let index = pairs.firstIndex { $0.0 == key }
    if path.count == 1 {
      if let index { pairs[index].1 = new } else { pairs.append((key, new)) }
      return .object(pairs)
    }
    guard let index else {
      pairs.append((key, setting(.object([]), Array(path.dropFirst()), to: new)))
      return .object(pairs)
    }
    pairs[index].1 = setting(pairs[index].1, Array(path.dropFirst()), to: new)
    return .object(pairs)
  }

  private func edit(_ repo: Repo, _ path: [String], to new: JSON) throws {
    try write(repo, Self.type, setting(try read(repo, Self.type), path, to: new))
  }

  /// A TrueType file holding only a `head` and an `hhea` table: what the
  /// face measure reads.
  static func font(unitsPerEm: Int, ascender: Int, descender: Int, lineGap: Int = 0) -> Data {
    var bytes: [UInt8] = []
    func u16(_ value: Int) { bytes += [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }
    func u32(_ value: Int) { u16(value >> 16); u16(value & 0xFFFF) }
    u32(0x0001_0000); u16(2); u16(32); u16(1); u16(0)
    let head = 12 + 2 * 16
    let hhea = head + 54
    for (tag, offset, length) in [("head", head, 54), ("hhea", hhea, 36)] {
      bytes += Array(tag.utf8); u32(0); u32(offset); u32(length)
    }
    var headTable = [UInt8](repeating: 0, count: 54)
    headTable[18] = UInt8(unitsPerEm >> 8)
    headTable[19] = UInt8(unitsPerEm & 0xFF)
    bytes += headTable
    var hheaTable = [UInt8](repeating: 0, count: 36)
    for (at, value) in [(4, ascender), (6, descender), (8, lineGap)] {
      let raw = value < 0 ? value + 0x10000 : value
      hheaTable[at] = UInt8(raw >> 8)
      hheaTable[at + 1] = UInt8(raw & 0xFF)
    }
    bytes += hheaTable
    return Data(bytes)
  }

  /// The fixture with its serif family drawn from *font* at
  /// `fonts/Serif.ttf`, a variable file covering every weight.
  private func repoWithSerifFile(_ font: Data) throws -> Repo {
    let repo = try dtcgRepo()
    let url = repo.root.appendingPathComponent("fonts/Serif.ttf")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try font.write(to: url)
    try edit(repo, ["fontFamily", "serif", "$extensions"], to: .object([
      (DTCGSource.extensionKey, .object([
        ("files", .array([.object([("path", .string("fonts/Serif.ttf")), ("weight", .array([.number(100), .number(900)]))])])),
      ])),
    ]))
    return repo
  }

  private func load(_ repo: Repo) throws -> DesignTokenConfig {
    try XCTUnwrap(try DesignTokenConfig.load(repo: repo))
  }

  private func token(_ config: DesignTokenConfig, _ style: String) throws -> DesignTokenConfig.FontToken {
    try XCTUnwrap(config.fontTokens.first { $0.name == style })
  }

  /// *css*'s rule for the font class of *style*.
  private func rule(_ css: String, _ style: String) throws -> String {
    let start = try XCTUnwrap(css.range(of: ".\(DesignTokensCSSEmitter.fontClass(style)) {"))
    let end = try XCTUnwrap(css.range(of: "}", range: start.upperBound..<css.endIndex))
    return String(css[start.lowerBound..<end.upperBound])
  }

  // MARK: - Reading a face

  func testTheLineHeightPerEmIsTheHheaAscenderDescenderAndGapOverUnitsPerEm() {
    XCTAssertEqual(DesignTokenLineHeights.perEm(Self.font(unitsPerEm: 2000, ascender: 1470, descender: -530)), 1.0)
    XCTAssertEqual(DesignTokenLineHeights.perEm(Self.font(unitsPerEm: 1000, ascender: 970, descender: -250)), 1.22)
    XCTAssertEqual(
      DesignTokenLineHeights.perEm(Self.font(unitsPerEm: 2048, ascender: 1900, descender: -500, lineGap: 48)),
      2448.0 / 2048.0)
  }

  func testAFileThatIsNotTrueTypeOrOpenTypeIsNotRead() {
    XCTAssertNil(DesignTokenLineHeights.perEm(Data("wOF2".utf8) + Data(count: 64)))
    XCTAssertNil(DesignTokenLineHeights.perEm(Data()))
  }

  func testAWeightReadsTheVariableFileHoldingItElseTheNearestStaticFile() {
    func file(_ name: String, _ weight: String) -> DesignTokenConfig.FontFile {
      .init(source: name, weight: weight, data: Data())
    }
    let mixed = DesignTokenConfig.FontFace(
      family: .serif, name: "Face", files: [file("Regular.ttf", "400"), file("Medium.ttf", "500"), file("Var.ttf", "600 800")])
    XCTAssertEqual(DesignTokenLineHeights.file(for: 700, in: mixed)?.source, "Var.ttf")
    XCTAssertEqual(DesignTokenLineHeights.file(for: 500, in: mixed)?.source, "Medium.ttf")
    XCTAssertEqual(DesignTokenLineHeights.file(for: 300, in: mixed)?.source, "Regular.ttf")
    XCTAssertEqual(DesignTokenLineHeights.file(for: 900, in: mixed)?.source, "Var.ttf")
  }

  // MARK: - Face line heights

  func testTheGoldenConfigsHaveNoStyleUnderItsFace() throws {
    let yaml = try DesignTokenConfig.parse(
      try String(contentsOf: try resource("tokens/design-tokens.yaml"), encoding: .utf8),
      path: DesignTokenConfig.relativePath)
    let yamlFaces = DesignTokenLineHeights.faces(yaml)
    XCTAssertEqual(yamlFaces.unmeasured, [], "the YAML grammar's families are the system faces")
    for token in yaml.fontTokens {
      XCTAssertEqual(DesignTokenLineHeights.webLineHeight(token, yamlFaces), token.lineHeight, token.name)
    }
    let dtcg = try load(try dtcgRepo())
    let dtcgFaces = DesignTokenLineHeights.faces(dtcg)
    XCTAssertEqual(dtcgFaces.unmeasured, [.serif], "the serif stack starts with a face no file holds")
    for token in dtcg.fontTokens {
      XCTAssertEqual(DesignTokenLineHeights.webLineHeight(token, dtcgFaces), token.lineHeight, token.name)
    }
  }

  func testOnlyTheWebTargetWritesTheFacesLineHeightForAStyleUnderIt() throws {
    // 1.3 em: largeTitle (34/41) and title2 (22/28) sit under it, the body
    // styles (17/26) above it.
    let config = try load(try repoWithSerifFile(Self.font(unitsPerEm: 1000, ascender: 1000, descender: -300)))
    let faces = DesignTokenLineHeights.faces(config)
    XCTAssertEqual(faces.unmeasured, [])
    XCTAssertEqual(faces.heights["largeTitle"], 44.2)
    XCTAssertEqual(faces.heights["title2"], 28.6)
    XCTAssertEqual(try token(config, "largeTitle").lineHeight, 41, "the config keeps the declared value")
    let files = DesignTokensEmitter.emit(config: config)
    func content(_ suffix: String) throws -> String {
      try XCTUnwrap(files.first { $0.path.hasSuffix(suffix) }).content
    }
    let css = try content("tokens.css")
    XCTAssertEqual(try rule(css, "largeTitle").components(separatedBy: "\n").filter { $0.contains("line-height") || $0.contains("/*") }, [
      "  /* the face's own line height; the token declares 41px */",
      "  line-height: 44.2px;",
    ])
    XCTAssertTrue(try rule(css, "title2").contains("line-height: 28.6px;"))
    XCTAssertTrue(try rule(css, "bodyRegular").contains("line-height: 26px;"))
    XCTAssertFalse(try rule(css, "bodyRegular").contains("/*"), "a style at or above its face carries no comment")
    XCTAssertTrue(try content("MainThemePalette.swift").contains("lineHeight: 41,"))
    XCTAssertFalse(try content("MainThemePalette.swift").contains("44.2"))
    XCTAssertTrue(try content("MainPalette.kt").contains("lineHeightSp = 41.0,"))
    XCTAssertFalse(try content("MainPalette.kt").contains("44.2"))
    XCTAssertTrue(try content("tokens.json").contains("\"lineHeight\": 41"))
    XCTAssertFalse(try content("tokens.json").contains("44.2"))
  }

  func testTheFacesLineHeightRoundsUpToAHundredthWithoutBinaryNoise() throws {
    // 34 × 1.22 is 41.480000000000004 in binary; the face's line height is 41.48.
    let config = try load(try repoWithSerifFile(Self.font(unitsPerEm: 1000, ascender: 970, descender: -250)))
    XCTAssertEqual(DesignTokenLineHeights.faces(config).heights["largeTitle"], 41.48)
  }

  func testASystemFirstFaceIsMeasuredByTheSystemFacesLineHeight() throws {
    let repo = try dtcgRepo()
    // headline: sans (-apple-system) at 17 with a line height of 17.
    try edit(repo, ["typography", "Chrome — the sans face", "headline", "$value", "lineHeight"], to: .number(1))
    let config = try load(repo)
    let faces = DesignTokenLineHeights.faces(config)
    XCTAssertEqual(faces.heights["headline"], 20.29, "17 × 1.1934 = 20.2878")
    XCTAssertEqual(DesignTokenLineHeights.webLineHeight(try token(config, "headline"), faces), 20.29)
    XCTAssertEqual(try token(config, "headline").lineHeight, 17)
  }

  func testAnUnmeasuredFaceIsWrittenAsDeclaredAndNamed() throws {
    let config = try load(try dtcgRepo())
    let faces = DesignTokenLineHeights.faces(config)
    for token in config.fontTokens where token.family == .serif {
      XCTAssertNil(faces.heights[token.name], token.name)
      XCTAssertEqual(DesignTokenLineHeights.webLineHeight(token, faces), token.lineHeight, token.name)
    }
    let notices = DesignTokenLineHeights.notices(faces, config: config)
    XCTAssertEqual(notices.count, 1)
    XCTAssertTrue(
      notices[0].hasPrefix("family 'serif': 'Source Serif 4' is in no font file this reads, so tokens.css writes"),
      notices[0])
    XCTAssertTrue(notices[0].contains(#"$extensions["dev.modaal.duet"].files"#), notices[0])
  }

  func testAStyleUnderItsFaceIsNotNamed() throws {
    let config = try load(try repoWithSerifFile(Self.font(unitsPerEm: 1000, ascender: 1000, descender: -300)))
    XCTAssertEqual(DesignTokenLineHeights.notices(DesignTokenLineHeights.faces(config), config: config), [])
  }

  // MARK: - The verb

  func testTheVerbWritesTheDeclaredLineHeightsAndTheWebOnesAndCheckPassesOnThem() throws {
    let repo = try repoWithSerifFile(Self.font(unitsPerEm: 1000, ascender: 1000, descender: -300))
    var options = Options()
    XCTAssertEqual(try DesignTokensVerb.run(repo: repo, options: options), 0)
    let css = try String(contentsOf: repo.root.appendingPathComponent("web/shared/tokens.css"), encoding: .utf8)
    XCTAssertTrue(css.contains("line-height: 44.2px;"))
    let swift = try String(
      contentsOf: repo.root.appendingPathComponent("src-ios/Sources/Theming/Generated/MainThemePalette.swift"),
      encoding: .utf8)
    XCTAssertTrue(swift.contains("lineHeight: 41,"))
    options.check = true
    XCTAssertEqual(try DesignTokensVerb.run(repo: repo, options: options), 0, "--check compares against the same output")
  }
}
