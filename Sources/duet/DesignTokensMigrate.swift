// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import Foundation
import Yams

/// `duet design-tokens migrate` — rewrites a version-1
/// `parity/design-tokens.yaml` as version 2: the tokens move into W3C Design
/// Tokens (DTCG 2025.10) files, and the config keeps the targets.
///
/// The files, under `parity/`:
/// - `design-tokens.resolver.json`: the resolver. One modifier, `appearance`,
///   whose `light` and `dark` contexts are the two colour files; one set,
///   `styles`, holding the type file and the gradient file.
/// - `design-tokens/color.light.tokens.json`, `color.dark.tokens.json`: every
///   colour, one file per appearance, each complete. A design tool that
///   imports one file per mode creates a variable only for a token present in
///   every file.
/// - `design-tokens/type.tokens.json`: the engine's three `fontFamily` tokens
///   and one `typography` token per font token.
/// - `design-tokens/gradient.tokens.json`: the gradients, each stop naming
///   the colour token it equals in both appearances. When a two-appearance
///   gradient has a stop no colour token matches, every gradient is written
///   into the colour files instead, with each appearance's own stops.
///
/// Values are written as the reader reads them back: sRGB components to four
/// decimals with `hex` beside them, sizes in `px`, line height as a multiple
/// of the size to six decimals, tracking as `px` at the token's size. The
/// generated Swift, Kotlin and CSS are unchanged by the migration except the
/// line naming their source.
enum DesignTokensMigrate {
  typealias JSON = DTCGSource.JSON

  static let resolverPath = "parity/design-tokens.resolver.json"
  static let tokensDirectory = "parity/design-tokens"

  struct Output {
    var files: [(path: String, content: String)]
  }

  enum Failure: Error, CustomStringConvertible {
    case refused(String)
    var description: String {
      switch self { case let .refused(message): return message }
    }
  }

  /// The engine's three families' stacks, matching the web target's defaults.
  static let defaultStacks: [String: [String]] = [
    "serif": ["ui-serif", "New York", "Georgia", "serif"],
    "sans": ["-apple-system", "BlinkMacSystemFont", "SF Pro Text", "system-ui", "Roboto", "sans-serif"],
    "mono": ["ui-monospace", "SF Mono", "Menlo", "monospace"],
  ]

  static let configHeader = """
    # The design-token generator config. The tokens themselves are W3C Design
    # Tokens (DTCG 2025.10) files: design-tokens.resolver.json names them, one
    # colour file per appearance, one for type, one for gradients.
    #
    # `duet design-tokens` reads the tokens and writes the targets below;
    # `duet design-tokens --check` fails while a generated file disagrees. Edit
    # values in the token files (or in a design tool that reads and writes
    # DTCG), regenerate, and commit the regenerated sources.

    """

  // MARK: - Values

  static func rounded(_ value: Double, _ places: Double) -> Double {
    DTCGSource.rounded(value, places)
  }

  static func color(_ value: DesignTokenConfig.ColorValue) -> JSON {
    let bytes = [(value.rgb >> 16) & 0xFF, (value.rgb >> 8) & 0xFF, value.rgb & 0xFF]
    var pairs: [(String, JSON)] = [
      ("colorSpace", .string("srgb")),
      ("components", .array(bytes.map { .number(rounded(Double($0) / 255, 4)) })),
    ]
    if value.alpha != 1 { pairs.append(("alpha", .number(value.alpha))) }
    pairs.append(("hex", .string(String(format: "#%06x", value.rgb))))
    return .object(pairs)
  }

  static func token(doc: String?, value: JSON, extensions: [(String, JSON)]) -> JSON {
    var pairs: [(String, JSON)] = []
    if let doc { pairs.append(("$description", .string(doc))) }
    pairs.append(("$value", value))
    if !extensions.isEmpty {
      pairs.append(("$extensions", .object([(DTCGSource.extensionKey, .object(extensions))])))
    }
    return .object(pairs)
  }

