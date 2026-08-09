// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import Foundation

/// `duet assert-replayed <log|-> [--min <n>] [--json]` — the empty-pass gate as a
/// verb (A29 R3). The family rule "a lane that passed without replaying is a
/// failure" is enforced inside `duet verify` by the fixture coverage gate; every
/// hand-written lane script around a bare `swift test` / `gradlew` re-acquires
/// the hole, because `swift test` exits 0 when it discovers ZERO tests. This verb
/// owns the assertion: feed it the lane's log (or pipe it on stdin as `-`) and it
/// fails unless the executed-test count reaches `--min` (default 1).
///
/// The count is the MAXIMUM across runner summaries, never the presence of a
/// zero: `swift test` drives XCTest and swift-testing together and always prints
/// both summaries, so a package using one runner shows the other's zero line on
/// a perfectly green run.
enum AssertReplayed {
  /// Highest executed-test count any runner summary in the log reports.
  /// Matched shapes:
  ///   XCTest:        Executed 12 tests, with 0 failures …
  ///   swift-testing: ✔ Test run with 5 tests passed after …
  ///   Gradle:        97 tests completed, 1 failed
  static func maxExecuted(inLog log: String) -> Int {
    var maxCount = 0
    for line in log.split(separator: "\n") {
      let text = String(line)
      for prefix in ["Executed ", "Test run with "] {
        var search = Substring(text)
        while let range = search.range(of: prefix) {
          let digits = search[range.upperBound...].prefix(while: \.isNumber)
          search = search[range.upperBound...]
          guard let count = Int(digits) else { continue }
          // Both shapes read "… N test(s) …" — require the word to avoid
          // matching unrelated "Executed <n> …" prose.
          guard search.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
            .hasPrefix("test")
          else { continue }
          maxCount = max(maxCount, count)
        }
      }
      if let range = text.range(of: " tests completed") {
        let head = text[..<range.lowerBound]
        let digits = head.reversed().prefix(while: \.isNumber).reversed()
        if let count = Int(String(digits)) { maxCount = max(maxCount, count) }
      }
    }
    return maxCount
  }

  static func run(options: Options) -> Int32 {
    guard let target = options.target else {
      FileHandle.standardError.write(
        Data("duet assert-replayed: no log given (usage: duet assert-replayed <log|-> [--min <n>])\n".utf8))
      return 2
    }
    let log: String
    if target == "-" {
      let data = FileHandle.standardInput.readDataToEndOfFile()
      log = String(decoding: data, as: UTF8.self)
    } else if let text = try? String(contentsOfFile: target, encoding: .utf8) {
      log = text
    } else {
      FileHandle.standardError.write(
        Data("duet assert-replayed: cannot read \(target)\n".utf8))
      return 2
    }
    let minimum = options.min ?? 1
    let executed = maxExecuted(inLog: log)
    let passed = executed >= minimum
    if options.json {
      Lanes.emitJSON([
        "status": passed ? "passed" : "failed",
        "executed": executed,
        "min": minimum,
      ])
      return passed ? 0 : 1
    }
    if passed {
      print("duet assert-replayed: \(executed) test(s) executed (min \(minimum))")
      return 0
    }
    print("duet assert-replayed: FAIL — max across runner summaries is \(executed), min \(minimum).")
    print("  A lane that passed without replaying is a failure: `swift test` exits 0")
    print("  when it discovers zero tests, and both runner summaries (XCTest's")
    print("  'Executed N tests', swift-testing's 'Test run with N tests') print on")
    print("  every run — the assertion takes the maximum, never the presence of a zero.")
    return 1
  }
}
