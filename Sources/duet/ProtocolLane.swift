// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import DuetReplay
import Foundation

/// The replay-protocol lane (the protocol itself is normative in the framework's
/// contracts/replay-protocol-v1.md): `duet protocol-run` drives every fixture
/// (leaves AND chains — one `reduce` op, CLI-side state slots) through a
/// replay-protocol runner subprocess and byte-gates each step CLI-side.
///
/// The split is what keeps the two flavors from drifting: a flavor exposes only
/// decode→reduce→encode, and the CLI owns fixture reading, step driving,
/// comparison and reporting for all of them (`--runner` drives any conforming
/// runner). The CLI-side writer is the same writer the flavors record through,
/// and `record --check` is its standing byte gate.
enum ProtocolLane {

  // MARK: - Runner selection and coverage

  /// A replay runner's flavor: the side of the manifest its runner serves.
  enum Side: String {
    case swift, kotlin

    var title: String { self == .swift ? "Swift" : "Kotlin" }
  }

  /// What `--platform` and `--runner` ask for, decided before the manifest
  /// is read.
  enum Selection: Equatable {
    /// No `--platform`: one runner — `--runner`'s, else the repo's own (the
    /// Swift `replay-runner` package when the manifest has one, else the
    /// Kotlin lane's) — checked against every feature and chain.
    case defaultRunner
    /// `--platform swift|kotlin|both`: each named side's runner, in this
    /// order, checked against the features and chains that declare its side.
    case sides([Side])
    /// A flag value or combination the verb does not take (exit 2).
    case usage(String)
  }

  static func selection(platform: String?, runner: String?) -> Selection {
    switch platform {
    case nil: return .defaultRunner
    case "swift": return .sides([.swift])
    case "kotlin": return .sides([.kotlin])
    case "both":
      if runner != nil {
        return .usage(
          "--runner drives one prebuilt runner and --platform both builds the repo's two;"
            + " pass one or the other")
      }
      return .sides([.swift, .kotlin])
    case let value?:
      return .usage("--platform takes swift, kotlin or both, got '\(value)'")
    }
  }

  /// Whether a feature declares a side: Swift, a `swift:` path that is
  /// neither empty nor `pending`; Kotlin, a derivable Kotlin lane.
  static func declares(_ feature: Feature, _ side: Side) -> Bool {
    switch side {
    case .swift: return !feature.swiftSource.isEmpty && feature.swiftSource != "pending"
    case .kotlin: return feature.hasKotlinLane
    }
  }

  /// The features and chains one runner is checked against, and those it is
  /// not sent. With a side, `verify`'s coverage rule applies: a feature goes
  /// to the runner of a side it declares, and a chain only while every
  /// participant the manifest declares — the fixture's `initialStates` keys —
  /// declares that side. Without one (the default run) every feature and
  /// chain goes to the runner.
  struct Coverage {
    var features: [Feature] = []
    var chains: [String] = []
    var featuresNotSent: [String] = []
    var chainsNotSent: [String] = []
  }

  static func coverage(
    side: Side?, manifest: Manifest, participants: (String) -> Set<String>
  ) -> Coverage {
    var coverage = Coverage()
    for feature in manifest.features {
      if let side, !declares(feature, side) {
        coverage.featuresNotSent.append(feature.name)
      } else {
        coverage.features.append(feature)
      }
    }
    for chain in manifest.chains {
      let lacking = side.map { side in
        participants(chain).contains { participant in
          manifest.feature(named: participant).map { !declares($0, side) } ?? false
        }
      } ?? false
      if lacking {
        coverage.chainsNotSent.append(chain)
      } else {
        coverage.chains.append(chain)
      }
    }
    return coverage
  }

  // MARK: - protocol-run

  /// One runner's run: which runner, what it was sent, and what diverged.
  struct RunnerResult {
    var side: Side?
    var executable: URL
    var version: Int
    var advertised: Set<String>
    var coverage: Coverage
    var fixturesRun = 0
    var chainsRun = 0
    var stepsRun = 0
    var failures: [String] = []
    var buildSeconds = 0.0
    var spawnSeconds = 0.0
    var replaySeconds = 0.0
  }

