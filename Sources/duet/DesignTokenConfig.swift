// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import Foundation
import Yams

/// The design-token master — `parity/design-tokens.yaml`, the one input
/// `duet design-tokens` generates both languages' token sources from (grammar in
/// contracts/design-tokens.md).
///
/// Read with a real YAML engine rather than the manifest's hand-rolled line
/// parser: the config nests lists of maps and carries folded block scalars for
/// every token's prose, which is where a line parser gets a paragraph subtly
/// wrong. Strictness is kept at the schema layer instead — every key is
/// checked against the known set for its position, and an unknown one is an
/// error naming the token it sits on, so a misspelled `lightAlpha` cannot
/// silently drop an alpha channel.
struct DesignTokenConfig {
  /// The schema this document declares. Bumped when a change would make an
  /// older toolchain misread a config, never for an added optional key.
  static let currentVersion = 1

  struct SwiftTarget {
    /// Repo-relative directory the generated Swift files are written to.
    var output: String
    /// The theming module the generated files import (`DuetTheming`).
    var engine: String
    /// The `Assetable` type the value tables extend (`MainTheme`).
    var theme: String
  }

  struct KotlinTarget {
    var output: String
    /// The package the generated declarations live in.
    var package: String
    /// The engine package the value types are imported from.
    var engine: String
    /// The object the value tables are emitted into (`MainPalette`).
    var palette: String
  }

  /// One colour literal: 24-bit RGB plus an alpha in 0…1. Alpha is carried as
  /// the fraction the Apple table states rather than the byte the Kotlin table
  /// stores, because the fraction is the authored value — the byte is derived
  /// from it and rounding it back loses the author's number.
  struct ColorValue: Equatable {
    var rgb: UInt32
    var alpha: Double

    /// `0xAARRGGBB`, the form the Kotlin palette carries.
    var argb: UInt32 { (UInt32((alpha * 255).rounded()) << 24) | rgb }
  }

  enum ColorAppearance: Equatable {
    /// Separate values per appearance.
    case auto(light: ColorValue, dark: ColorValue)
    /// One value in both appearances.
    case fixed(ColorValue)
  }

  enum FontFamily: String, CaseIterable {
    case serif, sans, mono

    /// The engine enum's entry spelling.
    var kotlinEntry: String {
      switch self {
      case .serif: return "Serif"
      case .sans: return "Sans"
      case .mono: return "Mono"
      }
    }
  }

  struct ColorToken {
    var name: String
    var doc: String?
    var note: String?
    var appearance: ColorAppearance
  }

  struct FontToken {
    var name: String
    var doc: String?
    var note: String?
    var family: FontFamily
    var weight: Int
    var size: Double
    var lineHeight: Double
    /// Tracking as a fraction of the em; 0 when the token names none.
    var tracking: Double
    /// The `opsz` axis, on families that carry it.
    var opticalSize: Double?
    /// The `SOFT` axis, on families that carry it.
    var softness: Double?
    /// The `wdth` axis, on families that carry it.
    var width: Double?
    /// `UIFont.TextStyle` the cut scales against — the one column only the
    /// Apple side expresses, required whenever a `swift:` target is declared.
    var textStyle: String?
  }

  /// How a gradient's stops answer the appearance. Mirrors `ColorAppearance`:
  /// one list of stops for both appearances, or a list per appearance.
  enum GradientAppearance: Equatable {
    case auto(light: [ColorValue], dark: [ColorValue])
    case fixed([ColorValue])
  }

  struct GradientToken {
    var name: String
    var doc: String?
    var note: String?
    var appearance: GradientAppearance
  }

  /// A run of tokens under one heading. The heading is emitted as a section
  /// comment in both languages' vocabulary and value files, which is what
  /// keeps the two trees' grouping one decision instead of two.
  struct Group<Token> {
    var name: String?
    var tokens: [Token]
  }

  var version: Int
  var swift: SwiftTarget?
  var kotlin: KotlinTarget?
  var colors: [Group<ColorToken>]
  var fonts: [Group<FontToken>]
  var gradients: [GradientToken]

  var colorTokens: [ColorToken] { colors.flatMap(\.tokens) }
  var fontTokens: [FontToken] { fonts.flatMap(\.tokens) }
}

enum DesignTokenConfigError: Error, CustomStringConvertible {
  case unreadable(path: String, reason: String)
  case malformed(path: String, message: String)

  var description: String {
    switch self {
    case let .unreadable(path, reason):
      return "\(path): \(reason)"
    case let .malformed(path, message):
      return "\(path): \(message)"
    }
  }
}

extension DesignTokenConfig {
  /// Repo-relative path of the config — fixed, like `parity/manifest.yaml` and
  /// `parity/mutations.json`. Nothing routes to it, so a repo either has a
  /// token master or has none.
  static let relativePath = "parity/design-tokens.yaml"

