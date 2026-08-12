// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

/// The ONE emission rule-set for canonical `{"case": …}` sum coders, normative
/// in the framework's contracts/serialization.md §4: one derivation logic, two
/// delivery vehicles — the `duet canonical-sum` codegen verb (the scaffold
/// default) and the `@CanonicalSum` macro opt-in both assemble their output from
/// these line builders, so the byte-dialect-critical half cannot fork. Zero
/// dependencies on purpose: emission is pure string building; each vehicle owns
/// its own collection (SwiftParser file walk vs. macro syntax nodes).
///
/// Payload rules (must match the KMP flavor's `CanonicalSumSerializer`):
///   no payload            → {"case":"name"}
///   1 unlabeled payload   → value = the payload's own encoding (inline envelope)
///   labeled payload(s)    → value = object keyed by labels; nil fields omitted;
///                           all-optional payloads omit "value" when every field nil
public struct SumCase: Sendable {
  public struct Field: Sendable {
    public let label: String?
    public let type: String
    public let optional: Bool

    public init(label: String?, type: String, optional: Bool) {
      self.label = label
      self.type = type
      self.optional = optional
    }
  }

  public let name: String
  public let fields: [Field]

  public init(name: String, fields: [Field]) {
    self.name = name
    self.fields = fields
  }

  var isLabeled: Bool { fields.allSatisfy { $0.label != nil } }
  var allOptional: Bool { fields.allSatisfy(\.optional) }
}

public enum CanonicalSumEmission {
  /// The `SumCodingKeys` + `ValueKey` declarations, each line prefixed with
  /// `indent` (file scope for the codegen file; extension-nested for the macro).
  public static func codingKeyDecls(indent: String) -> [String] {
    [
      "\(indent)private enum SumCodingKeys: String, CodingKey {",
      "\(indent)  case caseName = \"case\"",
      "\(indent)  case value",
      "\(indent)}",
      "",
      "\(indent)private struct ValueKey: CodingKey {",
      "\(indent)  let stringValue: String",
      "\(indent)  var intValue: Int? { nil }",
      "\(indent)  init(_ key: String) { stringValue = key }",
      "\(indent)  init?(stringValue: String) { self.stringValue = stringValue }",
      "\(indent)  init?(intValue: Int) { nil }",
      "\(indent)}",
    ]
  }

  /// `public init(from decoder:)` — extension-body indentation (two spaces).
  public static func initDecl(enumName: String, cases: [SumCase]) -> [String] {
    var out: [String] = []
    out.append("  public init(from decoder: Decoder) throws {")
    out.append("    let c = try decoder.container(keyedBy: SumCodingKeys.self)")
    out.append("    switch try c.decode(String.self, forKey: .caseName) {")
    for sumCase in cases { emitDecode(sumCase, into: &out) }
    out.append("    case let unknown:")
    out.append("      throw DecodingError.dataCorruptedError(")
    out.append("        forKey: .caseName, in: c,")
    out.append("        debugDescription: \"Unknown \(enumName) case '\\(unknown)'\")")
    out.append("    }")
    out.append("  }")
    return out
  }

  /// `public func encode(to encoder:)` — extension-body indentation (two spaces).
  public static func encodeDecl(cases: [SumCase]) -> [String] {
    var out: [String] = []
    out.append("  public func encode(to encoder: Encoder) throws {")
    out.append("    var c = encoder.container(keyedBy: SumCodingKeys.self)")
    out.append("    switch self {")
    for sumCase in cases { emitEncode(sumCase, into: &out) }
    out.append("    }")
    out.append("  }")
    return out
  }

  static func baseType(_ type: String) -> String {
    type.hasSuffix("?") ? String(type.dropLast()) : type
  }

  /// The value-binding list for a `case let .x(…)` pattern: labeled fields bind by
  /// label; unlabeled by position.
  static func bindings(for sumCase: SumCase) -> [String] {
    sumCase.fields.enumerated().map { index, field in field.label ?? "v\(index)" }
  }

  static func emitEncode(_ sumCase: SumCase, into out: inout [String]) {
    let name = sumCase.name
    if sumCase.fields.isEmpty {
      out.append("    case .\(name): try c.encode(\"\(name)\", forKey: .caseName)")
      return
    }
    let names = bindings(for: sumCase)
    out.append("    case let .\(name)(\(names.joined(separator: ", "))):")
    out.append("      try c.encode(\"\(name)\", forKey: .caseName)")
    if !sumCase.isLabeled {
      // Single unlabeled payload — inline envelope.
      precondition(sumCase.fields.count == 1, "\(name): unlabeled payloads must be single")
      if sumCase.fields[0].optional {
        out.append("      if let \(names[0]) { try c.encode(\(names[0]), forKey: .value) }")
      } else {
        out.append("      try c.encode(\(names[0]), forKey: .value)")
      }
      return
    }
    let indent: String
    if sumCase.allOptional {
      let anyPresent = names.map { "\($0) != nil" }.joined(separator: " || ")
      out.append("      if \(anyPresent) {")
      indent = "        "
    } else {
      indent = "      "
    }
    out.append("\(indent)var v = c.nestedContainer(keyedBy: ValueKey.self, forKey: .value)")
    for (field, binding) in zip(sumCase.fields, names) {
      let verb = field.optional ? "encodeIfPresent" : "encode"
      out.append("\(indent)try v.\(verb)(\(binding), forKey: ValueKey(\"\(field.label!)\"))")
    }
    if sumCase.allOptional {
      out.append("      }")
    }
  }

  static func emitDecode(_ sumCase: SumCase, into out: inout [String]) {
    let name = sumCase.name
    if sumCase.fields.isEmpty {
      out.append("    case \"\(name)\": self = .\(name)")
      return
    }
    if !sumCase.isLabeled {
      precondition(sumCase.fields.count == 1, "\(name): unlabeled payloads must be single")
      let field = sumCase.fields[0]
      if field.optional {
        out.append("    case \"\(name)\":")
        out.append(
          "      self = .\(name)(try c.decodeIfPresent(\(baseType(field.type)).self, forKey: .value))"
        )
      } else {
        out.append("    case \"\(name)\":")
        out.append("      self = .\(name)(try c.decode(\(field.type).self, forKey: .value))")
      }
      return
    }
    out.append("    case \"\(name)\":")
    func constructor(_ access: String, indent: String) -> [String] {
      let arguments = sumCase.fields.map { field -> String in
        let verb = field.optional ? "decodeIfPresent" : "decode"
        return "\(field.label!): try \(access).\(verb)(\(baseType(field.type)).self, "
          + "forKey: ValueKey(\"\(field.label!)\"))"
      }
      var lines = ["\(indent)self = .\(name)("]
      for (index, argument) in arguments.enumerated() {
        lines.append("\(indent)  \(argument)\(index == arguments.count - 1 ? ")" : ",")")
      }
      return lines
    }
    if sumCase.allOptional {
      out.append("      if c.contains(.value) {")
      out.append("        let v = try c.nestedContainer(keyedBy: ValueKey.self, forKey: .value)")
      out.append(contentsOf: constructor("v", indent: "        "))
      out.append("      } else {")
      let nils = sumCase.fields.map { "\($0.label!): nil" }.joined(separator: ", ")
      out.append("        self = .\(name)(\(nils))")
      out.append("      }")
    } else {
      out.append("      let v = try c.nestedContainer(keyedBy: ValueKey.self, forKey: .value)")
      out.append(contentsOf: constructor("v", indent: "      "))
    }
  }
}
