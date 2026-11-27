// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import Foundation

/// Token values per app: the resolver's `app` modifier (contracts/design-tokens.md,
/// "Values per app"). The vocabularies are generated once; the colour values
/// once per app context.
///
/// An app context changes colour values only. Each app's config is compared
/// with the default app's token by token, and a change to anything else (a
/// colour's name or prose, a gradient, a type token, a family, a length) is
/// refused naming the app and the token. Every generated file other than the
/// value files must then come out byte-identical for every app.
///
/// - Swift: `TokenApp.swift` declares the apps. While two apps' colours
///   differ, `<theme>Palette.swift`'s `colorSet(for:)` switches over
///   `TokenApp.current` and returns one table per group of apps with equal
///   colours; while every app has the default app's colours the palette is
///   the one a resolver without the modifier generates.
/// - Kotlin: `TokenApp.kt`, and `<palette>.color(token)` as on Swift.
/// - Web: `tokens.css` keeps the default app's values on `:root` and adds,
///   for each app whose colours differ, those colours under
///   `[data-app="<id>"]`; `tokens.json` gives each such colour an
///   `apps.<id>.{light,dark}` member.
enum DesignTokensAppValues {
  struct Failure: Error, CustomStringConvertible { var description: String }

  /// One app context's config and the files it generates alone.
  struct AppValues {
    var app: String
    var config: DesignTokenConfig
    var files: [GeneratedDesignTokenFile]
  }

  static func tokenAppPaths(config: DesignTokenConfig) -> Set<String> {
    var paths: Set<String> = []
    if let swift = config.swift { paths.insert("\(swift.output)/TokenApp.swift") }
    if let kotlin = config.kotlin { paths.insert("\(kotlin.output)/TokenApp.kt") }
    return paths
  }

  // MARK: - The colour-only rule

  /// What *config* (app *app*'s) changes besides colour values, against the
  /// default app's *base*. Each line names the app and the token.
  static func problems(app: String, config: DesignTokenConfig, base: DesignTokenConfig) -> [String] {
    var problems: [String] = []
    func refuse(_ what: String) {
      problems.append(
        "\(base.source): app '\(app)' changes \(what) — an app context changes colour values only")
    }
    let names = config.colors.map { ($0.name ?? "", $0.tokens.map(\.name)) }
    let baseNames = base.colors.map { ($0.name ?? "", $0.tokens.map(\.name)) }
    if names.map(\.0) != baseNames.map(\.0) || names.map(\.1) != baseNames.map(\.1) {
      let mine = Set(config.colorTokens.map(\.name)), theirs = Set(base.colorTokens.map(\.name))
      let added = mine.subtracting(theirs).sorted()
      refuse(
        "the colour vocabulary"
          + (added.isEmpty ? "" : " (it adds \(added.map { "'\($0)'" }.joined(separator: ", ")))")
          + "; declare every colour in the base files and override its value in the app's")
      return problems
    }
    for (mine, theirs) in zip(config.colorTokens, base.colorTokens) {
      var stripped = mine
      stripped.appearance = theirs.appearance
      if stripped != theirs { refuse("the colour '\(mine.name)' beyond its value (its description, note or source)") }
    }
    for (mine, theirs) in zip(config.gradients, base.gradients) where mine != theirs {
      refuse(
        "the gradient '\(theirs.name)' (a gradient stop that names a colour the app overrides follows it;"
          + " write that stop's own colour in the base files)")
    }
    if config.gradients.count != base.gradients.count { refuse("the gradient vocabulary") }
    if config.fonts != base.fonts {
      let changed = zip(config.fontTokens, base.fontTokens).filter { $0 != $1 }.map(\.1.name)
      refuse(changed.isEmpty ? "the type vocabulary" : "the typography token '\(changed[0])'")
    }
    let faces = { (c: DesignTokenConfig) in
      c.fontFaces.map { "\($0.family.rawValue)|\($0.name)|" + $0.files.map { "\($0.source)@\($0.weight)" }.joined(separator: ",") }
    }
    if config.families != base.families || config.firstFaces != base.firstFaces || faces(config) != faces(base) {
      refuse("the font families")
    }
    for (scale, mine, theirs) in [("spacing", config.spacing, base.spacing), ("radius", config.radii, base.radii)]
    where mine != theirs {
      let changed = zip(mine.flatMap(\.tokens), theirs.flatMap(\.tokens)).first { $0 != $1 }?.1.name
      refuse(changed.map { "the dimension '\(scale).\($0)'" } ?? "the \(scale) scale")
    }
    return problems
  }

  // MARK: - The merge

