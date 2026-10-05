// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

/// The rules a token's key follows so that the generated code compiles
/// (contracts/design-tokens.md, "Rules"): R1 its shape, R2 the reserved
/// names, R3 one key per vocabulary. Each check returns the refusal's text,
/// rule first and a fix last, or nil.
enum DesignTokenRules {
  /// Keys that do not compile as a token's name in a generated file: the
  /// Swift and Kotlin keywords that cannot name an enum case, a static
  /// constant or a `const val`, and the members of Kotlin's `Enum` an entry
  /// cannot shadow (`name`, `ordinal`, `entries`). Measured by compiling each
  /// candidate in the generated shapes (an enum case, a static constant, a
  /// `switch` or `when` arm, a member reference) with Swift for iOS and with
  /// Kotlin/JVM. Contextual keywords that compiled in those shapes (`none`,
  /// `get`, `set`, `open`, `value`, `data`) are not listed.
  static let reserved: Set<String> = [
    "as", "associatedtype", "break", "case", "catch", "class", "constructor", "continue",
    "default", "defer", "deinit", "do", "else", "entries", "enum", "extension",
    "fallthrough", "false", "fileprivate", "for", "fun", "func", "guard", "if",
    "import", "in", "init", "inout", "interface", "internal", "is", "let",
    "name", "nil", "null", "object", "operator", "ordinal", "package", "precedencegroup",
    "private", "protocol", "public", "repeat", "rethrows", "return", "self", "static",
    "struct", "subscript", "super", "switch", "this", "throw", "throws", "true",
    "try", "typealias", "typeof", "val", "var", "when", "where", "while",
  ]

  /// R1: ASCII letters and digits in lowerCamelCase, starting with a
  /// lowercase letter.
  static func hasKeyShape(_ key: String) -> Bool {
    guard let first = key.first, first.isASCII, first.isLowercase else { return false }
    return key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
  }

  /// The key's words joined in lowerCamelCase: `on-light` → `onLight`,
  /// `Primary` → `primary`, `Label Color` → `labelColor`.
  static func lowerCamel(_ text: String) -> String {
    let words = text.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.map(String.init)
    guard let first = words.first else { return "" }
    return first.prefix(1).lowercased() + first.dropFirst()
      + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
  }

  /// The group the token at *path* sits in, as a word: `radius.default` →
  /// `radius`, `color.Labels.default` → `labels`.
  static func groupWord(_ path: [String]) -> String {
    lowerCamel(path.count > 1 ? path[path.count - 2] : path[0])
  }

  /// What a key that starts with a digit gets in front: the scale's letter
  /// (`s4`, `r16`) for a spacing or radius token, else its group's word.
  static func prefix(for path: [String]) -> String {
    switch path.first {
    case "spacing": return "s"
    case "radius": return "r"
    default: return groupWord(path)
    }
  }

  /// *key* behind *prefix*, as one lowerCamelCase name.
  static func joined(_ prefix: String, _ key: String) -> String {
    let rest = lowerCamel(key)
    guard !prefix.isEmpty else { return rest }
    if prefix.count == 1 { return prefix + rest }
    return prefix + rest.prefix(1).uppercased() + rest.dropFirst()
  }

  static let shape =
    "a key is ASCII letters and digits in lowerCamelCase, starting with a lowercase letter, "
    + "because it names a case or a constant in Swift and Kotlin"

  /// The R1 or R2 refusal for the token at *path*, or nil.
  static func keyProblem(path: [String]) -> String? {
    guard let key = path.last else { return nil }
    if !hasKeyShape(key) {
      var fix = lowerCamel(key)
      if let first = fix.first, !first.isLetter { fix = joined(prefix(for: path), fix) }
      if reserved.contains(fix) { fix = joined(groupWord(path), fix) }
      guard hasKeyShape(fix) else { return "R1 — \(shape)" }
      return "R1 — \(shape); rename it '\(fix)'"
    }
    if reserved.contains(key) {
      return "R2 — '\(key)' is reserved: it does not compile as a name in Swift or Kotlin; "
        + "rename it, such as '\(joined(groupWord(path), key))'"
    }
    return nil
  }

  /// The R3 refusal for the token at *path*, whose key the token at *first*
  /// in the same vocabulary has already.
  static func duplicate(path: [String], first: [String]) -> String {
    let key = path.last ?? ""
    let group = path.count > 2 ? lowerCamel(path[path.count - 2]) : ""
    let fix = group.isEmpty || group == key ? "" : ", such as '\(joined(group, key))'"
    return "R3 — '\(first.joined(separator: "."))' has the key '\(key)' too: groups are headings, "
      + "not part of the name, so two tokens of one vocabulary need two keys; rename one\(fix)"
  }
}