  static func note(_ text: String?) -> [(String, JSON)] {
    text.map { [("note", .string($0))] } ?? []
  }

  /// `-apple-system, "SF Pro Text", sans-serif` → its names.
  static func stackNames(_ stack: String) -> [String] {
    stack.split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
  }

  /// Appends *pairs* to a group's members, refusing a key it already has.
  static func add(_ key: String, _ value: JSON, to members: inout [(String, JSON)], in group: String) throws {
    guard !members.contains(where: { $0.0 == key }) else {
      throw Failure.refused("\(group): '\(key)' would be declared twice — a group heading and a token share a name, or a heading appears twice; rename one in the version-1 config first")
    }
    members.append((key, value))
  }

  // MARK: - The documents

  static func documents(_ config: DesignTokenConfig) throws -> Output {
    // Colours: one tree per appearance, each holding every colour.
    var light: [(String, JSON)] = [("$type", .string("color"))]
    var dark: [(String, JSON)] = [("$type", .string("color"))]
    /// Each colour's path and its two values, for the gradient stops.
    var colorPaths: [(path: String, light: DesignTokenConfig.ColorValue, dark: DesignTokenConfig.ColorValue)] = []
    for group in config.colors {
      var groupLight: [(String, JSON)] = []
      var groupDark: [(String, JSON)] = []
      for item in group.tokens {
        let (l, d): (DesignTokenConfig.ColorValue, DesignTokenConfig.ColorValue)
        switch item.appearance {
        case let .auto(a, b): (l, d) = (a, b)
        case let .fixed(value): (l, d) = (value, value)
        }
        let path = (["color"] + (group.name.map { [$0] } ?? []) + [item.name]).joined(separator: ".")
        colorPaths.append((path, l, d))
        let lightToken = token(doc: item.doc, value: color(l), extensions: note(item.note))
        let darkToken = token(doc: item.doc, value: color(d), extensions: note(item.note))
        if group.name == nil {
          try add(item.name, lightToken, to: &light, in: "color")
          try add(item.name, darkToken, to: &dark, in: "color")
        } else {
          try add(item.name, lightToken, to: &groupLight, in: "color.\(group.name!)")
          try add(item.name, darkToken, to: &groupDark, in: "color.\(group.name!)")
        }
      }
      if let name = group.name {
        try add(name, .object(groupLight), to: &light, in: "color")
        try add(name, .object(groupDark), to: &dark, in: "color")
      }
    }

    // Type: the engine's three families, then the typography tokens.
    var families: [(String, JSON)] = [("$type", .string("fontFamily"))]
    for family in DesignTokenConfig.FontFamily.allCases {
      let names = config.css?.families[family].map(stackNames) ?? defaultStacks[family.rawValue]!
      families.append((family.rawValue, .object([("$value", .array(names.map(JSON.string)))])))
    }
    var typography: [(String, JSON)] = [("$type", .string("typography"))]
    for group in config.fonts {
      var members: [(String, JSON)] = []
      for item in group.tokens {
        let value: JSON = .object([
          ("fontFamily", .string("{fontFamily.\(item.family.rawValue)}")),
          ("fontWeight", .number(Double(item.weight))),
          ("fontSize", .object([("value", .number(item.size)), ("unit", .string("px"))])),
          ("lineHeight", .number(rounded(item.lineHeight / item.size, 6))),
          ("letterSpacing", .object([("value", .number(rounded(item.tracking * item.size, 6))), ("unit", .string("px"))])),
        ])
        var extensions: [(String, JSON)] = []
        if let style = item.textStyle { extensions.append(("textStyle", .string(style))) }
        var axes: [(String, JSON)] = []
        if let v = item.opticalSize { axes.append(("opticalSize", .number(v))) }
        if let v = item.softness { axes.append(("softness", .number(v))) }
        if let v = item.width { axes.append(("width", .number(v))) }
        if !axes.isEmpty { extensions.append(("axes", .object(axes))) }
        extensions += note(item.note)
        let entry = token(doc: item.doc, value: value, extensions: extensions)
        if group.name == nil {
          try add(item.name, entry, to: &typography, in: "typography")
        } else {
          try add(item.name, entry, to: &members, in: "typography.\(group.name!)")
        }
      }
      if let name = group.name { try add(name, .object(members), to: &typography, in: "typography") }
    }
    let typeDoc: JSON = .object([("fontFamily", .object(families)), ("typography", .object(typography))])

    // Gradients: stops that name colour tokens in a shared file, or each
    // appearance's own stops in the colour files.
    func alias(_ l: DesignTokenConfig.ColorValue, _ d: DesignTokenConfig.ColorValue) -> String? {
      colorPaths.first { $0.light == l && $0.dark == d }.map { "{\($0.path)}" }
    }
    func stopList(_ values: [JSON]) -> JSON {
      .array(values.enumerated().map { index, value in
        .object([("color", value), ("position", .number(rounded(Double(index) / Double(values.count - 1), 6)))])
      })
    }
    var sharedGradients: [(String, JSON)] = [("$type", .string("gradient"))]
    var lightGradients: [(String, JSON)] = [("$type", .string("gradient"))]
    var darkGradients: [(String, JSON)] = [("$type", .string("gradient"))]
    var shared = true
    for item in config.gradients {
      let (l, d): ([DesignTokenConfig.ColorValue], [DesignTokenConfig.ColorValue])
      switch item.appearance {
      case let .auto(a, b): (l, d) = (a, b)
      case let .fixed(values): (l, d) = (values, values)
      }
      let stops: [JSON?] = zip(l, d).map { a, b in
        if let name = alias(a, b) { return .string(name) }
        return a == b ? color(a) : nil
      }
      if stops.contains(where: { $0 == nil }) { shared = false }
      let extensions = note(item.note)
      if stops.allSatisfy({ $0 != nil }) {
        sharedGradients.append((item.name, token(doc: item.doc, value: stopList(stops.map { $0! }), extensions: extensions)))
      }
      lightGradients.append((item.name, token(doc: item.doc, value: stopList(l.map(color)), extensions: extensions)))
      darkGradients.append((item.name, token(doc: item.doc, value: stopList(d.map(color)), extensions: extensions)))
    }
    let gradientFile = !config.gradients.isEmpty && shared

    var lightDoc: [(String, JSON)] = [("color", .object(light))]
    var darkDoc: [(String, JSON)] = [("color", .object(dark))]
    if !config.gradients.isEmpty, !shared {
      lightDoc.append(("gradient", .object(lightGradients)))
      darkDoc.append(("gradient", .object(darkGradients)))
    }

    var styles: [JSON] = [.object([("$ref", .string("design-tokens/type.tokens.json"))])]
    if gradientFile { styles.append(.object([("$ref", .string("design-tokens/gradient.tokens.json"))])) }
    let resolver: JSON = .object([
      ("$schema", .string("https://www.designtokens.org/schemas/2025.10/resolver.json")),
      ("name", .string("App design tokens")),
      ("version", .string(DTCGSource.formatVersion)),
      ("sets", .object([("styles", .object([("sources", .array(styles))]))])),
      ("modifiers", .object([("appearance", .object([
        ("description", .string("The system appearance: one colour file per appearance, each with every colour.")),
        ("contexts", .object([
          ("light", .array([.object([("$ref", .string("design-tokens/color.light.tokens.json"))])])),
          ("dark", .array([.object([("$ref", .string("design-tokens/color.dark.tokens.json"))])])),
        ])),
        ("default", .string("light")),
      ]))])),
      ("resolutionOrder", .array([
        .object([("$ref", .string("#/modifiers/appearance"))]),
        .object([("$ref", .string("#/sets/styles"))]),
      ])),
    ])

    var files: [(String, String)] = [
      (resolverPath, DesignTokensJSON.render(resolver)),
      ("\(tokensDirectory)/color.light.tokens.json", DesignTokensJSON.render(.object(lightDoc))),
      ("\(tokensDirectory)/color.dark.tokens.json", DesignTokensJSON.render(.object(darkDoc))),
      ("\(tokensDirectory)/type.tokens.json", DesignTokensJSON.render(typeDoc)),
    ]
    if gradientFile {
      files.append(("\(tokensDirectory)/gradient.tokens.json",
                    DesignTokensJSON.render(.object([("gradient", .object(sharedGradients))]))))
    }
    files.append((DesignTokenConfig.relativePath, configText(config)))
    return Output(files: files)
  }

