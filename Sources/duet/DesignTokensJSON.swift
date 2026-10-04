// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import Foundation

/// The one JSON printer `duet design-tokens` writes with: the `tokens.json`
/// manifest and the token files `duet design-tokens migrate` writes.
///
/// `--check` compares whole files, so the bytes are this printer's decision,
/// not Foundation's: two-space indentation, `"key": value`, object keys in the
/// order the value lists them, an array of scalars on one line (a colour's
/// components, a font stack), and a newline at the end.
///
/// Numbers: a whole value is printed without a fraction (`34`, `0`, `1`);
/// any other value in the shortest form that reads back to the same double
/// (`0.102`, `1.205882`, `-0.34`). Strings escape `"`, `\` and control
/// characters, and keep every other character as itself.
enum DesignTokensJSON {
  typealias JSON = DTCGSource.JSON

  static func render(_ value: JSON) -> String {
    var out = ""
    write(value, indent: "", into: &out)
    return out + "\n"
  }

  static func write(_ value: JSON, indent: String, into out: inout String) {
    let inner = indent + "  "
    switch value {
    case let .object(pairs):
      guard !pairs.isEmpty else { out += "{}"; return }
      out += "{\n"
      for (index, (key, child)) in pairs.enumerated() {
        out += inner + string(key) + ": "
        write(child, indent: inner, into: &out)
        out += index == pairs.count - 1 ? "\n" : ",\n"
      }
      out += indent + "}"
    case let .array(items):
      guard !items.isEmpty else { out += "[]"; return }
      if items.allSatisfy(\.isScalar) {
        out += "[" + items.map { scalar($0) }.joined(separator: ", ") + "]"
        return
      }
      out += "[\n"
      for (index, item) in items.enumerated() {
        out += inner
        write(item, indent: inner, into: &out)
        out += index == items.count - 1 ? "\n" : ",\n"
      }
      out += indent + "]"
    default:
      out += scalar(value)
    }
  }

  static func scalar(_ value: JSON) -> String {
    switch value {
    case let .string(text): return string(text)
    case let .number(number): return self.number(number)
    case let .bool(flag): return flag ? "true" : "false"
    case .null: return "null"
    case .object, .array: return render(value).trimmingCharacters(in: .newlines)
    }
  }

  static func number(_ value: Double) -> String {
    if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
    return "\(value)"
  }

  static func string(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case "\u{08}": out += "\\b"
      case "\u{0C}": out += "\\f"
      default:
        if scalar.value < 0x20 {
          out += String(format: "\\u%04x", scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    return out + "\""
  }
}

extension DTCGSource.JSON {
  var isScalar: Bool {
    switch self {
    case .object, .array: return false
    default: return true
    }
  }
}
