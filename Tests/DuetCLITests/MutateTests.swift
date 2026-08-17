// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import XCTest

@testable import DuetCLI

final class MutateTests: XCTestCase {

  // MARK: - Harness

  /// A throwaway repo root with an optional mutation table and source files.
  /// `Repo` is a plain struct over a root URL, so no `parity/fixtures`
  /// discovery is involved — tests construct it directly.
  private func makeRepo(
    table: String? = nil, files: [String: String] = [:]
  ) throws -> Repo {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("duet-mutate-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("parity"), withIntermediateDirectories: true)
    if let table {
      try Data(table.utf8).write(to: root.appendingPathComponent("parity/mutations.json"))
    }
    for (path, content) in files {
      let url = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(content.utf8).write(to: url)
    }
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return Repo(root: root)
  }

  private func jsonOptions(target: String? = nil) -> Options {
    var options = Options()
    options.command = "mutate"
    options.json = true
    options.target = target
    return options
  }

  private let oneRowTable = """
    {"mutations": [{"name": "flip-guard", "file": "src/Feature.kt",
      "old": "if (ready)", "new": "if (true)", "seeds": "readiness guard dropped"}]}
    """
  private let featureSource = "fun reduce() {\n  if (ready) { go() }\n}\n"

  // MARK: - Table validation

  func testMissingTableThrowsWithTheShape() throws {
    let repo = try makeRepo()
    XCTAssertThrowsError(try Mutate.table(repo: repo)) { error in
      XCTAssertTrue("\(error)".contains("no mutation table"))
      XCTAssertTrue("\(error)".contains("\"mutations\""))
    }
  }

  func testRowMissingSeedsThrows() throws {
    let repo = try makeRepo(
      table: """
        {"mutations": [{"name": "x", "file": "f", "old": "a", "new": "b"}]}
        """)
    XCTAssertThrowsError(try Mutate.table(repo: repo)) { error in
      XCTAssertTrue("\(error)".contains("row 1"))
    }
  }

  func testIdenticalOldAndNewThrows() throws {
    let repo = try makeRepo(
      table: """
        {"mutations": [{"name": "x", "file": "f", "old": "a", "new": "a", "seeds": "s"}]}
        """)
    XCTAssertThrowsError(try Mutate.table(repo: repo)) { error in
      XCTAssertTrue("\(error)".contains("mutates nothing"))
    }
  }

  func testDuplicateNameThrows() throws {
    let repo = try makeRepo(
      table: """
        {"mutations": [
          {"name": "x", "file": "f", "old": "a", "new": "b", "seeds": "s"},
          {"name": "x", "file": "f", "old": "c", "new": "d", "seeds": "s"}]}
        """)
    XCTAssertThrowsError(try Mutate.table(repo: repo)) { error in
      XCTAssertTrue("\(error)".contains("duplicate"))
    }
  }

  func testEmptyTableThrows() throws {
    let repo = try makeRepo(table: #"{"mutations": []}"#)
    XCTAssertThrowsError(try Mutate.table(repo: repo)) { error in
      XCTAssertTrue("\(error)".contains("seeds nothing"))
    }
  }

  func testEmptyNewIsAllowed() throws {
    // Deleting a line is a legitimate behavioral mutation.
    let repo = try makeRepo(
      table: """
        {"mutations": [{"name": "x", "file": "f", "old": "a", "new": "", "seeds": "s"}]}
        """)
    XCTAssertEqual(try Mutate.table(repo: repo).count, 1)
  }

  // MARK: - The drill

  func testCaughtMutationPassesAndRestores() throws {
    let repo = try makeRepo(table: oneRowTable, files: ["src/Feature.kt": featureSource])
    let sourceURL = repo.root.appendingPathComponent("src/Feature.kt")
    var suiteContents: [String] = []
    let code = try Mutate.run(repo: repo, options: jsonOptions()) { _ in
      suiteContents.append((try? String(contentsOf: sourceURL, encoding: .utf8)) ?? "")
      // Baseline green; the mutated run red (the suite "catches" it).
      return Mutate.SuiteVerdict(
        green: suiteContents.count == 1, lanes: "kotlin", detail: "GoldenTest > replay FAILED")
    }
    XCTAssertEqual(code, 0)
    XCTAssertEqual(suiteContents.count, 2)
    XCTAssertEqual(suiteContents[0], featureSource, "baseline runs on the clean tree")
    XCTAssertTrue(suiteContents[1].contains("if (true)"), "the suite saw the mutation")
    XCTAssertEqual(
      try String(contentsOf: sourceURL, encoding: .utf8), featureSource,
      "the mutation is restored after the run")
  }

  func testSurvivorFailsTheDrill() throws {
    let repo = try makeRepo(table: oneRowTable, files: ["src/Feature.kt": featureSource])
    let code = try Mutate.run(repo: repo, options: jsonOptions()) { _ in
      Mutate.SuiteVerdict(green: true)  // never goes red — the mutation survives
    }
    XCTAssertEqual(code, 1)
    XCTAssertEqual(
      try String(
        contentsOf: repo.root.appendingPathComponent("src/Feature.kt"), encoding: .utf8),
      featureSource, "a survivor is still restored")
  }

  func testRedBaselineAbortsWithoutMutating() throws {
    let repo = try makeRepo(table: oneRowTable, files: ["src/Feature.kt": featureSource])
    var calls = 0
    let code = try Mutate.run(repo: repo, options: jsonOptions()) { _ in
      calls += 1
      return Mutate.SuiteVerdict(green: false, lanes: "swift", detail: "pre-existing red")
    }
    XCTAssertEqual(code, 1)
    XCTAssertEqual(calls, 1, "no mutation is seeded on a red tree")
  }

  func testStaleRowIsAConfigErrorNotACrash() throws {
    // `old` matches nothing — the target moved. The drill must fail with a
    // finding, not crash, and must not run the suite for the stale row.
    let repo = try makeRepo(
      table: """
        {"mutations": [{"name": "stale", "file": "src/Feature.kt",
          "old": "no such string", "new": "x", "seeds": "s"}]}
        """, files: ["src/Feature.kt": featureSource])
    var calls = 0
    let code = try Mutate.run(repo: repo, options: jsonOptions()) { _ in
      calls += 1
      return Mutate.SuiteVerdict(green: true)
    }
    XCTAssertEqual(code, 1)
    XCTAssertEqual(calls, 1, "baseline only — a stale row never mutates or runs the suite")
  }

  func testAmbiguousOldIsAConfigError() throws {
    let repo = try makeRepo(
      table: """
        {"mutations": [{"name": "ambiguous", "file": "src/Feature.kt",
          "old": "if", "new": "when", "seeds": "s"}]}
        """, files: ["src/Feature.kt": "if a\nif b\n"])
    let code = try Mutate.run(repo: repo, options: jsonOptions()) { _ in
      Mutate.SuiteVerdict(green: true)
    }
    XCTAssertEqual(code, 1)
    XCTAssertEqual(
      try String(
        contentsOf: repo.root.appendingPathComponent("src/Feature.kt"), encoding: .utf8),
      "if a\nif b\n", "an ambiguous row never touches the file")
  }

  func testMissingSourceFileIsAConfigError() throws {
    let repo = try makeRepo(table: oneRowTable)  // no src/Feature.kt on disk
    let code = try Mutate.run(repo: repo, options: jsonOptions()) { _ in
      Mutate.SuiteVerdict(green: true)
    }
    XCTAssertEqual(code, 1)
  }

  func testScopedRunByName() throws {
    let repo = try makeRepo(
      table: """
        {"mutations": [
          {"name": "one", "file": "src/A.kt", "old": "alpha", "new": "beta", "seeds": "s1"},
          {"name": "two", "file": "src/B.kt", "old": "gamma", "new": "delta", "seeds": "s2"}]}
        """,
      files: ["src/A.kt": "alpha\n", "src/B.kt": "gamma\n"])
    var mutatedB: [String] = []
    let code = try Mutate.run(repo: repo, options: jsonOptions(target: "two")) { _ in
      mutatedB.append(
        (try? String(
          contentsOf: repo.root.appendingPathComponent("src/B.kt"), encoding: .utf8)) ?? "")
      return Mutate.SuiteVerdict(green: mutatedB.count == 1, lanes: "kotlin", detail: "")
    }
    XCTAssertEqual(code, 0)
    XCTAssertEqual(mutatedB.count, 2, "baseline + the one scoped row")
    XCTAssertEqual(mutatedB[1], "delta\n", "only the named row is seeded")
    XCTAssertEqual(
      try String(contentsOf: repo.root.appendingPathComponent("src/A.kt"), encoding: .utf8),
      "alpha\n", "the other row's file is never touched")
  }

  func testUnknownNameThrowsListingTheTable() throws {
    let repo = try makeRepo(table: oneRowTable, files: ["src/Feature.kt": featureSource])
    XCTAssertThrowsError(
      try Mutate.run(repo: repo, options: jsonOptions(target: "nope")) { _ in
        Mutate.SuiteVerdict(green: true)
      }
    ) { error in
      XCTAssertTrue("\(error)".contains("flip-guard"))
    }
  }

  func testHangStopsTheDrill() throws {
    // After a hung suite the terminated run's lane children can still hold
    // build locks, so later rows must be skipped, and a skipped row fails
    // the drill.
    let repo = try makeRepo(
      table: """
        {"mutations": [
          {"name": "one", "file": "src/A.kt", "old": "alpha", "new": "beta", "seeds": "s1"},
          {"name": "two", "file": "src/B.kt", "old": "gamma", "new": "delta", "seeds": "s2"}]}
        """,
      files: ["src/A.kt": "alpha\n", "src/B.kt": "gamma\n"])
    var calls = 0
    let code = try Mutate.run(repo: repo, options: jsonOptions()) { _ in
      calls += 1
      if calls == 1 { return Mutate.SuiteVerdict(green: true) }  // baseline
      return Mutate.SuiteVerdict(green: false, lanes: "hang", detail: "timed out", hung: true)
    }
    XCTAssertEqual(code, 1)
    XCTAssertEqual(calls, 2, "row two never runs after the hang")
    XCTAssertEqual(
      try String(contentsOf: repo.root.appendingPathComponent("src/A.kt"), encoding: .utf8),
      "alpha\n", "the hung row is still restored")
  }

  // MARK: - Verdict parsing (verify's structured report → lanes + detail)

  func testRednessLanesReadsTheVerifyReport() {
    XCTAssertEqual(Mutate.rednessLanes(of: nil), "?")
    XCTAssertEqual(Mutate.rednessLanes(of: ["phase": "meta"]), "meta")
    XCTAssertEqual(
      Mutate.rednessLanes(of: [
        "lanes": [
          "swift": [["exit": 1], ["exit": 0]],
          "kotlin": ["exit": 1],
        ]
      ]), "swift+kotlin")
    XCTAssertEqual(
      Mutate.rednessLanes(of: [
        "lanes": ["swift": [["exit": 0]]],
        "missingReports": ["timeline [kotlin]"],
      ]), "coverage")
  }

  func testFirstFailurePrefersMinedLaneLines() {
    let payload: [String: Any] = [
      "lanes": [
        "kotlin": [
          "exit": 1,
          "failureLines": ["com.example.TimelineGoldenTest > replay FAILED"],
        ]
      ],
      "reports": [
        [
          "status": "failed",
          "failures": [["rendered": "✗ 'timeline' — divergence\npath: /x"]],
        ]
      ],
    ]
    XCTAssertEqual(
      Mutate.firstFailure(of: payload), "com.example.TimelineGoldenTest > replay FAILED")
  }

  func testFirstFailureFallsBackToReportsThenMetaErrors() {
    XCTAssertEqual(
      Mutate.firstFailure(of: [
        "reports": [
          [
            "status": "failed",
            "failures": [["rendered": "✗ 'timeline' — divergence\npath: /x"]],
          ]
        ]
      ]), "✗ 'timeline' — divergence")
    XCTAssertEqual(
      Mutate.firstFailure(of: ["errors": ["lockstep: manifest names a missing file"]]),
      "lockstep: manifest names a missing file")
  }
}