  static func url(in repo: Repo) -> URL {
    repo.root.appendingPathComponent(relativePath)
  }

  /// Loads and validates the config. Returns nil when the repo declares none.
  static func load(repo: Repo) throws -> DesignTokenConfig? {
    let file = url(in: repo)
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    let text: String
    do {
      text = try String(contentsOf: file, encoding: .utf8)
    } catch {
      throw DesignTokenConfigError.unreadable(path: relativePath, reason: "\(error)")
    }
    return try parse(text, path: relativePath)
  }

  static func parse(_ text: String, path: String) throws -> DesignTokenConfig {
    let loaded: Any?
    do {
      loaded = try Yams.load(yaml: text)
    } catch {
      throw DesignTokenConfigError.malformed(path: path, message: "not valid YAML — \(error)")
    }
    guard let root = loaded as? [String: Any] else {
      throw DesignTokenConfigError.malformed(path: path, message: "the document must be a map")
    }
    let reader = Reader(path: path)
    return try reader.config(root)
  }

  /// The strict schema walk. Every `keys(…)` call states the whole key set for
  /// its position, so an unknown key is caught where it sits rather than
  /// ignored.
  private struct Reader {
    let path: String

    func fail(_ message: String) -> DesignTokenConfigError {
      DesignTokenConfigError.malformed(path: path, message: message)
    }

    func keys(_ map: [String: Any], known: Set<String>, at where_: String) throws {
      for key in map.keys.sorted() where !known.contains(key) {
        throw fail("\(where_): unknown key '\(key)' (known: \(known.sorted().joined(separator: ", ")))")
      }
    }

    func string(_ map: [String: Any], _ key: String, at where_: String) throws -> String {
      guard let value = map[key] else { throw fail("\(where_): missing '\(key)'") }
      guard let text = value as? String, !text.isEmpty else {
        throw fail("\(where_): '\(key)' must be a non-empty string")
      }
      return text
    }

    func optionalString(_ map: [String: Any], _ key: String, at where_: String) throws -> String? {
      guard let value = map[key] else { return nil }
      guard let text = value as? String, !text.isEmpty else {
        throw fail("\(where_): '\(key)' must be a non-empty string")
      }
      return text
    }

    func number(_ map: [String: Any], _ key: String, at where_: String) throws -> Double {
      guard let value = map[key] else { throw fail("\(where_): missing '\(key)'") }
      if let double = value as? Double { return double }
      if let int = value as? Int { return Double(int) }
      throw fail("\(where_): '\(key)' must be a number")
    }

    func optionalNumber(_ map: [String: Any], _ key: String, at where_: String) throws -> Double? {
      guard map[key] != nil else { return nil }
      return try number(map, key, at: where_)
    }

    func map(_ value: Any, at where_: String) throws -> [String: Any] {
      guard let map = value as? [String: Any] else { throw fail("\(where_): expected a map") }
      return map
    }

    func list(_ map: [String: Any], _ key: String, at where_: String) throws -> [Any] {
      guard let value = map[key] else { return [] }
      guard let list = value as? [Any] else { throw fail("\(where_): '\(key)' must be a list") }
      return list
    }

    /// `#RRGGBB`, the one colour literal form. Six hex digits, always hashed —
    /// so a value reads the same in the config as in a design tool.
    func hex(_ text: String, at where_: String) throws -> UInt32 {
      guard text.hasPrefix("#") else {
        throw fail("\(where_): colour '\(text)' must start with '#'")
      }
      let digits = String(text.dropFirst())
      guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
        throw fail("\(where_): colour '\(text)' must be '#RRGGBB' — six hex digits")
      }
      return value
    }

    func alpha(_ map: [String: Any], _ key: String, at where_: String) throws -> Double {
      guard let value = try optionalNumber(map, key, at: where_) else { return 1 }
      guard value >= 0, value <= 1 else {
        throw fail("\(where_): '\(key)' must be between 0 and 1")
      }
      return value
    }

