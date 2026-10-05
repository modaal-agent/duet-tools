// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import Foundation
import Yams

/// The design tokens in the Design Tokens Community Group format, 2025.10:
/// a resolver document and the token files it names, read when
/// `parity/design-tokens.yaml` is version 2 (`tokens:` names the resolver).
/// Read into the same `DesignTokenConfig` the YAML grammar produces, so every
/// target emits from one model.
///
/// What the reader takes from the format:
/// - `color` (sRGB, `components` 0…1 with an optional `hex` that must agree,
///   `alpha`), `typography`, `fontFamily`, `gradient`, and `dimension` in `px`
///   under the top-level `spacing` and `radius` groups, where no other type
///   is allowed; aliases (`{a.b.c}`) resolved within each appearance. Other
///   types, and a dimension in any other group, are counted and skipped.
/// - Every key a target names follows `DesignTokenRules`, and every refusal
///   in the sources is reported in one run, each with its file, its token and
///   its rule.
/// - One modifier, `appearance`, with the contexts `light` (the default) and
///   `dark`. A colour or gradient whose resolved values differ between the
///   two is a two-appearance value; equal values are one value.
/// - The vocabularies come from `$type`; a token's case name is its own key,
///   and the group it sits in (below the top-level group) is its heading.
/// - `$description` is the vocabulary case's doc comment. The rest lives in
///   `$extensions["dev.modaal.duet"]`: `source` on any token (the design
///   tool and the name the token came from, copied to `tokens.json`), `note`
///   (the value's comment),
///   `textStyle` (the Dynamic Type style), `axes` (`opticalSize`, `softness`,
///   `width`); on a `fontFamily` token, `files`: the family's font files as
///   `{path, weight}`, `path` relative to the repository root and `weight` a
///   number or a variable face's `[min, max]`, which the web target copies
///   and declares with `@font-face`.
enum DTCGSource {
  static let extensionKey = "dev.modaal.duet"
  static let formatVersion = "2025.10"