  static func merge(
    perApp: [AppValues], modifier: DTCGSource.AppModifier, config: DesignTokenConfig
  ) throws -> [GeneratedDesignTokenFile] {
    guard let defaults = perApp.first(where: { $0.app == modifier.defaultContext }) else { return [] }
    let apps = perApp.map(\.app)
    var problems: [String] = []
    for values in perApp where values.app != defaults.app {
      problems += Self.problems(app: values.app, config: values.config, base: defaults.config)
    }
    if !problems.isEmpty {
      throw Failure(description: problems.count == 1
        ? problems[0]
        : "\(problems.count) design-token problems; nothing was generated:\n"
          + problems.map { "  " + $0 }.joined(separator: "\n"))
    }

    let swiftPalette = config.swift.map { "\($0.output)/\($0.theme)Palette.swift" }
    let kotlinPalette = config.kotlin.map { "\($0.output)/\($0.palette).kt" }
    let cssFile = config.css.map { "\($0.output)/tokens.css" }
    let jsonFile = config.css.map { "\($0.output)/tokens.json" }

    var byPath: [String: [String: String]] = [:]  // path → app → content
    for values in perApp {
      for file in values.files where file.data == nil { byPath[file.path, default: [:]][values.app] = file.content }
    }
    var out: [GeneratedDesignTokenFile] = []
    for file in defaults.files {
      guard file.data == nil, let contents = byPath[file.path] else { out.append(file); continue }
      var merged = file
      switch file.path {
      case swiftPalette:
        merged.content = try mergeFunction(
          contents: contents, apps: apps, path: file.path,
          header: "  public func colorSet(for asset: _ColorAsset) -> ColorSet {",
          closing: "\n  }\n",
          dispatch: { groups in
            var lines = ["  public func colorSet(for asset: _ColorAsset) -> ColorSet {", "    switch TokenApp.current {"]
            for group in groups {
              let cases = group.apps.map { ".\($0)" }.joined(separator: ", ")
              lines.append("    case \(cases): return colorSet_\(group.apps[0])(for: asset)")
            }
            lines += ["    }", "  }"]
            return lines.joined(separator: "\n")
          },
          rename: { body, app in
            body.replacingOccurrences(
              of: "  public func colorSet(for asset: _ColorAsset) -> ColorSet {",
              with: "  func colorSet_\(app)(for asset: _ColorAsset) -> ColorSet {")
          })
      case kotlinPalette:
        merged.content = try mergeFunction(
          contents: contents, apps: apps, path: file.path,
          header: "  fun color(token: SemanticColor): ColorToken =",
          closing: "\n    }\n",
          dispatch: { groups in
            var lines = ["  fun color(token: SemanticColor): ColorToken =", "    when (TokenApp.current) {"]
            for group in groups {
              let entries = group.apps.map { "TokenApp.\($0)" }.joined(separator: ", ")
              lines.append("      \(entries) -> color_\(group.apps[0])(token)")
            }
            lines.append("    }")
            return lines.joined(separator: "\n")
          },
          rename: { body, app in
            body.replacingOccurrences(
              of: "  fun color(token: SemanticColor): ColorToken =",
              with: "  private fun color_\(app)(token: SemanticColor): ColorToken =")
          })
      case cssFile:
        merged.content = file.content + stylesheetAppendix(perApp: perApp, defaults: defaults)
      case jsonFile:
        merged.content = try manifestWithApps(file.content, perApp: perApp, defaults: defaults)
      default:
        for app in apps where contents[app] != file.content {
          throw Failure(
            description: "\(config.source): app '\(app)' changes \(file.path) — an app context changes colour values only")
        }
      }
      out.append(merged)
    }
    if let swift = config.swift {
      out.append(.init(path: "\(swift.output)/TokenApp.swift", content: """
        // GENERATED by `duet design-tokens` from \(config.source) —
        // do not edit. The cases are the contexts of the resolver's `app` modifier.

        /// The app whose colour values the generated palette returns. The
        /// application target sets it once, from its app id, before the first
        /// view draws.
        public enum TokenApp: String, CaseIterable, Sendable {
        \(apps.map { "  case \($0)" }.joined(separator: "\n"))

          nonisolated(unsafe) public static var current: TokenApp = .\(defaults.app)
        }

        """))
    }
    if let kotlin = config.kotlin {
      out.append(.init(path: "\(kotlin.output)/TokenApp.kt", content: """
        // GENERATED by `duet design-tokens` from \(config.source) —
        // do not edit. The entries are the contexts of the resolver's `app` modifier.

        package \(kotlin.package)

        /**
         * The app whose colour values the generated palette returns. The application
         * sets it once, from its app id, before the first composition.
         */
        enum class TokenApp {
        \(apps.map { "  \($0)," }.joined(separator: "\n"))
          ;

          companion object {
            var current: TokenApp = \(defaults.app)
          }
        }

        """))
    }
    return out
  }

  struct Group { var apps: [String]; var body: String }