    func config(_ root: [String: Any]) throws -> DesignTokenConfig {
      try keys(root, known: ["version", "swift", "kotlin", "colors", "fonts", "gradients"],
               at: "top level")
      guard let version = root["version"] as? Int else {
        throw fail("top level: missing 'version' (this toolchain reads version \(DesignTokenConfig.currentVersion))")
      }
      guard version == DesignTokenConfig.currentVersion else {
        throw fail("version \(version) is not a schema this toolchain reads (it reads version \(DesignTokenConfig.currentVersion))")
      }

      var swiftTarget: DesignTokenConfig.SwiftTarget?
      if let raw = root["swift"] {
        let block = try map(raw, at: "swift")
        try keys(block, known: ["output", "engine", "theme"], at: "swift")
        swiftTarget = .init(
          output: try string(block, "output", at: "swift"),
          engine: try string(block, "engine", at: "swift"),
          theme: try string(block, "theme", at: "swift"))
      }
      var kotlinTarget: DesignTokenConfig.KotlinTarget?
      if let raw = root["kotlin"] {
        let block = try map(raw, at: "kotlin")
        try keys(block, known: ["output", "package", "engine", "palette"], at: "kotlin")
        kotlinTarget = .init(
          output: try string(block, "output", at: "kotlin"),
          package: try string(block, "package", at: "kotlin"),
          engine: try string(block, "engine", at: "kotlin"),
          palette: try string(block, "palette", at: "kotlin"))
      }
      guard swiftTarget != nil || kotlinTarget != nil else {
        throw fail("declare at least one of 'swift:' or 'kotlin:' — a config with neither generates nothing")
      }

      let colors = try colorGroups(root)
      let fonts = try fontGroups(root, requireTextStyle: swiftTarget != nil)
      let gradients = try gradientTokens(root)

      try assertUniqueNames(colors.flatMap(\.tokens).map(\.name), vocabulary: "colors")
      try assertUniqueNames(fonts.flatMap(\.tokens).map(\.name), vocabulary: "fonts")
      try assertUniqueNames(gradients.map(\.name), vocabulary: "gradients")

      return DesignTokenConfig(version: version, swift: swiftTarget, kotlin: kotlinTarget,
                         colors: colors, fonts: fonts, gradients: gradients)
    }

    func assertUniqueNames(_ names: [String], vocabulary: String) throws {
      var seen = Set<String>()
      for name in names where !seen.insert(name).inserted {
        throw fail("\(vocabulary): '\(name)' is declared twice — a vocabulary entry is one case")
      }
    }

    /// A token name becomes an enum case in both languages, so it has to be a
    /// bare identifier in each.
    func tokenName(_ map: [String: Any], at where_: String) throws -> String {
      let name = try string(map, "name", at: where_)
      let first = name.first!
      let valid = first.isLetter && first.isLowercase
        && name.allSatisfy { $0.isLetter || $0.isNumber }
      guard valid else {
        throw fail("\(where_): '\(name)' must be lowerCamelCase letters and digits — it becomes an enum case in both languages")
      }
      return name
    }

    func colorGroups(_ root: [String: Any]) throws -> [DesignTokenConfig.Group<DesignTokenConfig.ColorToken>] {
      var groups: [DesignTokenConfig.Group<DesignTokenConfig.ColorToken>] = []
      for (index, raw) in try list(root, "colors", at: "top level").enumerated() {
        let block = try map(raw, at: "colors[\(index)]")
        try keys(block, known: ["group", "tokens"], at: "colors[\(index)]")
        let name = try optionalString(block, "group", at: "colors[\(index)]")
        var tokens: [DesignTokenConfig.ColorToken] = []
        for (tokenIndex, rawToken) in try list(block, "tokens", at: "colors[\(index)]").enumerated() {
          let position = "colors[\(index)].tokens[\(tokenIndex)]"
          let entry = try map(rawToken, at: position)
          let tokenName = try tokenName(entry, at: position)
          let at = "color '\(tokenName)'"
          try keys(entry,
                   known: ["name", "doc", "note", "light", "dark", "lightAlpha", "darkAlpha",
                           "value", "alpha"],
                   at: at)
          let appearance: DesignTokenConfig.ColorAppearance
          if let value = try optionalString(entry, "value", at: at) {
            for key in ["light", "dark", "lightAlpha", "darkAlpha"] where entry[key] != nil {
              throw fail("\(at): 'value' and '\(key)' are alternatives — 'value' is the one-value-in-both-appearances form")
            }
            appearance = .fixed(.init(rgb: try hex(value, at: at),
                                      alpha: try alpha(entry, "alpha", at: at)))
          } else {
            if entry["alpha"] != nil {
              throw fail("\(at): 'alpha' belongs to 'value'; the two-appearance form takes 'lightAlpha' and 'darkAlpha'")
            }
            let light = try string(entry, "light", at: at)
            let dark = try string(entry, "dark", at: at)
            appearance = .auto(
              light: .init(rgb: try hex(light, at: at), alpha: try alpha(entry, "lightAlpha", at: at)),
              dark: .init(rgb: try hex(dark, at: at), alpha: try alpha(entry, "darkAlpha", at: at)))
          }
          tokens.append(.init(name: tokenName,
                              doc: try optionalString(entry, "doc", at: at),
                              note: try optionalString(entry, "note", at: at),
                              appearance: appearance))
        }
        groups.append(.init(name: name, tokens: tokens))
      }
      return groups
    }