  /// A JSON value with its object keys in document order. JSONSerialization
  /// drops the order, and the generated vocabularies follow it, so the files
  /// are read with Yams' composer: JSON is YAML 1.2's flow style.
  indirect enum JSON {
    case object([(String, JSON)])
    case array([JSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    subscript(key: String) -> JSON? {
      if case let .object(pairs) = self { return pairs.first { $0.0 == key }?.1 }
      return nil
    }

    var pairs: [(String, JSON)]? {
      if case let .object(pairs) = self { return pairs }
      return nil
    }

    var string: String? {
      if case let .string(text) = self { return text }
      return nil
    }

    var number: Double? {
      if case let .number(value) = self { return value }
      return nil
    }

    /// The plain value, for the target blocks the YAML reader validates.
    var any: Any {
      switch self {
      case let .object(pairs): return Dictionary(pairs.map { ($0.0, $0.1.any) }, uniquingKeysWith: { a, _ in a })
      case let .array(items): return items.map(\.any)
      case let .string(text): return text
      case let .number(value): return value == value.rounded() && abs(value) < 1e15 ? Int(value) as Any : value
      case let .bool(flag): return flag
      case .null: return NSNull()
      }
    }
  }

  struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  static func parseJSON(_ text: String, path: String) throws -> JSON {
    let node: Node?
    do {
      node = try Yams.compose(yaml: text)
    } catch {
      throw Failure(description: "\(path): not valid JSON — \(error)")
    }
    guard let node else { throw Failure(description: "\(path): empty document") }
    return try json(node, path: path)
  }

  private static func json(_ node: Node, path: String) throws -> JSON {
    switch node {
    case let .mapping(mapping):
      return .object(try mapping.map { pair in
        guard case let .scalar(key) = pair.key else { throw Failure(description: "\(path): a key must be a string") }
        return (key.string, try json(pair.value, path: path))
      })
    case let .sequence(sequence):
      return .array(try sequence.map { try json($0, path: path) })
    case let .scalar(scalar):
      if scalar.style == .doubleQuoted || scalar.style == .singleQuoted { return .string(scalar.string) }
      switch scalar.string {
      case "true": return .bool(true)
      case "false": return .bool(false)
      case "null": return .null
      default:
        guard let value = Double(scalar.string) else {
          throw Failure(description: "\(path): '\(scalar.string)' is not a JSON value")
        }
        return .number(value)
      }
    case .alias:
      throw Failure(description: "\(path): not valid JSON")
    }
  }

  // MARK: - The resolver

  /// One merged token tree per appearance, plus the paths the dark context's
  /// sources define and the file each token path last came from, so a
  /// refusal names the file to edit.
  struct Resolved {
    var light: JSON
    var dark: JSON
    var darkPaths: Set<String>
    var lightFiles: [String: String] = [:]
    var darkFiles: [String: String] = [:]
  }

  static func resolve(resolver url: URL, relativePath: String) throws -> Resolved {
    let text = try String(contentsOf: url, encoding: .utf8)
    let doc = try parseJSON(text, path: relativePath)
    guard let top = doc.pairs else { throw Failure(description: "\(relativePath): the document must be an object") }
    let known: Set<String> = ["$schema", "name", "description", "version", "sets", "modifiers", "resolutionOrder", "$defs"]
    for (key, _) in top where !known.contains(key) {
      throw Failure(description: "\(relativePath): unknown key '\(key)'")
    }
    guard doc["version"]?.string == formatVersion else {
      throw Failure(description: "\(relativePath): 'version' must be \"\(formatVersion)\", the resolver format this toolchain reads")
    }
    let base = url.deletingLastPathComponent()
    let directory = (relativePath as NSString).deletingLastPathComponent
    var cache: [String: JSON] = [:]

    /// A source: an inline token group, or `{"$ref": "file.tokens.json"}`
    /// relative to the resolver. Paired with the file it names, relative to
    /// the repository root (the resolver's own path for an inline group).
    func source(_ entry: JSON, at where_: String) throws -> (JSON, String) {
      guard let ref = entry["$ref"] else { return (entry, relativePath) }
      guard let file = ref.string, !file.contains("#") else {
        throw Failure(description: "\(relativePath): \(where_): '$ref' must name a token file (JSON pointers into files are not read)")
      }
      let label = directory.isEmpty ? file : "\(directory)/\(file)"
      if let cached = cache[file] { return (cached, label) }
      let target = base.appendingPathComponent(file)
      guard let body = try? String(contentsOf: target, encoding: .utf8) else {
        throw Failure(description: "\(relativePath): \(where_): cannot read '\(file)'")
      }
      let parsed = try parseJSON(body, path: label)
      cache[file] = parsed
      return (parsed, label)
    }

    func sources(_ list: JSON?, at where_: String) throws -> [(JSON, String)] {
      guard case let .array(items)? = list else { throw Failure(description: "\(relativePath): \(where_) must be an array") }
      return try items.map { try source($0, at: where_) }
    }

    /// `#/sets/<name>` or `#/modifiers/<name>`, or the inline object itself.
    func referenced(_ item: JSON) throws -> (kind: String, name: String, body: JSON) {
      if let ref = item["$ref"]?.string {
        let parts = ref.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "#", ["sets", "modifiers"].contains(parts[1]),
              let body = doc[parts[1]]?[parts[2]]
        else { throw Failure(description: "\(relativePath): resolutionOrder: cannot resolve '\(ref)'") }
        return (parts[1] == "sets" ? "set" : "modifier", parts[2], body)
      }
      guard let kind = item["type"]?.string, let name = item["name"]?.string else {
        throw Failure(description: "\(relativePath): resolutionOrder: an inline entry needs 'type' and 'name'")
      }
      return (kind, name, item)
    }

    guard case let .array(order)? = doc["resolutionOrder"], !order.isEmpty else {
      throw Failure(description: "\(relativePath): 'resolutionOrder' must be a non-empty array")
    }
    var light: [(JSON, String)] = []
    var dark: [(JSON, String)] = []
    var darkOnly: [(JSON, String)] = []
    var sawAppearance = false
    for item in order {
      let (kind, name, body) = try referenced(item)
      if kind == "set" {
        let set = try sources(body["sources"], at: "set '\(name)' sources")
        light += set
        dark += set
        continue
      }
      guard name == "appearance" else {
        throw Failure(description: "\(relativePath): modifier '\(name)': the targets know one modifier, 'appearance' (light, dark)")
      }
      sawAppearance = true
      guard let contexts = body["contexts"]?.pairs,
            Set(contexts.map(\.0)) == ["light", "dark"]
      else {
        throw Failure(description: "\(relativePath): modifier 'appearance' must have exactly the contexts 'light' and 'dark'")
      }
      guard body["default"]?.string == "light" else {
        throw Failure(description: "\(relativePath): modifier 'appearance' must default to 'light'")
      }
      light += try sources(body["contexts"]?["light"], at: "appearance.light")
      let darkSources = try sources(body["contexts"]?["dark"], at: "appearance.dark")
      dark += darkSources
      darkOnly += darkSources
    }
    guard sawAppearance else {
      throw Failure(description: "\(relativePath): resolutionOrder must include the 'appearance' modifier")
    }
    var darkPaths = Set<String>()
    for (tree, _) in darkOnly { collectTokenPaths(tree, prefix: [], into: &darkPaths) }
    /// Later sources win, as in `merge`.
    func files(_ trees: [(JSON, String)]) -> [String: String] {
      var out: [String: String] = [:]
      for (tree, label) in trees {
        var paths = Set<String>()
        collectTokenPaths(tree, prefix: [], into: &paths)
        for path in paths { out[path] = label }
      }
      return out
    }
    return Resolved(
      light: merge(light.map(\.0)), dark: merge(dark.map(\.0)), darkPaths: darkPaths,
      lightFiles: files(light), darkFiles: files(darkOnly))
  }

  static func isToken(_ node: JSON) -> Bool { node["$value"] != nil }

  /// Later sources win: groups merge key by key, and a token replaces the
  /// earlier token at its path whole.
  static func merge(_ trees: [JSON]) -> JSON {
    func combine(_ a: JSON, _ b: JSON) -> JSON {
      guard var left = a.pairs, let right = b.pairs, !isToken(a), !isToken(b) else { return b }
      for (key, value) in right {
        if let index = left.firstIndex(where: { $0.0 == key }) {
          left[index].1 = combine(left[index].1, value)
        } else {
          left.append((key, value))
        }
      }
      return .object(left)
    }
    return trees.reduce(JSON.object([])) { combine($0, $1) }
  }

  static func collectTokenPaths(_ node: JSON, prefix: [String], into paths: inout Set<String>) {
    guard let pairs = node.pairs else { return }
    if isToken(node) { paths.insert(prefix.joined(separator: ".")); return }
    for (key, child) in pairs where !key.hasPrefix("$") {
      collectTokenPaths(child, prefix: prefix + [key], into: &paths)
    }
  }

  // MARK: - Tokens

  struct Token {
    var path: [String]
    var type: String
    var node: JSON
    var id: String { path.joined(separator: ".") }
    var name: String { path.last! }
    /// The group below the top-level one; nil for a token directly in it.
    var heading: String? { path.count > 2 ? path.dropFirst().dropLast().joined(separator: " / ") : nil }
  }

  static let tokenKeys: Set<String> = ["$value", "$type", "$description", "$extensions", "$deprecated"]
  static let groupKeys: Set<String> = ["$type", "$description", "$extensions", "$deprecated", "$schema"]

  static func tokens(_ node: JSON, path: [String] = [], type: String? = nil, file: String) throws -> [Token] {
    guard let pairs = node.pairs else { throw Failure(description: "\(file): '\(path.joined(separator: "."))' must be an object") }
    if isToken(node) {
      for (key, _) in pairs where !tokenKeys.contains(key) {
        throw Failure(description: "\(file): token '\(path.joined(separator: "."))': unknown key '\(key)'")
      }
      guard let resolvedType = node["$type"]?.string ?? type else {
        throw Failure(description: "\(file): token '\(path.joined(separator: "."))' has no $type, on itself or a group")
      }
      return [Token(path: path, type: resolvedType, node: node)]
    }
    var out: [Token] = []
    let groupType = node["$type"]?.string ?? type
    for (key, child) in pairs {
      if key.hasPrefix("$") {
        guard groupKeys.contains(key) else {
          throw Failure(description: "\(file): group '\(path.joined(separator: "."))': unknown key '\(key)'")
        }
        continue
      }
      out += try tokens(child, path: path + [key], type: groupType, file: file)
    }
    return out
  }

  /// Follows `{a.b.c}` references within one appearance's tree.
  static func dereference(_ value: JSON, in tree: JSON, file: String, depth: Int = 0) throws -> JSON {
    guard let text = value.string, text.hasPrefix("{"), text.hasSuffix("}") else { return value }
    guard depth < 16 else { throw Failure(description: "\(file): alias '\(text)' does not end (a cycle?)") }
    var node: JSON? = tree
    for part in text.dropFirst().dropLast().split(separator: ".") { node = node?[String(part)] }
    guard let target = node, let next = target["$value"] else {
      throw Failure(description: "\(file): alias '\(text)' names no token")
    }
    return try dereference(next, in: tree, file: file, depth: depth + 1)
  }

  static func lookup(_ token: Token, in tree: JSON) -> JSON? {
    var node: JSON? = tree
    for part in token.path { node = node?[part] }
    return node
  }

  static func ext(_ node: JSON) -> JSON? { node["$extensions"]?[extensionKey] }

  /// The top-level groups whose `dimension` tokens are a vocabulary.
  static let dimensionScales: Set<String> = ["spacing", "radius"]

  // MARK: - Values

  static func color(_ raw: JSON, in tree: JSON, at where_: String, file: String) throws -> DesignTokenConfig.ColorValue {
    let value = try dereference(raw, in: tree, file: file)
    guard value["colorSpace"]?.string == "srgb", case let .array(parts)? = value["components"], parts.count == 3 else {
      throw Failure(description: "\(file): \(where_): a colour must be {colorSpace: \"srgb\", components: [r, g, b]} — the targets draw sRGB")
    }
    var rgb: UInt32 = 0
    for part in parts {
      guard let c = part.number, c >= 0, c <= 1 else {
        throw Failure(description: "\(file): \(where_): sRGB components are numbers from 0 to 1")
      }
      rgb = rgb << 8 | UInt32((c * 255).rounded())
    }
    if let hex = value["hex"]?.string {
      guard hex.lowercased() == String(format: "#%06x", rgb) else {
        throw Failure(description: "\(file): \(where_): 'hex' \(hex) disagrees with the components (\(String(format: "#%06x", rgb)))")
      }
    }
    let alpha = value["alpha"]?.number ?? 1
    guard alpha >= 0, alpha <= 1 else { throw Failure(description: "\(file): \(where_): 'alpha' must be between 0 and 1") }
    return .init(rgb: rgb, alpha: alpha)
  }

  static func px(_ raw: JSON?, in tree: JSON, at where_: String, file: String) throws -> Double {
    guard let raw else { throw Failure(description: "\(file): \(where_) is missing") }
    let value = try dereference(raw, in: tree, file: file)
    guard let number = value["value"]?.number, value["unit"]?.string == "px" else {
      throw Failure(description: "\(file): \(where_) must be a px dimension, {value, unit: \"px\"}")
    }
    return number
  }

  static let weightNames: [String: Int] = [
    "thin": 100, "hairline": 100, "extra-light": 200, "ultra-light": 200, "light": 300,
    "normal": 400, "regular": 400, "book": 400, "medium": 500, "semi-bold": 600, "demi-bold": 600,
    "bold": 700, "extra-bold": 800, "ultra-bold": 800, "black": 900, "heavy": 900,
    "extra-black": 950, "ultra-black": 950,
  ]

  static func rounded(_ value: Double, _ places: Double) -> Double {
    let scale = pow(10, places)
    return (value * scale).rounded() / scale
  }

  /// A family's `files`, read from the repository.
  static func fontFiles(_ raw: JSON, repoRoot: URL, at where_: String, file: String) throws -> [DesignTokenConfig.FontFile] {
    guard case let .array(items) = raw, !items.isEmpty else {
      throw Failure(description: "\(file): \(where_): 'files' must be a non-empty array of {path, weight}")
    }
    var seen = Set<String>()
    return try items.map { item in
      guard let path = item["path"]?.string, !path.isEmpty, !path.hasPrefix("/"), !path.contains("..") else {
        throw Failure(description: "\(file): \(where_): each file needs 'path', relative to the repository root")
      }
      for (key, _) in item.pairs ?? [] where !["path", "weight"].contains(key) {
        throw Failure(description: "\(file): \(where_): file '\(path)': unknown key '\(key)' (known: path, weight)")
      }
      let weight: String
      switch item["weight"] {
      case let .number(value)?:
        weight = DesignTokensJSON.number(value)
      case let .array(range)? where range.count == 2:
        guard let low = range[0].number, let high = range[1].number, low < high else {
          throw Failure(description: "\(file): \(where_): file '\(path)': a weight range is [min, max]")
        }
        weight = "\(DesignTokensJSON.number(low)) \(DesignTokensJSON.number(high))"
      default:
        throw Failure(description: "\(file): \(where_): file '\(path)': 'weight' must be a number or a [min, max] range")
      }
      guard let data = FileManager.default.contents(atPath: repoRoot.appendingPathComponent(path).path) else {
        throw Failure(description: "\(file): \(where_): cannot read the font file '\(path)'")
      }
      let font = DesignTokenConfig.FontFile(source: path, weight: weight, data: data)
      guard font.format != nil else {
        throw Failure(description: "\(file): \(where_): '\(path)' is not a .ttf, .otf, .woff or .woff2 file")
      }
      guard seen.insert(font.fileName).inserted else {
        throw Failure(description: "\(file): \(where_): two font files are named '\(font.fileName)' — they are copied into one directory")
      }
      return font
    }
  }

  static func load(
    resolver url: URL, relativePath: String,
    targets: (DesignTokenConfig.SwiftTarget?, DesignTokenConfig.KotlinTarget?, DesignTokenConfig.CSSTarget?),
    repoRoot: URL
  ) throws -> DesignTokenConfig {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw Failure(description: "\(DesignTokenConfig.relativePath): 'tokens' names \(relativePath), which does not exist")
    }
    let resolved = try resolve(resolver: url, relativePath: relativePath)
    let file = relativePath
    let (swift, kotlin, css) = targets

    var colors: [DesignTokenConfig.Group<DesignTokenConfig.ColorToken>] = []
    var fonts: [DesignTokenConfig.Group<DesignTokenConfig.FontToken>] = []
    var gradients: [DesignTokenConfig.GradientToken] = []
    var spacing: [DesignTokenConfig.Group<DesignTokenConfig.DimensionToken>] = []
    var radii: [DesignTokenConfig.Group<DesignTokenConfig.DimensionToken>] = []
    var families: [DesignTokenConfig.FontFamily: String] = [:]
    var declaredFamilies: [DesignTokenConfig.FontFamily] = []
    var faces: [DesignTokenConfig.FontFace] = []
    var faceFiles = Set<String>()
    struct Skip: Hashable { var type: String; var group: String }
    var skipped: [Skip: Int] = [:]

    func append<T>(_ token: T, heading: String?, to groups: inout [DesignTokenConfig.Group<T>]) {
      if let last = groups.indices.last, groups[last].name == heading {
        groups[last].tokens.append(token)
      } else {
        groups.append(.init(name: heading, tokens: [token]))
      }
    }

    func stops(_ raw: JSON, in tree: JSON, at where_: String, file: String) throws -> [DesignTokenConfig.ColorValue] {
      guard case let .array(items) = try dereference(raw, in: tree, file: file), items.count >= 2 else {
        throw Failure(description: "\(file): \(where_): a gradient needs two or more stops")
      }
      return try items.enumerated().map { index, stop in
        let even = Double(index) / Double(items.count - 1)
        guard let position = try dereference(stop["position"] ?? .null, in: tree, file: file).number,
              abs(position - even) < 1e-6
        else {
          throw Failure(description: "\(file): \(where_): stop \(index) must sit at \(even) — the targets space stops evenly")
        }
        let value = try color(stop["color"] ?? .null, in: tree, at: "\(where_) stop \(index)", file: file)
        guard value.alpha == 1 else { throw Failure(description: "\(file): \(where_): gradient stops are opaque") }
        return value
      }
    }

    // Every refusal is collected, each naming its file, its token and the
    // rule it breaks (contracts/design-tokens.md, "Rules"), and all of them
    // are reported together; nothing is generated while one stands.
    var problems: [(file: String, text: String)] = []
    let lightTokens = try tokens(resolved.light, file: file)
    let lightIDs = Set(lightTokens.map(\.id))
    for id in resolved.darkPaths.sorted() where !lightIDs.contains(id) {
      let darkFile = resolved.darkFiles[id] ?? file
      problems.append((darkFile, "\(darkFile): '\(id)' is defined only for the dark appearance: R5 — declare it in the base set too"))
    }
    let extensionKeys: [String: Set<String>] = [
      "color": ["note", "source"], "gradient": ["note", "source"], "fontFamily": ["files", "source"],
      "typography": ["note", "textStyle", "axes", "source"], "dimension": ["note", "source"],
    ]
    /// The rule a token's values follow, by type.
    let valueRules = ["color": "R5", "gradient": "R5", "typography": "R6", "fontFamily": "R7", "dimension": "R4"]
    /// Each vocabulary's keys, with the path that took each key first (R3).
    var keys: [String: [String: [String]]] = [:]
    var refusedFamilies = Set<String>()
    for token in lightTokens {
      let at = "\(token.type) '\(token.id)'"
      let file = resolved.lightFiles[token.id] ?? relativePath
      func refuse(_ text: String) { problems.append((file, "\(file): \(at): \(text)")) }
      if let scale = token.path.first, dimensionScales.contains(scale), token.type != "dimension" {
        let example = token.node["$value"]?.number.map(DesignTokensJSON.number) ?? "8"
        refuse("R4 — a token under '\(scale)' is a dimension in px: write \"$type\": \"dimension\" and \"$value\": {\"value\": \(example), \"unit\": \"px\"}")
        continue
      }
      let vocabulary: String?
      switch token.type {
      case "color", "typography", "gradient", "fontFamily": vocabulary = token.type
      case "dimension": vocabulary = dimensionScales.contains(token.path[0]) ? token.path[0] : nil
      default: vocabulary = nil
      }
      if let vocabulary {
        if let problem = DesignTokenRules.keyProblem(path: token.path) {
          refuse(problem)
          if token.type == "fontFamily" { refusedFamilies.insert(token.name) }
        } else if let first = keys[vocabulary]?[token.name] {
          refuse(DesignTokenRules.duplicate(path: token.path, first: first))
        } else {
          keys[vocabulary, default: [:]][token.name] = token.path
        }
      }
      if let known = extensionKeys[token.type], let owned = ext(token.node)?.pairs {
        for (key, _) in owned where !known.contains(key) {
          refuse("R8 — unknown key '\(key)' in $extensions[\"\(extensionKey)\"] (known: \(known.sorted().joined(separator: ", ")))")
        }
        if let source = ext(token.node)?["source"], source.string?.isEmpty != false {
          refuse("R8 — 'source' is a non-empty string naming the design tool and the name there, such as \"Figma: Labels/Primary\"")
        }
      }
      let doc = token.node["$description"]?.string
      let note = ext(token.node)?["note"]?.string
      let source = ext(token.node)?["source"]?.string
      do {
        guard let darkNode = lookup(token, in: resolved.dark), let lightValue = token.node["$value"],
              let darkValue = darkNode["$value"]
        else { throw Failure(description: "\(file): \(at): it has no value in the dark appearance; add it to the dark context's file") }
        switch token.type {
        case "color":
          // The generated code depends on the resolved values only, never on
          // which file holds them: equal in both appearances is one value.
          let light = try color(lightValue, in: resolved.light, at: at, file: file)
          let dark = try color(darkValue, in: resolved.dark, at: at, file: file)
          let appearance: DesignTokenConfig.ColorAppearance = light == dark ? .fixed(light) : .auto(light: light, dark: dark)
          append(.init(name: token.name, doc: doc, note: note, appearance: appearance, source: source),
                 heading: token.heading, to: &colors)
        case "fontFamily":
          // A family whose key is refused is reported once, by its key.
          guard !refusedFamilies.contains(token.name) else { break }
          guard let family = DesignTokenConfig.FontFamily(rawValue: token.name) else {
            throw Failure(description: "\(file): \(at): a family's key becomes an enum case — lowerCamelCase letters and digits")
          }
          declaredFamilies.append(family)
          let names: [String]
          switch try dereference(lightValue, in: resolved.light, file: file) {
          case let .string(one): names = [one]
          case let .array(list): names = list.compactMap(\.string)
          default: throw Failure(description: "\(file): \(at): a font family is a name or a list of names")
          }
          let generic: Set<String> = ["serif", "sans-serif", "monospace", "system-ui", "ui-serif", "ui-sans-serif", "ui-monospace", "-apple-system", "cursive", "fantasy"]
          families[family] = names.map { $0.contains(" ") && !generic.contains($0) ? "\"\($0)\"" : $0 }.joined(separator: ", ")
          if let rawFiles = ext(token.node)?["files"] {
            guard let name = names.first, !generic.contains(name) else {
              throw Failure(description: "\(file): \(at): a family with 'files' starts its stack with the face's own name")
            }
            let files = try fontFiles(rawFiles, repoRoot: repoRoot, at: at, file: file)
            for font in files where !faceFiles.insert(font.fileName).inserted {
              throw Failure(description: "\(file): \(at): the font file name '\(font.fileName)' is used by another family")
            }
            faces.append(.init(family: family, name: name, files: files))
          }
        case "typography":
          let value = try dereference(lightValue, in: resolved.light, file: file)
          let familyKey = value["fontFamily"]?.string.map { String($0.dropLast().split(separator: ".").last ?? "") }
          // A style on a refused family is reported through the family.
          if let familyKey, refusedFamilies.contains(familyKey) { break }
          guard let familyRef = value["fontFamily"]?.string, familyRef.hasPrefix("{"),
                let family = DesignTokenConfig.FontFamily(rawValue: familyKey ?? ""),
                declaredFamilies.contains(family)
          else {
            throw Failure(description: "\(file): \(at): 'fontFamily' must reference a fontFamily token ({fontFamily.sans})")
          }
          let weightValue = try dereference(value["fontWeight"] ?? .null, in: resolved.light, file: file)
          guard let weight = weightValue.number.map({ Int($0) }) ?? weightValue.string.flatMap({ weightNames[$0] }) else {
            throw Failure(description: "\(file): \(at): 'fontWeight' must be 1…1000 or a weight name")
          }
          let size = try px(value["fontSize"], in: resolved.light, at: "\(at) fontSize", file: file)
          guard let ratio = try dereference(value["lineHeight"] ?? .null, in: resolved.light, file: file).number else {
            throw Failure(description: "\(file): \(at): 'lineHeight' must be a number, the multiple of the font size")
          }
          let spacing = try px(value["letterSpacing"], in: resolved.light, at: "\(at) letterSpacing", file: file)
          let extras = ext(token.node)
          let textStyle = extras?["textStyle"]?.string
          if swift != nil, textStyle == nil {
            throw Failure(description: "\(file): \(at): a swift target is declared, so the token needs $extensions[\"\(extensionKey)\"].textStyle")
          }
          let axes = extras?["axes"]
          append(.init(
            name: token.name, doc: doc, note: note, family: family, weight: weight, size: size,
            lineHeight: rounded(size * ratio, 2), tracking: rounded(spacing / size, 6),
            opticalSize: axes?["opticalSize"]?.number, softness: axes?["softness"]?.number,
            width: axes?["width"]?.number, textStyle: textStyle, source: source),
            heading: token.heading, to: &fonts)
        case "gradient":
          let light = try stops(lightValue, in: resolved.light, at: at, file: file)
          let dark = try stops(darkValue, in: resolved.dark, at: at, file: file)
          // A gradient whose stops name colour tokens changes with them.
          gradients.append(.init(name: token.name, doc: doc, note: note,
                                 appearance: light != dark ? .auto(light: light, dark: dark) : .fixed(light),
                                 source: source))
        case "dimension":
          // A length is a vocabulary under the top-level `spacing` and `radius`
          // groups only; a dimension anywhere else has no target, and scale
          // tokens may alias it.
          guard let scale = token.path.first, dimensionScales.contains(scale) else {
            skipped[Skip(type: token.type, group: token.path[0]), default: 0] += 1
            break
          }
          let light = try px(lightValue, in: resolved.light, at: at, file: file)
          let dark = try px(darkValue, in: resolved.dark, at: at, file: file)
          guard light == dark else {
            throw Failure(description: "\(file): \(at): a \(scale) token has one value in both appearances (light \(DesignTokensJSON.number(light))px, dark \(DesignTokensJSON.number(dark))px)")
          }
          guard light >= 0 else {
            throw Failure(description: "\(file): \(at): a \(scale) token is 0px or more")
          }
          let length = DesignTokenConfig.DimensionToken(name: token.name, doc: doc, note: note, value: light, source: source)
          if scale == "spacing" {
            append(length, heading: token.heading, to: &spacing)
          } else {
            append(length, heading: token.heading, to: &radii)
          }
        default:
          skipped[Skip(type: token.type, group: token.path[0]), default: 0] += 1
        }
      } catch let failure as Failure {
        // The value helpers name the file and the token; the rule goes after
        // them, so every refusal reads `file: token: rule — what to change`.
        var rest = Substring(failure.description)
        if rest.hasPrefix("\(file): ") { rest = rest.dropFirst(file.count + 2) }
        if rest.hasPrefix(at) { rest = rest.dropFirst(at.count) }
        while rest.hasPrefix(":") || rest.hasPrefix(" ") { rest = rest.dropFirst() }
        refuse("\(valueRules[token.type] ?? "R5") — \(rest)")
      }
    }
    if !problems.isEmpty {
      // Grouped by file, each file's refusals in document order.
      let lines = problems.enumerated()
        .sorted { ($0.element.file, $0.offset) < ($1.element.file, $1.offset) }
        .map(\.element.text)
      throw Failure(description: lines.count == 1
        ? lines[0]
        : "\(lines.count) design-token problems; nothing was generated:\n" + lines.map { "  " + $0 }.joined(separator: "\n"))
    }
    for (skip, count) in skipped.sorted(by: { ($0.key.type, $0.key.group) < ($1.key.type, $1.key.group) }) {
      let line = skip.type == "dimension"
        ? "\(count) 'dimension' token(s) under '\(skip.group)' are not generated; alias them from 'spacing' or 'radius' to generate them"
        : "\(count) '\(skip.type)' token(s) under '\(skip.group)' have no target vocabulary; not generated"
      FileHandle.standardError.write(Data("duet design-tokens: \(line)\n".utf8))
    }
    var config = DesignTokenConfig(
      version: DesignTokenConfig.currentVersion, swift: swift, kotlin: kotlin,
      css: css.map { DesignTokenConfig.CSSTarget(output: $0.output, families: families, faces: faces) },
      colors: colors, fonts: fonts, gradients: gradients)
    config.source = relativePath
    config.families = declaredFamilies
    config.spacing = spacing
    config.radii = radii
    return config
  }
}
