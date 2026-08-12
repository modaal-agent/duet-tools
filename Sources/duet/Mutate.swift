// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import Foundation

/// `duet mutate` — the mutation drill: seed behavioral mutations one at a time,
/// require the suite to catch every one, and record which lane caught it.
///
/// Each mutation is an exact-string substitution in one platform's sources,
/// declared in parity/mutations.json. The full suite (`duet verify`:
/// meta-checks + every platform lane) runs against the committed fixtures; a
/// mutation "survives" if the suite stays green — which fails the drill,
/// because a survivor is a behavior the corpus does not pin. This makes the
/// negative-control discipline mechanical: add at least one row per migration
/// wave, and the drill re-proves every wave's row on every run.
///
/// A row targets SOURCES, so it goes stale when sources move — unlike
/// fixtures, which outlive refactors. A stale row (`old` no longer matching
/// exactly once) is a config-error that FAILS the run, so the drill sweeps
/// its own table instead of relying on discipline.
///
/// Not served over MCP on purpose: the drill runs the full suite once per row
/// plus a baseline — minutes, not seconds — outside the MCP surface's
/// synchronous seconds-fast contract.
enum Mutate {
  struct Mutation {
    let name: String
    /// Repo-relative source path the substitution applies to.
    let file: String
    /// Exact string to replace — must match the file exactly once.
    let old: String
    let new: String
    /// The defect this mutation would ship — the row's claim, rendered in the
    /// receipt table.
    let seeds: String
  }

  /// One suite run's verdict, as the drill consumes it. `lanes` names what
  /// went red ("swift+kotlin", "meta", "coverage"); `detail` is the first
  /// failure line — a pointer, not the log.
  struct SuiteVerdict {
    let green: Bool
    let lanes: String
    let detail: String
    let hung: Bool

    init(green: Bool, lanes: String = "", detail: String = "", hung: Bool = false) {
      self.green = green
      self.lanes = lanes
      self.detail = detail
      self.hung = hung
    }
  }

  enum MutateError: Error, CustomStringConvertible {
    case noTable(String)
    case badTable(String)
    case unknownMutation(String, known: [String])

    var description: String {
      switch self {
      case let .noTable(path):
        return """
          no mutation table at \(path) — the drill needs one. Shape:
            {"mutations": [{"name": "<row id>", "file": "<repo-relative source>",
              "old": "<exact string, must match once>", "new": "<replacement>",
              "seeds": "<the defect this mutation would ship>"}]}
          """
      case let .badTable(detail):
        return "parity/mutations.json: \(detail)"
      case let .unknownMutation(name, known):
        return
          "unknown mutation '\(name)' — the table declares: \(known.joined(separator: ", "))"
      }
    }
  }

  /// A suite that produces no verdict in this window is treated as hung. A
  /// hang never goes green, so the mutation IS detected — but it is a far
  /// worse detection mode than a red test, and the terminated run's lane
  /// children can survive to hold build locks, so a hang also stops the drill
  /// (see the hung-verdict handling in `run`).
  static let suiteTimeoutSeconds: TimeInterval = 600

  // MARK: - The table

  static func table(repo: Repo) throws -> [Mutation] {
    let url = repo.root.appendingPathComponent("parity/mutations.json")
    guard let data = try? Data(contentsOf: url) else {
      throw MutateError.noTable(url.path)
    }
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let rows = root["mutations"] as? [[String: Any]]
    else {
      throw MutateError.badTable("not a JSON object with a `mutations` array")
    }
    guard !rows.isEmpty else {
      throw MutateError.badTable(
        "the `mutations` array is empty — a drill that seeds nothing proves nothing")
    }
    var seen = Set<String>()
    return try rows.enumerated().map { index, row in
      guard let name = row["name"] as? String, !name.isEmpty,
        let file = row["file"] as? String, !file.isEmpty,
        let old = row["old"] as? String, !old.isEmpty,
        let new = row["new"] as? String,
        let seeds = row["seeds"] as? String, !seeds.isEmpty
      else {
        throw MutateError.badTable(
          "row \(index + 1): every row needs non-empty `name`, `file`, `old`, `seeds`"
            + " and a `new` string")
      }
      guard old != new else {
        throw MutateError.badTable("'\(name)': `old` and `new` are identical — the row mutates nothing")
      }
      guard seen.insert(name).inserted else {
        throw MutateError.badTable("duplicate mutation name '\(name)'")
      }
      return Mutation(name: name, file: file, old: old, new: new, seeds: seeds)
    }
  }

  // MARK: - The drill

