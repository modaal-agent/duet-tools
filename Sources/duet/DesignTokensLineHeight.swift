// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import Foundation

/// The floor under a text style's line height: its face's own.
///
/// Every target lays a text out the way design tools and CSS do: each line is
/// the style's line height tall, with the face centred in it. The web target
/// does it with `line-height`, and the apps' theming code with padding and a
/// line-height style. No platform draws a line shorter than its face: Compose
/// grows such a line back to the face's height, and SwiftUI's leading cannot
/// go below zero. A style whose line height sits under its face's would
/// therefore lay out differently per platform, so every target is written the
/// face's height instead, and the run names the style.
enum DesignTokenLineHeights {
  /// The line height per em of Apple's system faces: every system design
  /// (SF Pro, New York, SF Mono, SF Pro Rounded) at every size and weight
  /// measured. Android's system faces for `sans-serif`, `serif` and
  /// `monospace` (Roboto, Noto Serif, Droid Sans Mono) are 1.1719, under it,
  /// so one value covers both platforms.
  static let systemFace = 1.1934

  /// First names in a stack that resolve to the platform's system face.
  static let systemNames: Set<String> = [
    "-apple-system", "system-ui", "BlinkMacSystemFont", "ui-sans-serif", "ui-serif", "ui-monospace",
    "ui-rounded", "New York", "SF Mono", "sans-serif", "serif", "monospace",
  ]

  static func isSystemFace(_ name: String) -> Bool {
    systemNames.contains(name) || name.hasPrefix("SF Pro")
  }

  /// One text style written taller than its source declares.
  struct Raise: Equatable {
    var style: String
    var from: Double
    var to: Double
  }

  struct Outcome: Equatable {
    var raised: [Raise] = []
    /// Families whose first face is neither a system face nor in a file this
    /// reads: their styles are written as declared.
    var unmeasured: [DesignTokenConfig.FontFamily] = []
  }

  /// The face's line height per em: the `hhea` table's ascender − descender
  /// + line gap over the `head` table's units per em, the values CoreText
  /// and Android lay a line out with. Nil for a file this does not read (a
  /// WOFF or WOFF2 file, a collection).
  static func perEm(_ data: Data) -> Double? {
    let bytes = [UInt8](data)
    func u16(_ at: Int) -> Int? {
      at >= 0 && at + 2 <= bytes.count ? Int(bytes[at]) << 8 | Int(bytes[at + 1]) : nil
    }
    func i16(_ at: Int) -> Int? { u16(at).map { $0 >= 0x8000 ? $0 - 0x10000 : $0 } }
    func u32(_ at: Int) -> Int? {
      guard let high = u16(at), let low = u16(at + 2) else { return nil }
      return high << 16 | low
    }
    // TrueType (0x00010000, 'true') and CFF-flavoured OpenType ('OTTO').
    guard let version = u32(0), [0x0001_0000, 0x7472_7565, 0x4F54_544F].contains(version),
          let count = u16(4)
    else { return nil }
    var tables: [String: Int] = [:]
    for index in 0..<count {
      let record = 12 + 16 * index
      guard record + 16 <= bytes.count, let offset = u32(record + 8) else { return nil }
      tables[String(decoding: bytes[record..<record + 4], as: UTF8.self)] = offset
    }
    guard let head = tables["head"], let hhea = tables["hhea"],
          let unitsPerEm = u16(head + 18), unitsPerEm > 0,
          let ascender = i16(hhea + 4), let descender = i16(hhea + 6), let lineGap = i16(hhea + 8)
    else { return nil }
    return Double(ascender - descender + lineGap) / Double(unitsPerEm)
  }

  /// The file a family draws *weight* from: the variable file whose range
  /// holds it, else the file whose weight is nearest.
  static func file(for weight: Int, in face: DesignTokenConfig.FontFace) -> DesignTokenConfig.FontFile? {
    let ranges = face.files.map { file -> (DesignTokenConfig.FontFile, ClosedRange<Int>) in
      let bounds = file.weight.split(separator: " ").compactMap { Int($0) }
      let low = bounds.first ?? 400
      return (file, low...max(low, bounds.last ?? low))
    }
    if let holding = ranges.first(where: { $0.1.contains(weight) }) { return holding.0 }
    func distance(_ range: ClosedRange<Int>) -> Int {
      min(abs(range.lowerBound - weight), abs(range.upperBound - weight))
    }
    return ranges.min { distance($0.1) < distance($1.1) }?.0
  }

  /// Raises every text style whose line height sits under its face's own to
  /// the face's, rounded up to 0.01.
  static func raise(_ config: inout DesignTokenConfig) -> Outcome {
    var outcome = Outcome()
    var measured: [String: Double?] = [:]
    func faceHeight(_ family: DesignTokenConfig.FontFamily, _ weight: Int) -> Double? {
      if let face = config.fontFaces.first(where: { $0.family == family }) {
        guard let file = file(for: weight, in: face) else { return nil }
        if let known = measured[file.source] { return known }
        let value = perEm(file.data)
        measured[file.source] = value
        return value
      }
      // The YAML grammar names no stack: its families are the system faces.
      guard let first = config.firstFaces[family] else { return systemFace }
      return isSystemFace(first) ? systemFace : nil
    }
    for group in config.fonts.indices {
      for index in config.fonts[group].tokens.indices {
        let token = config.fonts[group].tokens[index]
        guard let perEm = faceHeight(token.family, token.weight) else {
          if !outcome.unmeasured.contains(token.family) { outcome.unmeasured.append(token.family) }
          continue
        }
        // The epsilon keeps 34 × 1.22 at 41.48: the product carries binary
        // noise above the hundredth it is.
        let floor = ((token.size * perEm * 100) - 1e-6).rounded(.up) / 100
        guard token.lineHeight < floor else { continue }
        outcome.raised.append(Raise(style: token.name, from: token.lineHeight, to: floor))
        config.fonts[group].tokens[index].lineHeight = floor
      }
    }
    return outcome
  }

  /// One line per raised style and per unmeasured family, for the run's
  /// output and `--json`'s `notices`.
  static func notices(_ outcome: Outcome, config: DesignTokenConfig) -> [String] {
    var lines = outcome.raised.map { raise in
      "text style '\(raise.style)': line height \(DesignTokensJSON.number(raise.from)) is under its face's own, "
        + "so every target is written \(DesignTokensJSON.number(raise.to)); set the token to it or above to silence this"
    }
    for family in outcome.unmeasured {
      let face = config.firstFaces[family].map { "'\($0)'" } ?? "its face"
      lines.append(
        "family '\(family.rawValue)': \(face) is in no font file this reads, so its text styles' line heights "
          + "are written as declared; one under the face's height lays out taller in the apps than on the web. "
          + "Name its files in $extensions[\"\(DTCGSource.extensionKey)\"].files to measure it")
    }
    return lines
  }
}