  static func run(repo: Repo, options: Options) throws -> Int32 {
    let total = Date()
    // 0. The flags — a value the verb does not take is a usage error, before
    // the manifest is read.
    let selection = selection(platform: options.platform, runner: options.runner)
    if case let .usage(message) = selection {
      if options.json {
        Lanes.emitJSON(["status": "failed", "phase": "usage", "error": "protocol-run: \(message)"])
      } else {
        print("duet protocol-run: \(message)")
      }
      return 2
    }
    let manifest = try Manifest.load(repo: repo)
    if !manifest.lintOK {
      if options.json {
        Lanes.emitJSON(["status": "failed", "phase": "meta", "errors": manifest.lintErrors])
      } else {
        print("lockstep-lint: FAIL — not driving the protocol lane")
        for error in manifest.lintErrors { print("  ✗ \(error)") }
      }
      return 1
    }

    var results: [RunnerResult] = []

    func fail(_ lines: [String], log: URL? = nil) -> Int32 {
      if options.json {
        var report: [String: Any] = ["status": "failed", "error": lines.joined(separator: "\n")]
        if let log { report["log"] = log.path }
        if !results.isEmpty { report["runners"] = results.map { entry(for: $0, in: repo) } }
        Lanes.emitJSON(report)
      } else {
        if let log, let text = try? String(contentsOf: log, encoding: .utf8) {
          print(text.split(separator: "\n").suffix(20).joined(separator: "\n"))
        }
        for line in lines { print(line) }
      }
      return 1
    }

    // The runners to drive, each with the side it is checked as. The default
    // builds one runner: the Kotlin lane's when the manifest has a Kotlin
    // root and no Swift runner package, else the Swift one.
    let defaultSide: Side =
      manifest.androidDir != nil && manifest.replayRunnerPackageDir == nil ? .kotlin : .swift
    let plans: [(side: Side?, filtered: Bool)]
    switch selection {
    case .defaultRunner:
      plans = [(options.runner == nil ? defaultSide : nil, false)]
    case let .sides(sides):
      plans = sides.map { ($0, true) }
    case .usage:
      return 2
    }

    for plan in plans {
      // 1. Ensure the runner is current (the lane's fixed cost — measured,
      // not hidden). `--runner <path>` overrides with a prebuilt executable —
      // the protocol is flavor-neutral (contracts/replay-protocol-v1.md), so
      // any conforming runner drives the same gate. Without an override the
      // CLI builds the side's own runner itself: the Swift `replay-runner`
      // product, or the Kotlin lane's `:replay-runner:installDist` (the
      // caller shouldn't have to hand-build installDist).
      let tag = plan.side.map { " [\($0.rawValue)]" } ?? ""
      var buildSeconds = 0.0
      let executable: URL
      if let override = options.runner {
        executable = URL(fileURLWithPath: override)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
          return fail(["protocol-run\(tag): FAIL — --runner '\(override)' is not an executable"])
        }
      } else {
        switch try buildRunner(plan.side ?? defaultSide, manifest: manifest) {
        case let .built(url, seconds):
          executable = url
          buildSeconds = seconds
        case let .failed(lines, log):
          return fail(lines, log: log)
        }
      }

      // 2. Spawn + handshake.
      let spawn = Date()
      let runner = try RunnerClient(executable: executable)
      guard let handshake = try runner.readLine(),
        (handshake["protocol"] as? String) == "duet-replay",
        let version = handshake["version"] as? Int
      else {
        return fail(["protocol-run\(tag): FAIL — no valid handshake from the replay runner"])
      }
      var result = RunnerResult(
        side: plan.side, executable: executable, version: version,
        advertised: Set(handshake["features"] as? [String] ?? []),
        coverage: coverage(
          side: plan.filtered ? plan.side : nil, manifest: manifest,
          participants: { Lanes.chainParticipants(of: $0, in: repo) }))
      result.buildSeconds = buildSeconds
      result.spawnSeconds = Date().timeIntervalSince(spawn)

      // 3. Drive the fixtures this runner is checked against.
      let replayStart = Date()
      try drive(runner, &result, repo: repo)
      runner.exit()
      result.replaySeconds = Date().timeIntervalSince(replayStart)
      results.append(result)
      if !options.json { printBlock(result) }
    }