  // MARK: - The version-2 config

  /// A plain YAML scalar, double-quoted when a plain one would misread.
  static func yamlScalar(_ text: String) -> String {
    let special = CharacterSet(charactersIn: "[]{},&*!|>'\"%@`#?:-")
    let needsQuotes = text.isEmpty || text.contains(": ") || text.contains(" #")
      || text.unicodeScalars.first.map(special.contains) == true
      || text.hasSuffix(":") || text != text.trimmingCharacters(in: .whitespaces)
    guard needsQuotes else { return text }
    return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
  }

  static func configText(_ config: DesignTokenConfig) -> String {
    var lines = [
      "version: \(DesignTokenConfig.dtcgVersion)",
      "tokens: design-tokens.resolver.json",
    ]
    if let target = config.swift {
      lines += ["", "swift:",
                "  output: \(yamlScalar(target.output))",
                "  engine: \(yamlScalar(target.engine))",
                "  theme: \(yamlScalar(target.theme))"]
    }
    if let target = config.kotlin {
      lines += ["", "kotlin:",
                "  output: \(yamlScalar(target.output))",
                "  package: \(yamlScalar(target.package))",
                "  engine: \(yamlScalar(target.engine))",
                "  palette: \(yamlScalar(target.palette))"]
    }
    if let target = config.css {
      lines += ["", "css:", "  output: \(yamlScalar(target.output))"]
    }
    return configHeader + "\n" + lines.joined(separator: "\n") + "\n"
  }

