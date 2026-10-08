// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import Foundation

/// The web target of `duet design-tokens`: the same tokens as the Swift and
/// Kotlin targets, as a stylesheet a web page links and a JSON manifest a tool
/// reads to list them.
///
/// - `tokens.css`: one custom property per colour (`--color-label-primary`)
///   and per gradient's stop list (`--gradient-background-hero`), the light
///   values on `:root` and the dark ones under
///   `@media (prefers-color-scheme: dark)`; one per spacing step
///   (`--spacing-m`) and corner radius (`--radius-card`) in px; one class per
///   font token (`.font-large-title`), whose `line-height` is at least the
///   face's own (`DesignTokenLineHeights`); and `--font-family-<family>` per
///   family.
/// - `tokens.json`: every token with its CSS name, its values per appearance as
///   CSS colour strings, its type metrics and its prose.
/// - `fonts/<file>`: a copy of each font file a family's `files` names, with
///   an `@font-face` rule for it at the top of `tokens.css`.
///
/// Names follow one rule, so a page and the app name a token alike: the
/// lowerCamelCase token name in kebab case, after a prefix per vocabulary.
enum DesignTokensCSSEmitter {
  static let fileNames = ["tokens.css", "tokens.json"]

  /// The stack a family resolves to when the config does not name one: the
  /// platform's system faces, which are what the Apple and Android resolvers
  /// pick for the same family when the app registers no face of its own.
  static let defaultFamilies: [DesignTokenConfig.FontFamily: String] = [
    .sans: "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", system-ui, Roboto, sans-serif",
    .serif: "ui-serif, \"New York\", Georgia, serif",
    .mono: "ui-monospace, \"SF Mono\", Menlo, monospace",
  ]

  static func emit(config: DesignTokenConfig, target: DesignTokenConfig.CSSTarget) -> [GeneratedDesignTokenFile] {
    var files = [
      GeneratedDesignTokenFile(path: "\(target.output)/tokens.css", content: stylesheet(config: config, target: target)),
      GeneratedDesignTokenFile(path: "\(target.output)/tokens.json", content: manifest(config: config, target: target)),
    ]
    for face in target.faces {
      for font in face.files {
        files.append(.init(path: "\(target.output)/fonts/\(font.fileName)", content: "", data: font.data))
      }
    }
    return files
  }