    // 4. Report.
    let elapsed = Date().timeIntervalSince(total)
    let failureCount = results.reduce(0) { $0 + $1.failures.count }
    if options.json {
      var report: [String: Any]
      if results.count == 1, let only = results.first {
        // One runner: its report is the top level, as it has always been.
        report = entry(for: only, in: repo)
      } else {
        report = [
          "platform": "both",
          "failures": results.flatMap { result in
            result.failures.map { "[\(result.side?.rawValue ?? "runner")] \($0)" }
          },
        ]
      }
      report["status"] = failureCount == 0 ? "passed" : "failed"
      report["runners"] = results.map { entry(for: $0, in: repo) }
      report["elapsedSeconds"] = elapsed
      Lanes.emitJSON(report)
      return failureCount == 0 ? 0 : 1
    }
    var counts = ""
    if results.count > 1 {
      counts = " — " + results.map { "\($0.side?.rawValue ?? "runner") \($0.failures.count)" }
        .joined(separator: ", ")
    }
    print(
      failureCount == 0
        ? "protocol-run: PASS in \(String(format: "%.1f", elapsed))s"
        : "protocol-run: FAIL (\(failureCount)\(counts)) in \(String(format: "%.1f", elapsed))s")
    return failureCount == 0 ? 0 : 1
  }

  private enum Build {
    case built(URL, Double)
    case failed([String], URL?)
  }

  /// Builds a side's own runner and returns its executable.
  private static func buildRunner(_ side: Side, manifest: Manifest) throws -> Build {
    let tag = " [\(side.rawValue)]"
    switch side {
    case .kotlin:
      guard let androidDir = manifest.androidDir else {
        // Forcing the Kotlin runner on a Swift-only manifest: there is no
        // Gradle tree to build it in — a named refusal, not a crash.
        return .failed(
          [
            "protocol-run\(tag): FAIL — --platform kotlin: the manifest declares no `kotlin:` paths",
            "  (--runner <path> drives any prebuilt conforming runner)",
          ], nil)
      }
      let module = androidDir.appendingPathComponent("replay-runner")
      guard FileManager.default.fileExists(atPath: module.path) else {
        return .failed(
          [
            "protocol-run\(tag): FAIL — no `replay-runner` Gradle module at \(module.path)",
            "  (the Kotlin lane's conforming runner; --runner <path> drives any prebuilt one)",
          ], nil)
      }
      let build = Lanes.finish(
        try Lanes.launch(
          ["./gradlew", ":replay-runner:installDist", "--console=plain"],
          cwd: androidDir, extraEnv: Lanes.gradleEnvironment(),
          logName: "replay-runner-installdist"))
      if build.exitCode != 0 {
        return .failed(
          ["protocol-run\(tag): FAIL — :replay-runner:installDist did not build"], build.logURL)
      }
      let executable = module.appendingPathComponent("build/install/replay-runner/bin/replay-runner")
      guard FileManager.default.isExecutableFile(atPath: executable.path) else {
        return .failed(
          ["protocol-run\(tag): FAIL — installDist produced no launcher at \(executable.path)"], nil)
      }
      return .built(executable, build.seconds)
    case .swift:
      guard let runnerHome = manifest.replayRunnerPackageDir else {
        return .failed(
          [
            "protocol-run\(tag): FAIL — no manifest package root contains Sources/replay-runner",
            "  declare one (`replayRunner: <package dir>` in parity/manifest.yaml) or pass",
            "  a prebuilt conforming runner: --runner <path> (e.g. the Kotlin lane's",
            "  `:replay-runner:installDist` launcher)",
          ], nil)
      }
      let build = Lanes.finish(
        try Lanes.launch(
          ["swift", "build", "--product", "replay-runner"],
          cwd: runnerHome, logName: "replay-runner-build"))
      if build.exitCode != 0 {
        return .failed(["protocol-run\(tag): FAIL — replay-runner did not build"], build.logURL)
      }
      return .built(runnerHome.appendingPathComponent(".build/debug/replay-runner"), build.seconds)
    }
  }

  /// Drives every leaf fixture of the runner's features step by step, actual
  /// state flowing forward, then its chains.
  static func drive(_ runner: RunnerClient, _ result: inout RunnerResult, repo: Repo)
    throws
  {
    let runnerName = result.side.map { "\($0.rawValue) runner" } ?? "runner"
    for feature in result.coverage.features {
      guard result.advertised.contains(feature.name) else {
        result.failures.append("\(feature.name): not advertised by the \(runnerName)")
        continue
      }
      for fixture in feature.fixtures {
        let url = repo.fixturesDir.appendingPathComponent("\(fixture).fixture.json")
        guard let data = try? Data(contentsOf: url),
          let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rawInitial = document["initialState"],
          let rawSteps = document["steps"] as? [[String: Any]]
        else {
          result.failures.append("\(fixture): unreadable fixture")
          continue
        }
        result.fixturesRun += 1
        var stateTree: Any = rawInitial
        for (index, rawStep) in rawSteps.enumerated() {
          guard let action = rawStep["action"],
            let rawExpectedState = rawStep["expectedState"],
            let rawExpectedEffects = rawStep["expectedEffects"]
          else {
            result.failures.append("\(fixture)#\(index): malformed step")
            break
          }
          let response = try runner.request([
            "op": "reduce", "feature": feature.name,
            "state": stateTree, "action": action,
          ])
          guard let actualState = response["state"] as? String,
            let actualEffects = response["effects"] as? String
          else {
            result.failures.append(
              "\(fixture)#\(index): \(response["error"] as? String ?? "no response")")
            break
          }
          result.stepsRun += 1
          let expectedState = try ReplayCanonical.canonicalString(fromJSONObject: rawExpectedState)
          let expectedEffects = try ReplayCanonical.canonicalString(
            fromJSONObject: rawExpectedEffects)
          if actualState != expectedState {
            result.failures.append("\(fixture)#\(index): state diverged")
            break
          }
          if actualEffects != expectedEffects {
            result.failures.append("\(fixture)#\(index): effects diverged")
            break
          }
          stateTree = try JSONSerialization.jsonObject(
            with: Data(actualState.utf8), options: [.fragmentsAllowed])
        }
      }
    }
    // Chains need NO new protocol op: steps carry their `node` key, per-node
    // states seed from `initialStates`, and the hop-DERIVED action is recorded
    // in the fixture. The CLI drives a state slot per node; the hop-derivation
    // authoring check (delegate → action, typed) stays in the in-process
    // scenario lane — pure replay crosses the protocol whole.
    for chain in result.coverage.chains {
      let url = repo.fixturesDir.appendingPathComponent("\(chain).fixture.json")
      guard let data = try? Data(contentsOf: url),
        let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let initialStates = document["initialStates"] as? [String: Any],
        let rawSteps = document["steps"] as? [[String: Any]]
      else {
        result.failures.append("\(chain): unreadable chain fixture")
        continue
      }
      result.chainsRun += 1
      var slots = initialStates
      for (index, rawStep) in rawSteps.enumerated() {
        guard let node = rawStep["node"] as? String,
          let action = rawStep["action"],
          let rawExpectedEffects = rawStep["expectedEffects"],
          let stateTree = slots[node]
        else {
          result.failures.append("\(chain)#\(index): malformed chain step")
          break
        }
        let response = try runner.request([
          "op": "reduce", "feature": node,
          "state": stateTree, "action": action,
        ])
        guard let actualState = response["state"] as? String,
          let actualEffects = response["effects"] as? String
        else {
          result.failures.append(
            "\(chain)#\(index): \(response["error"] as? String ?? "no response")")
          break
        }
        result.stepsRun += 1
        let expectedEffects = try ReplayCanonical.canonicalString(
          fromJSONObject: rawExpectedEffects)
        if actualEffects != expectedEffects {
          result.failures.append("\(chain)#\(index) (\(node)): effects diverged")
          break
        }
        if let rawExpectedState = rawStep["expectedState"] {
          let expectedState = try ReplayCanonical.canonicalString(fromJSONObject: rawExpectedState)
          if actualState != expectedState {
            result.failures.append("\(chain)#\(index) (\(node)): state diverged")
            break
          }
        }
        slots[node] = try JSONSerialization.jsonObject(
          with: Data(actualState.utf8), options: [.fragmentsAllowed])
      }
    }
  }

  /// One runner's `--json` entry.
  private static func entry(for result: RunnerResult, in repo: Repo) -> [String: Any] {
    var entry: [String: Any] = [
      "status": result.failures.isEmpty ? "passed" : "failed",
      "runner": result.executable.path,
      "protocolVersion": result.version,
      "advertised": result.advertised.sorted(),
      "leafFixtures": result.fixturesRun,
      "chainFixtures": result.chainsRun,
      "steps": result.stepsRun,
      "failures": result.failures,
      "runnerBuildSeconds": result.buildSeconds,
      "spawnSeconds": result.spawnSeconds,
      "replaySeconds": result.replaySeconds,
    ]
    if let side = result.side { entry["platform"] = side.rawValue }
    if !result.coverage.featuresNotSent.isEmpty || !result.coverage.chainsNotSent.isEmpty {
      entry["notSent"] = [
        "features": result.coverage.featuresNotSent,
        "chains": result.coverage.chainsNotSent,
      ]
    }
    return entry
  }

  /// One runner's block of the text report; every line names the runner.
  private static func printBlock(_ result: RunnerResult) {
    let tag = result.side.map { " [\($0.rawValue)]" } ?? ""
    print(
      "protocol-run\(tag): duet-replay v\(result.version), \(result.advertised.count) feature(s) "
        + "advertised by \(result.executable.path)")
    print(
      "  runner build \(String(format: "%.2f", result.buildSeconds))s · spawn+handshake "
        + String(format: "%.3f", result.spawnSeconds) + "s · replay "
        + String(format: "%.3f", result.replaySeconds) + "s")
    print(
      "  \(result.fixturesRun) leaf + \(result.chainsRun) chain fixture(s), \(result.stepsRun) "
        + "step(s) byte-gated CLI-side (hop-derivation authoring checks stay in-process)")
    let notSent =
      result.coverage.featuresNotSent
      + result.coverage.chainsNotSent.map { "chain \($0)" }
    if let side = result.side, !notSent.isEmpty {
      print(
        "  not sent to the \(side.rawValue) runner (no \(side.title) side declared): "
          + notSent.joined(separator: ", "))
    }
    for failure in result.failures { print("  ✗\(tag) \(failure)") }
  }

  // MARK: - Runner client

  /// A JSON-lines stdio client for the replay runner subprocess.
  final class RunnerClient {
    private let process = Process()
    private let requests = Pipe()
    private let responses = Pipe()
    private var buffer = Data()

    init(executable: URL) throws {
      process.executableURL = executable
      process.standardInput = requests
      process.standardOutput = responses
      process.standardError = FileHandle.nullDevice
      try process.run()
    }

    func request(_ object: [String: Any]) throws -> [String: Any] {
      let data = try JSONSerialization.data(withJSONObject: object)
      requests.fileHandleForWriting.write(data)
      requests.fileHandleForWriting.write(Data("\n".utf8))
      guard let response = try readLine() else {
        return ["error": "runner closed the stream"]
      }
      return response
    }

    /// Reads one newline-terminated JSON object from the runner's stdout.
    func readLine() throws -> [String: Any]? {
      while true {
        if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
          let line = buffer.subdata(in: buffer.startIndex..<newline)
          buffer.removeSubrange(buffer.startIndex...newline)
          if line.isEmpty { continue }
          return try JSONSerialization.jsonObject(with: line) as? [String: Any]
        }
        let chunk = responses.fileHandleForReading.availableData
        if chunk.isEmpty { return nil }
        buffer.append(chunk)
      }
    }

    func exit() {
      requests.fileHandleForWriting.write(Data("{\"op\":\"exit\"}\n".utf8))
      try? requests.fileHandleForWriting.close()
      process.waitUntilExit()
    }
  }
}