  // MARK: - The verb

  static func run(repo: Repo, options: Options) throws -> Int32 {
    let configURL = DesignTokenConfig.url(in: repo)
    func refuse(_ message: String) -> Int32 {
      if options.json {
        Lanes.emitJSON(["status": "failed", "config": DesignTokenConfig.relativePath, "error": message, "written": [String]()])
      } else {
        FileHandle.standardError.write(Data("duet design-tokens migrate: \(message)\n".utf8))
      }
      return 1
    }
    guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
      return refuse("no \(DesignTokenConfig.relativePath) — nothing to migrate")
    }
    if let root = (try? Yams.load(yaml: text)) as? [String: Any], root["version"] as? Int == DesignTokenConfig.dtcgVersion {
      return refuse("\(DesignTokenConfig.relativePath) is already version \(DesignTokenConfig.dtcgVersion)")
    }
    let config: DesignTokenConfig
    do {
      config = try DesignTokenConfig.parse(text, path: DesignTokenConfig.relativePath)
    } catch {
      return refuse("\(error)")
    }
    let output: Output
    do {
      output = try documents(config)
    } catch {
      return refuse("\(error)")
    }
    for (path, _) in output.files where path != DesignTokenConfig.relativePath {
      if FileManager.default.fileExists(atPath: repo.root.appendingPathComponent(path).path) {
        return refuse("\(path) already exists — move it aside, or delete it, and run migrate again")
      }
    }
    for (path, content) in output.files {
      let url = repo.root.appendingPathComponent(path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(content.utf8).write(to: url)
    }
    let written = output.files.map(\.path)
    if options.json {
      Lanes.emitJSON(["status": "passed", "config": DesignTokenConfig.relativePath, "written": written])
    } else {
      print("duet design-tokens migrate: wrote \(written.count) file(s):")
      for path in written { print("  \(path)") }
      print("the config's comments were not carried over; run `duet design-tokens`, then review and commit")
    }
    return 0
  }
}