  /// `duet mutate [<name>] [--json]`. `suite` is injectable for tests; the
  /// production default re-invokes this executable's `verify --json`.
  static func run(
    repo: Repo, options: Options, suite: ((Repo) -> SuiteVerdict)? = nil
  ) throws -> Int32 {
    let start = Date()
    let runSuite = suite ?? { defaultSuite(repo: $0) }
    var rows = try table(repo: repo)
    if let name = options.target {
      guard let row = rows.first(where: { $0.name == name }) else {
        throw MutateError.unknownMutation(name, known: rows.map(\.name))
      }
      rows = [row]
    }

    // Baseline: a red tree makes every verdict meaningless (each mutation
    // would "be caught" by the pre-existing failure). The baseline is also
    // the infrastructure canary — a broken verify invocation aborts here
    // instead of turning every row into a false "caught".
    if !options.json { print("duet mutate: verifying the clean tree is green first…") }
    let baseline = runSuite(repo)
    guard baseline.green else {
      if options.json {
        Lanes.emitJSON([
          "status": "aborted", "phase": "baseline",
          "lanes": baseline.lanes, "detail": baseline.detail,
        ])
      } else {
        print("duet mutate: ABORT — the suite is red before any mutation")
        if !baseline.detail.isEmpty { print("  \(baseline.detail)") }
        print("  fix the tree (duet verify), then re-run")
      }
      return 1
    }

    struct Row {
      let mutation: Mutation
      let verdict: String  // "caught" | "survived" | "config-error" | "skipped"
      let lanes: String
      let detail: String
    }
    var results: [Row] = []
    var survived = 0
    var configErrors = 0
    var hungAfter: String?

    for mutation in rows {
      if let hungRow = hungAfter {
        // Terminating a hung verify cannot reach its lane children (they share
        // this process's group — no group-kill without killing the drill), so
        // stray gradle/swift-test processes may still hold build locks and
        // would corrupt every later verdict. Stop instead of drilling on.
        results.append(
          Row(
            mutation: mutation, verdict: "skipped", lanes: "",
            detail: "drill stopped after '\(hungRow)' hung"))
        continue
      }
      let url = repo.root.appendingPathComponent(mutation.file)
      guard let source = try? String(contentsOf: url, encoding: .utf8) else {
        configErrors += 1
        results.append(
          Row(
            mutation: mutation, verdict: "config-error", lanes: "",
            detail: "\(mutation.file): not readable — the target moved; sweep the table"))
        if !options.json { print("  !! \(mutation.name): \(mutation.file) not readable — stale row") }
        continue
      }
      let matches = source.components(separatedBy: mutation.old).count - 1
      guard matches == 1 else {
        configErrors += 1
        results.append(
          Row(
            mutation: mutation, verdict: "config-error", lanes: "",
            detail: "`old` matches \(matches) time(s) — must match exactly once; sweep the table"))
        if !options.json {
          print("  !! \(mutation.name): `old` matches \(matches) time(s) — stale row")
        }
        continue
      }

      // Name the seeded file before the long suite run: an interrupted drill
      // (^C, SIGKILL) leaves the mutation on disk with no chance to restore,
      // so the operator must know what to check.
      if !options.json {
        print("  seeding \(mutation.name) → \(mutation.file)")
        print("    (if interrupted, restore with: git checkout -- \(mutation.file))")
      }
      try Data(source.replacingOccurrences(of: mutation.old, with: mutation.new).utf8)
        .write(to: url)
      let verdict = runSuite(repo)
      // Restore the exact prior bytes — never `git checkout`, which would also
      // discard any uncommitted edits the file carried before the drill.
      do {
        try Data(source.utf8).write(to: url)
      } catch {
        let warning =
          "duet mutate: FAILED TO RESTORE \(mutation.file)"
          + " — restore by hand: git checkout -- \(mutation.file)\n"
        FileHandle.standardError.write(Data(warning.utf8))
        throw error
      }

      if verdict.green {
        survived += 1
        results.append(
          Row(
            mutation: mutation, verdict: "survived", lanes: "",
            detail: "the corpus does not pin this behavior"))
        if !options.json { print("  ✗ \(mutation.name): SURVIVED — the corpus does not pin this behavior") }
      } else {
        results.append(
          Row(mutation: mutation, verdict: "caught", lanes: verdict.lanes, detail: verdict.detail))
        if !options.json { print("  ✓ \(mutation.name): caught by [\(verdict.lanes)]") }
        if verdict.hung { hungAfter = mutation.name }
      }
    }

    let caught = results.filter { $0.verdict == "caught" }.count
    let skipped = results.filter { $0.verdict == "skipped" }.count
    let failed = survived + configErrors + skipped > 0
    let elapsed = Date().timeIntervalSince(start)

    if options.json {
      var payload: [String: Any] = [
        "status": failed ? "failed" : "passed",
        "elapsedSeconds": elapsed,
        "caught": caught,
        "survived": survived,
        "configErrors": configErrors,
        "mutations": results.map { row in
          [
            "name": row.mutation.name, "file": row.mutation.file,
            "seeds": row.mutation.seeds, "verdict": row.verdict,
            "lanes": row.lanes, "detail": row.detail,
          ] as [String: Any]
        },
      ]
      if skipped > 0 { payload["skipped"] = skipped }
      Lanes.emitJSON(payload)
      return failed ? 1 : 0
    }

    // The receipt table — paste into a wave's log as-is.
    print("")
    print("| # | Mutation | Seeds | Result | Detail |")
    print("| --- | --- | --- | --- | --- |")
    for (index, row) in results.enumerated() {
      let result = row.verdict == "caught" ? "caught: \(row.lanes)" : row.verdict.uppercased()
      let detail = row.detail.replacingOccurrences(of: "|", with: "\\|")
      print("| \(index + 1) | `\(row.mutation.name)` | \(row.mutation.seeds) | \(result) | \(detail) |")
    }
    print("")
    if failed {
      var parts: [String] = []
      if survived > 0 { parts.append("\(survived) survived") }
      if configErrors > 0 { parts.append("\(configErrors) config-error(s)") }
      if skipped > 0 { parts.append("\(skipped) skipped after a hang") }
      print(
        "duet mutate: FAIL — \(parts.joined(separator: ", ")) of \(results.count)"
          + " in \(String(format: "%.1f", elapsed))s")
      return 1
    }
    print(
      "duet mutate: PASS — \(caught)/\(results.count) caught"
        + " in \(String(format: "%.1f", elapsed))s")
    return 0
  }

