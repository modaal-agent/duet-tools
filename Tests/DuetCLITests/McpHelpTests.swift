// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import XCTest

@testable import DuetCLI

/// `duet help` names every tool `duet mcp` serves. The usage text is a global
/// in main.swift, which a test cannot read once the module is imported (its
/// top-level code never runs), so the test reads the source file.
final class McpHelpTests: XCTestCase {

  func testHelpNamesEveryServedTool() throws {
    let source = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // DuetCLITests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // the package root
      .appendingPathComponent("Sources/duet/main.swift")
    let text = try String(contentsOf: source, encoding: .utf8)
    let start = try XCTUnwrap(text.range(of: "\n    duet mcp\n"), "no `duet mcp` entry in the usage text")
    let rest = text[start.upperBound...]
    let end = rest.range(of: "\n    duet ")?.lowerBound ?? rest.endIndex
    let paragraph = rest[..<end]

    let served = Mcp.toolCatalog().compactMap { $0["name"] as? String }
    XCTAssertEqual(served.count, 9)
    for name in served {
      XCTAssertTrue(paragraph.contains(name), "`duet help` does not name \(name)")
    }
  }
}