  /// Cuts the function that starts with *header* out of each app's file,
  /// requires the rest of the file to be the same for every app, and groups
  /// the apps whose functions are equal. With one group the file is returned
  /// as it is; otherwise the function becomes one dispatch over the groups and
  /// one renamed table per group.
  static func mergeFunction(
    contents: [String: String], apps: [String], path: String, header: String, closing: String,
    dispatch: ([Group]) -> String, rename: (String, String) -> String
  ) throws -> String {
    func split(_ text: String) throws -> (before: String, body: String, after: String) {
      guard let start = text.range(of: header),
            let end = text.range(of: closing, range: start.upperBound..<text.endIndex)
      else { throw Failure(description: "design-tokens: \(path) has no `\(header)`") }
      let bodyEnd = text.index(end.lowerBound, offsetBy: closing.count - 1)
      return (String(text[..<start.lowerBound]), String(text[start.lowerBound..<bodyEnd]), String(text[bodyEnd...]))
    }
    let base = try split(contents[apps[0]] ?? "")
    var groups: [Group] = []
    for app in apps {
      let parts = try split(contents[app] ?? "")
      guard parts.before == base.before, parts.after == base.after else {
        throw Failure(
          description: "design-tokens: app '\(app)' changes \(path) outside its colour table"
            + " — an app context changes colour values only")
      }
      if let index = groups.firstIndex(where: { $0.body == parts.body }) {
        groups[index].apps.append(app)
      } else {
        groups.append(Group(apps: [app], body: parts.body))
      }
    }
    if groups.count == 1 { return contents[apps[0]] ?? "" }
    let tables = groups.map { rename($0.body, $0.apps[0]) }.joined(separator: "\n\n")
    return base.before + dispatch(groups) + "\n\n" + tables + base.after
  }

  typealias ColourValues = (name: String, light: DesignTokenConfig.ColorValue, dark: DesignTokenConfig.ColorValue)

  /// Each colour's (light, dark) values, in vocabulary order.
  static func values(_ config: DesignTokenConfig) -> [ColourValues] {
    config.colorTokens.map { token in
      switch token.appearance {
      case let .auto(light, dark): return (token.name, light, dark)
      case let .fixed(value): return (token.name, value, value)
      }
    }
  }

  /// The rules of each app whose colours differ from the default app's. Each
  /// rule sets every colour the app changes, in either appearance, so the
  /// app's values hold whichever element carries `data-app` and whichever
  /// carries an appearance class: the same element, an ancestor or a
  /// descendant.
  static func stylesheetAppendix(perApp: [AppValues], defaults: AppValues) -> String {
    let base = values(defaults.config)
    var out: [String] = []
    for app in perApp where app.app != defaults.app {
      let changed = zip(values(app.config), base)
        .filter { $0.light != $1.light || $0.dark != $1.dark }
        .map(\.0)
      guard !changed.isEmpty else { continue }
      let selector = "[data-app=\"\(app.app)\"]"
      func lines(_ indent: String, dark: Bool) -> [String] {
        changed.map {
          "\(indent)\(DesignTokensCSSEmitter.colorProperty($0.name)): "
            + "\(DesignTokensCSSEmitter.cssColor(dark ? $0.dark : $0.light));"
        }
      }
      out += [
        "",
        "/* The \(app.app) app's colours (the resolver's `app` modifier): on an",
        "   element with data-app=\"\(app.app)\" and its descendants. */",
        "\(selector) {",
      ] + lines("  ", dark: false) + [
        "}",
        "",
        "@media (prefers-color-scheme: dark) {",
        "  \(selector) {",
      ] + lines("    ", dark: true) + [
        "  }",
        "}",
        "",
        "\(selector).appearance-light,",
        "\(selector) .appearance-light,",
        ".appearance-light \(selector) {",
      ] + lines("  ", dark: false) + [
        "}",
        "",
        "\(selector).appearance-dark,",
        "\(selector) .appearance-dark,",
        ".appearance-dark \(selector) {",
      ] + lines("  ", dark: true) + ["}"]
    }
    return out.isEmpty ? "" : out.joined(separator: "\n") + "\n"
  }

  /// `tokens.json` with an `apps` member on each colour some app changes:
  /// `{"<id>": {"dark": …, "light": …}}`, one entry per such app.
  static func manifestWithApps(_ text: String, perApp: [AppValues], defaults: AppValues) throws -> String {
    typealias JSON = DTCGSource.JSON
    let base = values(defaults.config)
    var perColour: [[(String, JSON)]] = Array(repeating: [], count: base.count)
    for app in perApp where app.app != defaults.app {
      for (index, pair) in zip(values(app.config), base).enumerated()
      where pair.0.light != pair.1.light || pair.0.dark != pair.1.dark {
        perColour[index].append((app.app, .object([
          ("dark", .string(DesignTokensCSSEmitter.cssColor(pair.0.dark))),
          ("light", .string(DesignTokensCSSEmitter.cssColor(pair.0.light))),
        ])))
      }
    }
    guard perColour.contains(where: { !$0.isEmpty }) else { return text }
    guard case var .object(top) = try DTCGSource.parseJSON(text, path: "tokens.json"),
          let colorsIndex = top.firstIndex(where: { $0.0 == "colors" }),
          case var .array(colors) = top[colorsIndex].1, colors.count == base.count
    else { throw Failure(description: "design-tokens: tokens.json does not list one entry per colour") }
    for index in colors.indices where !perColour[index].isEmpty {
      guard case var .object(entry) = colors[index] else { continue }
      entry.append(("apps", .object(perColour[index])))
      entry.sort { $0.0 < $1.0 }
      colors[index] = .object(entry)
    }
    top[colorsIndex].1 = .array(colors)
    return DesignTokensJSON.render(.object(top))
  }
}