  // MARK: - The production suite

  /// Re-invokes THIS executable's `verify --json` as a subprocess — the MCP
  /// server's dispatch pattern: the verbs print to stdout, so in-process
  /// dispatch would tangle the drill's own report with verify's. The verdict
  /// is read from verify's structured report, not grepped from prose.
  static func defaultSuite(repo: Repo) -> SuiteVerdict {
    let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
    guard
      let launched = try? Lanes.launch(
        [executable, "verify", "--json"], cwd: repo.root, logName: "mutate-verify")
    else {
      return SuiteVerdict(green: false, lanes: "?", detail: "could not launch \(executable) verify")
    }
    let (process, logURL, _) = launched
    let deadline = Date().addingTimeInterval(suiteTimeoutSeconds)
    while process.isRunning && Date() < deadline {
      Thread.sleep(forTimeInterval: 1)
    }
    if process.isRunning {
      process.terminate()
      return SuiteVerdict(
        green: false, lanes: "hang",
        detail: "no verdict within \(Int(suiteTimeoutSeconds))s — counts as caught, but fix the hang",
        hung: true)
    }
    let data = (try? Data(contentsOf: logURL)) ?? Data()
    var payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    if payload == nil, let text = String(data: data, encoding: .utf8),
      let brace = text.firstIndex(of: "{")
    {
      payload =
        (try? JSONSerialization.jsonObject(with: Data(text[brace...].utf8))) as? [String: Any]
    }
    if process.terminationStatus == 0 { return SuiteVerdict(green: true) }
    return SuiteVerdict(
      green: false, lanes: rednessLanes(of: payload),
      detail: firstFailure(of: payload).isEmpty
        ? "verify red with no parseable report — log: \(logURL.path)"
        : firstFailure(of: payload))
  }

  /// Which part of the run went red, from verify's structured report: "meta"
  /// (lint / host-lane / spec cross-reference), the red platform lanes, and
  /// "coverage" for missing fixture reports. "?" when the report is
  /// unreadable (verify crashed before emitting one) — still red, so still
  /// caught.
  static func rednessLanes(of payload: [String: Any]?) -> String {
    guard let payload else { return "?" }
    if payload["phase"] as? String == "meta" { return "meta" }
    var lanes: [String] = []
    let laneMap = payload["lanes"] as? [String: Any] ?? [:]
    if let swift = laneMap["swift"] as? [[String: Any]],
      swift.contains(where: { ($0["exit"] as? Int) != 0 })
    {
      lanes.append("swift")
    }
    if let kotlin = laneMap["kotlin"] as? [String: Any], (kotlin["exit"] as? Int) != 0 {
      lanes.append("kotlin")
    }
    if let missing = payload["missingReports"] as? [String], !missing.isEmpty {
      lanes.append("coverage")
    }
    return lanes.isEmpty ? "?" : lanes.joined(separator: "+")
  }

  /// The first failure line from the report — the mined lane log lines first
  /// (they name the failing row), then a failed fixture report's rendered
  /// header, then a meta error. Capped: a pointer into the report, not a
  /// replacement for it.
  static func firstFailure(of payload: [String: Any]?) -> String {
    guard let payload else { return "" }
    let laneMap = payload["lanes"] as? [String: Any] ?? [:]
    var lines: [String] = []
    for lane in laneMap["swift"] as? [[String: Any]] ?? [] {
      lines += lane["failureLines"] as? [String] ?? []
    }
    if let kotlin = laneMap["kotlin"] as? [String: Any] {
      lines += kotlin["failureLines"] as? [String] ?? []
    }
    if let first = lines.first { return String(first.prefix(160)) }
    for report in payload["reports"] as? [[String: Any]] ?? []
    where (report["status"] as? String) == "failed" {
      for failure in report["failures"] as? [[String: Any]] ?? [] {
        if let rendered = failure["rendered"] as? String,
          let firstLine = rendered.split(separator: "\n").first
        {
          return String(firstLine.prefix(160))
        }
      }
    }
    if let errors = payload["errors"] as? [String], let first = errors.first {
      return String(first.prefix(160))
    }
    return ""
  }
}