    func fontGroups(_ root: [String: Any], requireTextStyle: Bool) throws
      -> [DesignTokenConfig.Group<DesignTokenConfig.FontToken>]
    {
      var groups: [DesignTokenConfig.Group<DesignTokenConfig.FontToken>] = []
      for (index, raw) in try list(root, "fonts", at: "top level").enumerated() {
        let block = try map(raw, at: "fonts[\(index)]")
        try keys(block, known: ["group", "tokens"], at: "fonts[\(index)]")
        let name = try optionalString(block, "group", at: "fonts[\(index)]")
        var tokens: [DesignTokenConfig.FontToken] = []
        for (tokenIndex, rawToken) in try list(block, "tokens", at: "fonts[\(index)]").enumerated() {
          let position = "fonts[\(index)].tokens[\(tokenIndex)]"
          let entry = try map(rawToken, at: position)
          let tokenName = try tokenName(entry, at: position)
          let at = "font '\(tokenName)'"
          try keys(entry,
                   known: ["name", "doc", "note", "family", "weight", "size", "lineHeight",
                           "tracking", "opticalSize", "softness", "width", "swift"],
                   at: at)
          let familyName = try string(entry, "family", at: at)
          guard let family = DesignTokenConfig.FontFamily(rawValue: familyName) else {
            let allowed = DesignTokenConfig.FontFamily.allCases.map(\.rawValue).joined(separator: ", ")
            throw fail("\(at): family '\(familyName)' is not one of: \(allowed)")
          }
          var textStyle: String?
          if let rawSwift = entry["swift"] {
            let swiftBlock = try map(rawSwift, at: "\(at) swift:")
            try keys(swiftBlock, known: ["textStyle"], at: "\(at) swift:")
            textStyle = try string(swiftBlock, "textStyle", at: "\(at) swift:")
          }
          if requireTextStyle, textStyle == nil {
            throw fail("\(at): a 'swift:' target is declared, so the token needs 'swift: { textStyle: … }' — the Dynamic Type style its cut scales against")
          }
          let weight = try number(entry, "weight", at: at)
          guard weight == weight.rounded(), weight > 0 else {
            throw fail("\(at): 'weight' must be a positive whole number")
          }
          tokens.append(.init(
            name: tokenName,
            doc: try optionalString(entry, "doc", at: at),
            note: try optionalString(entry, "note", at: at),
            family: family,
            weight: Int(weight),
            size: try number(entry, "size", at: at),
            lineHeight: try number(entry, "lineHeight", at: at),
            tracking: try optionalNumber(entry, "tracking", at: at) ?? 0,
            opticalSize: try optionalNumber(entry, "opticalSize", at: at),
            softness: try optionalNumber(entry, "softness", at: at),
            width: try optionalNumber(entry, "width", at: at),
            textStyle: textStyle))
        }
        groups.append(.init(name: name, tokens: tokens))
      }
      return groups
    }

    /// One stop list: two or more `#RRGGBB` strings, opaque (a gradient's
    /// transparency is the surface's, not the stop's).
    func stops(_ entry: [String: Any], _ key: String, at: String) throws -> [DesignTokenConfig.ColorValue] {
      let raw = try list(entry, key, at: at)
      guard raw.count >= 2 else { throw fail("\(at): '\(key)' needs at least two colours") }
      return try raw.map { stop in
        guard let text = stop as? String else {
          throw fail("\(at): every entry in '\(key)' must be a '#RRGGBB' string")
        }
        return .init(rgb: try hex(text, at: at), alpha: 1)
      }
    }

    func gradientTokens(_ root: [String: Any]) throws -> [DesignTokenConfig.GradientToken] {
      var tokens: [DesignTokenConfig.GradientToken] = []
      for (index, raw) in try list(root, "gradients", at: "top level").enumerated() {
        let position = "gradients[\(index)]"
        let entry = try map(raw, at: position)
        let name = try tokenName(entry, at: position)
        let at = "gradient '\(name)'"
        try keys(entry, known: ["name", "doc", "note", "stops", "light", "dark"], at: at)
        let hasFixed = entry["stops"] != nil
        let hasSplit = entry["light"] != nil || entry["dark"] != nil
        guard hasFixed != hasSplit else {
          throw fail("\(at): declare either 'stops' or both 'light' and 'dark'")
        }
        let appearance: DesignTokenConfig.GradientAppearance
        if hasFixed {
          appearance = .fixed(try stops(entry, "stops", at: at))
        } else {
          guard entry["light"] != nil, entry["dark"] != nil else {
            throw fail("\(at): the two-appearance form needs both 'light' and 'dark'")
          }
          appearance = .auto(light: try stops(entry, "light", at: at),
                             dark: try stops(entry, "dark", at: at))
        }
        tokens.append(.init(name: name,
                            doc: try optionalString(entry, "doc", at: at),
                            note: try optionalString(entry, "note", at: at),
                            appearance: appearance))
      }
      return tokens
    }
  }
}