  /// One `@font-face` rule per copied font file.
  static func fontFaces(_ target: DesignTokenConfig.CSSTarget) -> [String] {
    var out: [String] = []
    for face in target.faces {
      for font in face.files {
        let format = font.format.map { " format(\"\($0)\")" } ?? ""
        out += [
          "@font-face {",
          "  font-family: \(face.name.contains(" ") ? "\"\(face.name)\"" : face.name);",
          "  src: url(\"fonts/\(font.fileName)\")\(format);",
          "  font-weight: \(font.weight);",
          "}",
          "",
        ]
      }
    }
    return out
  }

  // MARK: - Names and values

  /// `labelPrimary` → `label-primary`.
  static func kebab(_ name: String) -> String {
    var out = ""
    for character in name {
      if character.isUppercase {
        out += "-" + character.lowercased()
      } else {
        out.append(character)
      }
    }
    return out
  }

  static func colorProperty(_ name: String) -> String { "--color-\(kebab(name))" }
  static func gradientProperty(_ name: String) -> String { "--gradient-\(kebab(name))" }
  static func fontClass(_ name: String) -> String { "font-\(kebab(name))" }
  static func familyProperty(_ family: DesignTokenConfig.FontFamily) -> String { "--font-family-\(family.rawValue)" }
  static func spacingProperty(_ name: String) -> String { "--spacing-\(kebab(name))" }
  static func radiusProperty(_ name: String) -> String { "--radius-\(kebab(name))" }

  /// `#1A1A1A`, or `rgba(26, 26, 26, 0.2)` when the alpha is below 1: the
  /// authored fraction, not a rounded byte.
  static func cssColor(_ value: DesignTokenConfig.ColorValue) -> String {
    if value.alpha >= 1 { return String(format: "#%06X", value.rgb) }
    let r = (value.rgb >> 16) & 0xFF, g = (value.rgb >> 8) & 0xFF, b = value.rgb & 0xFF
    return "rgba(\(r), \(g), \(b), \(cssNumber(value.alpha)))"
  }

  static func cssNumber(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(value)
  }

  static func stops(_ values: [DesignTokenConfig.ColorValue]) -> String {
    values.map(cssColor).joined(separator: ", ")
  }

  static func family(_ family: DesignTokenConfig.FontFamily, target: DesignTokenConfig.CSSTarget) -> String {
    target.families[family] ?? defaultFamilies[family] ?? "system-ui, sans-serif"
  }

  // MARK: - tokens.css

  static func blockComment(_ text: String, indent: String) -> [String] {
    let lines = DesignTokensEmitter.comment(text, prefix: "   ", indent: indent)
    guard !lines.isEmpty else { return [] }
    var out = lines
    out[0] = indent + "/* " + out[0].dropFirst(indent.count + 3)
    out[out.count - 1] += " */"
    // A paragraph break is the bare indent; no line ends in whitespace.
    return out.map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? "" : $0 }
  }

  static func stylesheet(config: DesignTokenConfig, target: DesignTokenConfig.CSSTarget) -> String {
    // The scales are named only when the config has them, so a stylesheet
    // without them reads as it did.
    let scales = !config.spacing.isEmpty || !config.radii.isEmpty
    var out: [String] = [
      "/* GENERATED by `duet design-tokens` from \(config.source) —",
      "   do not edit. Change a value in the config and regenerate:",
      "   `duet design-tokens`. A hand-edit here fails `duet design-tokens --check`.",
      "",
      "   Colours: var(--color-<name>). Gradients: var(--gradient-<name>) is the",
      "   stop list; the surface picks the axis, as in",
      "   linear-gradient(180deg, var(--gradient-<name>)). Type: class=\"font-<name>\"." + (scales ? "" : " */"),
    ]
    if scales { out.append("   Spacing: var(--spacing-<name>). Corner radii: var(--radius-<name>). */") }
    out.append("")
    out += fontFaces(target)
    out += [
      ":root {",
      "  color-scheme: light dark;",
    ]
    for family in config.families {
      out.append("  \(familyProperty(family)): \(DesignTokensCSSEmitter.family(family, target: target));")
    }
    for group in config.colors {
      out.append("")
      if let name = group.name { out.append("  /* \(name) */") }
      for token in group.tokens {
        if let doc = token.doc { out += blockComment(doc, indent: "  ") }
        let light: DesignTokenConfig.ColorValue
        switch token.appearance {
        case let .auto(value, _): light = value
        case let .fixed(value): light = value
        }
        out.append("  \(colorProperty(token.name)): \(cssColor(light));")
      }
    }
    if !config.gradients.isEmpty { out.append("") }
    for token in config.gradients {
      if let doc = token.doc { out += blockComment(doc, indent: "  ") }
      switch token.appearance {
      case let .auto(light, _): out.append("  \(gradientProperty(token.name)): \(stops(light));")
      case let .fixed(values): out.append("  \(gradientProperty(token.name)): \(stops(values));")
      }
    }
    for (groups, property) in [(config.spacing, spacingProperty), (config.radii, radiusProperty)] {
      for group in groups {
        out.append("")
        if let name = group.name { out.append("  /* \(name) */") }
        for token in group.tokens {
          if let doc = token.doc { out += blockComment(doc, indent: "  ") }
          out.append("  \(property(token.name)): \(cssNumber(token.value))px;")
        }
      }
    }
    out.append("}")

    var dark: [String] = []
    for token in config.colorTokens {
      if case let .auto(_, value) = token.appearance {
        dark.append("    \(colorProperty(token.name)): \(cssColor(value));")
      }
    }
    for token in config.gradients {
      if case let .auto(_, values) = token.appearance {
        dark.append("    \(gradientProperty(token.name)): \(stops(values));")
      }
    }
    if !dark.isEmpty {
      out += ["", "@media (prefers-color-scheme: dark) {", "  :root {"] + dark + ["  }", "}"]
    }

    let faces = DesignTokenLineHeights.faces(config)
    for group in config.fonts {
      out.append("")
      if let name = group.name { out += ["/* \(name) */", ""] }
      for token in group.tokens {
        if let doc = token.doc { out += blockComment(doc, indent: "") }
        out.append(".\(fontClass(token.name)) {")
        out.append("  font-family: var(\(familyProperty(token.family)));")
        out.append("  font-weight: \(token.weight);")
        out.append("  font-size: \(cssNumber(token.size))px;")
        let lineHeight = DesignTokenLineHeights.webLineHeight(token, faces)
        if lineHeight > token.lineHeight {
          // The apps draw a line height under the face's at the face's.
          out.append("  /* the face's own line height; the token declares \(cssNumber(token.lineHeight))px */")
        }
        out.append("  line-height: \(cssNumber(lineHeight))px;")
        if token.tracking != 0 { out.append("  letter-spacing: \(cssNumber(token.tracking))em;") }
        var axes: [String] = []
        if let value = token.opticalSize { axes.append("\"opsz\" \(cssNumber(value))") }
        if let value = token.softness { axes.append("\"SOFT\" \(cssNumber(value))") }
        if let value = token.width { axes.append("\"wdth\" \(cssNumber(value))") }
        if !axes.isEmpty { out.append("  font-variation-settings: \(axes.joined(separator: ", "));") }
        out.append("}")
        out.append("")
      }
    }
    return DesignTokensEmitter.render(out).trimmingCharacters(in: .newlines) + "\n"
  }

  // MARK: - tokens.json

  static func manifest(config: DesignTokenConfig, target: DesignTokenConfig.CSSTarget) -> String {
    typealias JSON = DTCGSource.JSON
    /// An object with its keys sorted, so the manifest reads the same
    /// whichever order an entry was assembled in.
    func object(_ pairs: [(String, JSON?)]) -> JSON {
      .object(pairs.compactMap { key, value in value.map { (key, $0) } }.sorted { $0.0 < $1.0 })
    }
    func text(_ value: String?) -> JSON? { value.map(JSON.string) }
    func colorPair(_ appearance: DesignTokenConfig.ColorAppearance) -> (JSON, JSON) {
      switch appearance {
      case let .auto(light, dark): return (.string(cssColor(light)), .string(cssColor(dark)))
      case let .fixed(value): return (.string(cssColor(value)), .string(cssColor(value)))
      }
    }
    var colors: [JSON] = []
    for group in config.colors {
      for token in group.tokens {
        let (light, dark) = colorPair(token.appearance)
        colors.append(object([
          ("name", .string(token.name)), ("css", .string(colorProperty(token.name))), ("group", text(group.name)),
          ("light", light), ("dark", dark), ("doc", text(token.doc)), ("note", text(token.note)),
          ("source", text(token.source)),
        ]))
      }
    }
    var fonts: [JSON] = []
    for group in config.fonts {
      for token in group.tokens {
        fonts.append(object([
          ("name", .string(token.name)), ("css", .string(fontClass(token.name))), ("group", text(group.name)),
          ("family", .string(token.family.rawValue)), ("weight", .number(Double(token.weight))),
          ("size", .number(token.size)), ("lineHeight", .number(token.lineHeight)),
          ("tracking", .number(token.tracking)),
          ("opticalSize", token.opticalSize.map(JSON.number)), ("softness", token.softness.map(JSON.number)),
          ("width", token.width.map(JSON.number)),
          ("doc", text(token.doc)), ("note", text(token.note)), ("source", text(token.source)),
        ]))
      }
    }
    var gradients: [JSON] = []
    for token in config.gradients {
      let (light, dark): ([DesignTokenConfig.ColorValue], [DesignTokenConfig.ColorValue])
      switch token.appearance {
      case let .auto(l, d): (light, dark) = (l, d)
      case let .fixed(values): (light, dark) = (values, values)
      }
      gradients.append(object([
        ("name", .string(token.name)), ("css", .string(gradientProperty(token.name))),
        ("light", .array(light.map { .string(cssColor($0)) })), ("dark", .array(dark.map { .string(cssColor($0)) })),
        ("doc", text(token.doc)), ("note", text(token.note)), ("source", text(token.source)),
      ]))
    }
    func lengths(
      _ groups: [DesignTokenConfig.Group<DesignTokenConfig.DimensionToken>], property: (String) -> String
    ) -> JSON? {
      let entries: [JSON] = groups.flatMap { group in
        group.tokens.map { token in
          object([
            ("name", .string(token.name)), ("css", .string(property(token.name))), ("group", text(group.name)),
            ("value", .number(token.value)), ("doc", text(token.doc)), ("note", text(token.note)),
            ("source", text(token.source)),
          ])
        }
      }
      // Absent, not empty, when the config declares none: the manifest of a
      // config without the scales reads as it did.
      return entries.isEmpty ? nil : .array(entries)
    }
    let families = object(config.families.map { ($0.rawValue, .string(family($0, target: target))) })
    let document = object([
      ("generatedBy", .string("duet design-tokens")),
      ("source", .string(config.source)),
      ("stylesheet", .string("tokens.css")),
      ("families", families),
      ("colors", .array(colors)),
      ("fonts", .array(fonts)),
      ("gradients", .array(gradients)),
      ("spacing", lengths(config.spacing, property: spacingProperty)),
      ("radii", lengths(config.radii, property: radiusProperty)),
    ])
    return DesignTokensJSON.render(document)
  }
}
