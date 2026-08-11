// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import Foundation

/// Subprocess plumbing + the `duet verify` and `duet record` commands.
enum Lanes {
  struct ProcessResult {
    let exitCode: Int32
    let logURL: URL
    let seconds: Double
  }

  /// Launches a process with output captured to a log file. `wait: false` returns
  /// immediately (caller pairs it with `finish`).
  static func launch(
    _ arguments: [String], cwd: URL, extraEnv: [String: String] = [:], logName: String
  ) throws -> (Process, URL, Date) {
    let logURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("duet-\(logName)-\(ProcessInfo.processInfo.processIdentifier).log")
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    let handle = try FileHandle(forWritingTo: logURL)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    process.currentDirectoryURL = cwd
    var environment = ProcessInfo.processInfo.environment
    for (key, value) in extraEnv { environment[key] = value }
    process.environment = environment
    process.standardOutput = handle
    process.standardError = handle
    // Lane children must never read the interactive terminal: the Gradle daemon
    // client forwards stdin, and a TTY read from a background process group stops
    // the whole client JVM (SIGTTIN) AFTER "BUILD SUCCESSFUL" — a dual-lane
    // `verify` from a real terminal then hangs in waitUntilExit forever. /dev/null
    // gives every lane instant EOF, which is also what CI provides.
    process.standardInput = FileHandle.nullDevice
    let start = Date()
    try process.run()
    return (process, logURL, start)
  }

  static func finish(_ triple: (Process, URL, Date)) -> ProcessResult {
    let (process, logURL, start) = triple
    process.waitUntilExit()
    return ProcessResult(
      exitCode: process.terminationStatus, logURL: logURL,
      seconds: Date().timeIntervalSince(start))
  }

  /// The Gradle lane needs JAVA_HOME (21) to *configure* even the JVM-only test
  /// task. The Android SDK location is repo/machine config, not toolchain config —
  /// Gradle reads `<android>/local.properties` (sdk.dir) or the caller's
  /// ANDROID_HOME itself; the CLI adds neither.
  static func gradleEnvironment() -> [String: String] {
    var env: [String: String] = [:]
    let current = ProcessInfo.processInfo.environment
    if current["JAVA_HOME"] == nil {
      let probe = Process()
      probe.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
      probe.arguments = ["-v", "21"]
      let pipe = Pipe()
      probe.standardOutput = pipe
      probe.standardError = FileHandle.nullDevice
      if (try? probe.run()) != nil {
        probe.waitUntilExit()
        if probe.terminationStatus == 0,
          let data = try? pipe.fileHandleForReading.readToEnd(),
          let home = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
          !home.isEmpty
        {
          env["JAVA_HOME"] = home
        }
      }
    }
    return env
  }

  // MARK: - Reports

  static func clearReports(_ repo: Repo) {
    try? FileManager.default.removeItem(at: repo.runsDir)
  }

  /// All fixture reports written by the runners this run, `[platform: [report]]`.
  static func readReports(_ repo: Repo) -> [[String: Any]] {
    var reports: [[String: Any]] = []
    for platform in (try? FileManager.default.contentsOfDirectory(atPath: repo.runsDir.path)) ?? [] {
      let dir = repo.runsDir.appendingPathComponent(platform)
      for file in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
      where file.hasSuffix(".json") {
        if let data = try? Data(contentsOf: dir.appendingPathComponent(file)),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
          reports.append(object)
        }
      }
    }
    return reports.sorted {
      (($0["fixture"] as? String) ?? "") < (($1["fixture"] as? String) ?? "")
    }
  }

  /// Failures carry their own runner-rendered block (`rendered`) — the CLI prints it
  /// verbatim and only tags the platform on the header line. One formatter per
  /// platform (the runners'), zero here.
  static func renderedText(failure: [String: Any], of report: [String: Any]) -> String {
    let platform = report["platform"] as? String ?? "?"
    guard let text = failure["rendered"] as? String, !text.isEmpty else {
      let fixture = report["fixture"] as? String ?? "?"
      let kind = failure["kind"] as? String ?? "?"
      return "✗ '\(fixture)' — \(kind) (report has no rendered block — pre-FT2 runner?)   [\(platform)]"
    }
    guard let newline = text.firstIndex(of: "\n") else {
      return "\(text)   [\(platform)]"
    }
    return text.replacingCharacters(in: newline..<newline, with: "   [\(platform)]")
  }

  static func failedReports(_ reports: [[String: Any]]) -> [[String: Any]] {
    reports.filter { ($0["status"] as? String) == "failed" }
  }

  /// Failure lines mined from a red lane's log — the no-fixture-report path's
  /// pointer to WHAT failed, not just where the log is. A fixed tail can scroll
  /// past the one line that names the failing test (it did, in the first adopter
  /// CI run under this shape: "97 tests, 1 failure" with the row's name
  /// unrecoverable from the output). Matched per line, one shape per toolchain
  /// the lanes run:
  ///   XCTest row:      Test Case '-[Suite test]' failed (0.019 seconds).
  ///   XCTest detail /
  ///   swiftc error:    /path/File.swift:42: error: …
  ///   swift-testing:   ✘ Test "x" recorded an issue …
  ///   Swift trap:      Fatal error: …
  ///   Gradle test row: com.example.FooTest > bar FAILED
  ///   Gradle task /
  ///   build:           > Task :x:test FAILED · FAILURE: Build failed · BUILD FAILED in …
  ///   kotlinc:         e: file:///…/Foo.kt:12:3 …
  /// Suite-level "failed at" lines are deliberately not matched — the case line
  /// names the row; the suite line is noise. Capped: this is a pointer into the
  /// log, not a replacement for it.
  static func failureLines(inLogAt url: URL, cap: Int = 40) -> [String] {
    guard let log = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    let markers = ["' failed (", ": error:", "✘", "Fatal error", " FAILED", "FAILURE:"]
    var found: [String] = []
    var elided = 0
    for line in log.split(separator: "\n") {
      let text = String(line)
      guard markers.contains(where: { text.contains($0) }) || text.hasPrefix("e: ") else {
        continue
      }
      if found.count < cap { found.append(text) } else { elided += 1 }
    }
    if elided > 0 { found.append("… +\(elided) more failure line(s) — see the log") }
    return found
  }

  // MARK: - Commands

  /// `duet verify [--feature X] [--swift-only|--kotlin-only] [--json]`
  static func run(repo: Repo, options: Options) throws -> Int32 {
    let start = Date()
    // Loading the manifest IS the meta-check (lockstep-lint --json) — a stale
    // manifest makes lane results unreliable, so a lint failure stops here.
    let manifest = try Manifest.load(repo: repo)
    if !manifest.lintOK {
      if options.json {
        emitJSON(["status": "failed", "phase": "meta", "errors": manifest.lintErrors])
      } else {
        print("lockstep-lint: FAIL")
        for error in manifest.lintErrors { print("  ✗ \(error)") }
        print("duet verify: FAIL (meta-checks) — not running platform lanes")
      }
      return 1
    }
    // The host-lane rule, toolchain-owned (HostLane.swift): what a gated unit
    // RESOLVES, on both build systems — a lane result over a leaky graph is
    // sitting on toolchain surface the gate does not test, so this stops the
    // run exactly like a lint failure.
    let hostLaneErrors = HostLane.check(repo: repo, manifest: manifest)
    if !hostLaneErrors.isEmpty {
      if options.json {
        emitJSON(["status": "failed", "phase": "meta", "errors": hostLaneErrors])
      } else {
        print("host-lane check: FAIL")
        for error in hostLaneErrors { print("  ✗ \(error)") }
        print("duet verify: FAIL (meta-checks) — not running platform lanes")
      }
      return 1
    }
    // The spec↔fixture cross-reference (graduated spec-fixture-lint): the
    // prose one-pagers must track the corpus. Applies only to repos carrying
    // parity/feature-specs/ — the adopter's opt-in to the prose discipline.
    if let specErrors = SpecFixtureLint.check(repo: repo, manifest: manifest),
      !specErrors.isEmpty
    {
      if options.json {
        emitJSON(["status": "failed", "phase": "meta", "errors": specErrors])
      } else {
        print("spec-fixture check: FAIL")
        for error in specErrors { print("  ✗ \(error)") }
        print("duet verify: FAIL (meta-checks) — not running platform lanes")
      }
      return 1
    }
    // The lane-task shape lint (A29 R4) — advisory, never a failure: a repo's
    // own automation naming fewer lane tasks than the manifest derives is how
    // a migration silently stops running migrated modules' suites.
    let laneTaskWarnings = LaneTaskLint.warnings(repo: repo, manifest: manifest)
    if !options.json {
      print("duet verify: meta-checks ok")
      for warning in laneTaskWarnings { print("  ⚠ lane-task shape: \(warning)") }
    }
    let feature = try options.resolveFeature(in: manifest)
    // A lane flag naming a lane the manifest does not derive is a meta-error,
    // not a silent green: with both lanes skipped, the coverage gate below
    // expects nothing and the run would report PASS having replayed nothing.
    let flagMismatch: String? =
      options.kotlinOnly && manifest.androidDir == nil
      ? "--kotlin-only: the manifest declares no `kotlin:` paths — there is no Kotlin lane to run"
      : options.swiftOnly && manifest.swiftPackageDirs.isEmpty
        ? "--swift-only: the manifest declares no `swift:` paths — there is no Swift lane to run"
        : nil
    if let flagMismatch {
      if options.json {
        emitJSON(["status": "failed", "phase": "meta", "errors": [flagMismatch]])
      } else {
        print("duet verify: FAIL — \(flagMismatch)")
      }
      return 1
    }
    clearReports(repo)

    var swiftResults: [(package: String, result: ProcessResult)] = []
    var kotlinResult: ProcessResult?
    var swiftLaunches: [(package: String, launch: (Process, URL, Date))] = []
    var kotlinLaunch: (Process, URL, Date)?

    if !options.kotlinOnly {
      // One host lane per package root, all in parallel (F5: subtree re-cuts
      // spread the features across packages); a scoped run needs only the
      // feature's own root. Reports land in the shared parity/.runs dir, so the
      // coverage gate below is package-agnostic.
      let roots: [URL]
      if let feature = feature {
        if feature.swiftSource.isEmpty {
          // Mid-migration coexistence: a migrated feature declares no `swift:`
          // twin — its only host lane is the Kotlin one, so a scoped run skips
          // the Swift lane instead of failing to derive a root for it.
          roots = []
        } else if let own = manifest.swiftPackageDir(of: feature) {
          roots = [own]
        } else {
          print("duet verify: cannot derive the Swift package root for '\(feature.name)'")
          return 1
        }
      } else {
        roots = manifest.swiftPackageDirs
      }
      for root in roots {
        var arguments = ["swift", "test"]
        if let target = feature?.swiftTestTarget {
          arguments += ["--filter", target]
        }
        let package = relativePath(root, in: repo)
        swiftLaunches.append(
          (package, try launch(arguments, cwd: root, logName: "swift-\(root.lastPathComponent)")))
      }
    }
    // A Swift-only manifest derives no Kotlin lane (androidDir nil) — the
    // mirror of the empty-roots skip above.
    if !options.swiftOnly, let androidDir = manifest.androidDir {
      let tasks = feature?.gradleTestTask.map { [$0] } ?? manifest.unscopedGradleTasks
      // --rerun: an up-to-date Gradle test task would silently skip the replays and
      // write no reports — a "PASS" that verified nothing (caught by the coverage
      // check below, but rerunning is the correct behavior for a verification tool).
      // It is a TASK option (binds to the task named right before it), not a build
      // flag — a mixed tree names one lane task per module shape, and each needs
      // its own --rerun or the earlier one stays UP-TO-DATE and writes no reports
      // into the parity/.runs directory this run just wiped.
      kotlinLaunch = try launch(
        ["./gradlew"] + tasks.flatMap { [$0, "--rerun"] } + ["--console=plain"],
        cwd: androidDir,
        extraEnv: gradleEnvironment(), logName: "kotlin")
    }
    // Lanes stream to their log files, not the console — say so before waiting,
    // else a stalled lane is an undiagnosable blank screen.
    if !options.json {
      var running: [String] = []
      for entry in swiftLaunches { running.append("swift[\(entry.package)] \(entry.launch.1.path)") }
      if let launch = kotlinLaunch { running.append("kotlin \(launch.1.path)") }
      print("duet verify: lanes running — logs: \(running.joined(separator: " · "))")
    }
    for entry in swiftLaunches { swiftResults.append((entry.package, finish(entry.launch))) }
    if let launch = kotlinLaunch { kotlinResult = finish(launch) }

    let reports = readReports(repo)
    let failed = failedReports(reports)
    let elapsed = Date().timeIntervalSince(start)

    // Coverage gate: every expected fixture must have reported on every requested
    // platform — a lane that "passed" without replaying is a failure, not a pass.
    // Unscoped runs expect the chain fixtures too.
    var expectedFixtures = (feature.map { [$0] } ?? manifest.features)
      .flatMap { $0.fixtures }
    if feature == nil { expectedFixtures += manifest.chains }
    var missing: [String] = []
    for fixture in expectedFixtures {
      for platform in ["swift", "kotlin"] {
        // A single-source repo has one lane: no `swift:` twins (KMP flavor)
        // means the swift half of the gate doesn't apply; no `kotlin:` paths
        // (Swift-only flavor) means the kotlin half doesn't — flag or no flag.
        if platform == "swift" && (options.kotlinOnly || manifest.swiftPackageDirs.isEmpty) {
          continue
        }
        if platform == "kotlin" && (options.swiftOnly || manifest.androidDir == nil) {
          continue
        }
        // Mid-migration coexistence: a fixture owned by a feature with only one
        // declared side reports from that side's lane only (no `swift:` twin →
        // Kotlin lane; no Kotlin lane — empty or `pending` — → Swift lane).
        if platform == "swift",
          let owner = manifest.feature(forFixture: fixture), owner.swiftSource.isEmpty
        {
          continue
        }
        if platform == "kotlin",
          let owner = manifest.feature(forFixture: fixture), !owner.hasKotlinLane
        {
          continue
        }
        // Chain rows follow their participants (0.4.0): a chain expects a
        // Swift-lane row only while EVERY participant feature still has a
        // `swift:` twin — the aggregator's chain scenario cannot compile a
        // retired twin's reducer, so its authoring retires with the twin and
        // the committed fixture is frozen bytes (Kotlin replay + the protocol
        // lane keep gating it) until the chain corpus itself ports. The
        // participant set is the fixture's own `initialStates` keys — the
        // same derivation the spec↔fixture meta-check uses.
        if platform == "swift", manifest.chains.contains(fixture),
          chainParticipants(of: fixture, in: repo).contains(where: { participant in
            manifest.features.first { $0.name == participant }?.swiftSource.isEmpty == true
          })
        {
          continue
        }
        // The kotlin mirror of the participant rule: a chain expects a
        // kotlin-lane row only while every participant has a Kotlin lane.
        if platform == "kotlin", manifest.chains.contains(fixture),
          chainParticipants(of: fixture, in: repo).contains(where: { participant in
            manifest.features.first { $0.name == participant }?.hasKotlinLane == false
          })
        {
          continue
        }
        if !reports.contains(where: {
          ($0["fixture"] as? String) == fixture && ($0["platform"] as? String) == platform
        }) {
          missing.append("\(fixture) [\(platform)]")
        }
      }
    }

    let laneFailed =
      swiftResults.contains { $0.result.exitCode != 0 }
      || (kotlinResult.map { $0.exitCode != 0 } ?? false)
      || !missing.isEmpty

    // What this run makes NO claim about (A29 R2) — silence reads as coverage,
    // so the gate names its own boundary: build units outside the manifest and
    // the protocol lane. Scoped runs state their scope instead.
    let coverage: Inventory.Coverage? = feature == nil
      ? Inventory.coverage(repo: repo, manifest: manifest) : nil

    if options.json {
      var lanes: [String: Any] = [:]
      if !swiftResults.isEmpty {
        // One entry per package root (an array since F5's multi-package layout).
        lanes["swift"] = swiftResults.map { entry in
          var lane: [String: Any] = [
            "package": entry.package, "exit": Int(entry.result.exitCode),
            "seconds": entry.result.seconds, "log": entry.result.logURL.path,
          ]
          if entry.result.exitCode != 0 {
            lane["failureLines"] = failureLines(inLogAt: entry.result.logURL)
          }
          return lane
        }
      }
      if let result = kotlinResult {
        var lane: [String: Any] = [
          "exit": Int(result.exitCode), "seconds": result.seconds, "log": result.logURL.path,
        ]
        if result.exitCode != 0 {
          lane["failureLines"] = failureLines(inLogAt: result.logURL)
        }
        lanes["kotlin"] = lane
      }
      var payload: [String: Any] = [
        "status": laneFailed ? "failed" : "passed",
        "elapsedSeconds": elapsed,
        "lanes": lanes,
        "missingReports": missing,
        "reports": reports,
        "warnings": laneTaskWarnings,
      ]
      if let coverage {
        payload["notCovered"] = [
          "gradleModules": coverage.gradleModulesOutsideManifest,
          "swiftPackages": coverage.swiftPackagesOutsideManifest,
          "swiftPackagesWithUnrunTests": coverage.swiftPackagesWithUnrunTests,
          "lanes": ["the protocol lane (duet protocol-run)"],
        ] as [String: Any]
      }
      emitJSON(payload)
      return laneFailed ? 1 : 0
    }

    if swiftResults.isEmpty {
      print("  - swift  lane skipped")
    } else {
      for entry in swiftResults {
        let mark = entry.result.exitCode == 0 ? "✓" : "✗"
        print(
          "  \(mark) swift  \(entry.package) (\(String(format: "%.1f", entry.result.seconds))s)")
      }
    }
    if let result = kotlinResult {
      let mark = result.exitCode == 0 ? "✓" : "✗"
      print("  \(mark) kotlin lane (\(String(format: "%.1f", result.seconds))s)")
    } else {
      print("  - kotlin lane skipped")
    }

    let passedCount = reports.count - failed.count
    print("duet verify: \(passedCount)/\(reports.count) fixture report(s) passed")
    if !missing.isEmpty {
      print("✗ missing fixture report(s) — lane ran but did not replay these:")
      for entry in missing { print("    \(entry)") }
      // The two platforms miss for different reasons — name the fix, not just the
      // gap (the Swift scenario replays its leaves itself; Kotlin needs the
      // per-leaf @Test convention).
      if missing.contains(where: { $0.hasSuffix("[kotlin]") }) {
        print("  fix [kotlin]: every Branch leaf needs its own replay method — add")
        print("      `@Test fun <leaf>Leaf() = replay(\"<feature>.<leaf>\")` to the feature's")
        print("      <Feature>GoldenTest.kt (chains: the chain fixture tests, e.g. ChainFixtureTest.kt)")
      }
      if missing.contains(where: { $0.hasSuffix("[swift]") }) {
        print("  fix [swift]: the scenario did not replay this leaf — check the Branch exists")
        print("      in the scenario, then `duet record --feature <feature>` and re-run")
      }
    }
    for report in failed {
      for failure in report["failures"] as? [[String: Any]] ?? [] {
        print(renderedText(failure: failure, of: report))
      }
    }
    // A red lane with zero failed fixture reports = infrastructure failure (compile
    // error, crashed suite, a red non-fixture test) — no report explains it, so
    // mine the log: the failure lines first (they name the row), then the tail
    // for surrounding context.
    if laneFailed && failed.isEmpty {
      let redResults = swiftResults.map(\.result) + [kotlinResult].compactMap { $0 }
      for result in redResults where result.exitCode != 0 {
        let mined = failureLines(inLogAt: result.logURL)
        if !mined.isEmpty {
          print("--- failure lines (\(result.logURL.path)) ---")
          for line in mined { print(line) }
        }
        let log = (try? String(contentsOf: result.logURL, encoding: .utf8)) ?? ""
        print("--- log tail (\(result.logURL.path)) ---")
        print(log.split(separator: "\n").suffix(30).joined(separator: "\n"))
      }
    }
    if let coverage {
      var outside: [String] = []
      if !coverage.gradleModulesOutsideManifest.isEmpty {
        outside.append(
          "gradle modules \(coverage.gradleModulesOutsideManifest.joined(separator: " "))")
      }
      if !coverage.swiftPackagesOutsideManifest.isEmpty {
        outside.append(
          "swift package(s) \(coverage.swiftPackagesOutsideManifest.joined(separator: " "))")
      }
      outside.append("the protocol lane (run `duet protocol-run`)")
      print("not covered by verify — run these in your workflow: \(outside.joined(separator: " · "))")
      // Narrow enough to act on, unlike the list above: these declare tests and
      // have never been resolved as a root, so nothing has ever run them.
      if !coverage.swiftPackagesWithUnrunTests.isEmpty {
        print(
          "  of those, tests that have never run anywhere: "
            + coverage.swiftPackagesWithUnrunTests.joined(separator: " ")
            + " — `duet doctor` fails on these")
      }
    } else {
      print("coverage: scoped run — the landing gate is unscoped `duet verify`")
    }
    print(
      laneFailed
        ? "duet verify: FAIL in \(String(format: "%.1f", elapsed))s"
        : "duet verify: PASS in \(String(format: "%.1f", elapsed))s")
    return laneFailed ? 1 : 0
  }

  /// `duet record [--feature X] [--platform swift|kotlin] [--check] [--json]` —
  /// scoped fixture regeneration via the scenario runners, then a review summary.
  /// Recording is a *source-generation* step: the diff is meant to be reviewed like
  /// code (bless-by-git). `--platform kotlin` records through the Kotlin runner
  /// (`-PregenFixtures=1`); the §6 shared writer makes the two platforms' outputs
  /// byte-identical for equivalent scenarios. `--check` is the CI regen gate:
  /// exit 1 if any fixture was stale relative to its scenario.
  /// (No lint gate here on purpose — record is how a lint-red tree gets repaired.)
  static func record(repo: Repo, options: Options) throws -> Int32 {
    let manifest = try Manifest.load(repo: repo)
    let feature = try options.resolveFeature(in: manifest)
    if feature != nil, options.chain != nil {
      let message = "scope with --feature or --chain, not both"
      if options.json {
        emitJSON(["status": "failed", "phase": "meta", "errors": [message]])
      } else {
        print("duet record: FAIL — \(message)")
      }
      return 1
    }
    if let chain = options.chain, !manifest.chains.contains(chain) {
      let message = "unknown chain '\(chain)' (not in parity/manifest.yaml chains)"
      if options.json {
        emitJSON(["status": "failed", "phase": "meta", "errors": [message]])
      } else {
        print("duet record: FAIL — \(message)")
      }
      return 1
    }
    // The dual-writer guard (A30 R3): while a feature declares BOTH a `swift:`
    // twin and a Kotlin `scenario:`, two writers exist for its fixture files.
    // Unscoped record runs every Swift root under REGEN, so the retiring twin
    // would re-record fixtures the Kotlin scenario owns — refuse, with the
    // scoped verbs as the in-window recording paths.
    let dualWriters = manifest.features.filter(\.isDualWriter).map(\.name)
    if feature == nil, options.chain == nil, !dualWriters.isEmpty {
      let message =
        "dual-writer feature(s) in the manifest: \(dualWriters.joined(separator: ", "))"
        + " — a `swift:` twin plus a Kotlin `scenario:` is two writers for the same"
        + " fixtures, and an unscoped pass re-records through the retiring Swift twin."
        + " Record scoped inside the window: `duet record --feature <name>` (the writer"
        + " follows the manifest's scenario) or `duet record --chain <name>`."
      if options.json {
        emitJSON(["status": "failed", "phase": "meta", "errors": [message]])
      } else {
        print("duet record: REFUSED — \(message)")
      }
      return 1
    }
    // A single-source (KMP-flavor) repo records through its only lane — the
    // Kotlin runner — without the caller having to say so; likewise a scoped
    // record of a feature whose scenario is Kotlin-authored (a migrated feature
    // has no `swift:` twin at all; a dual-writer feature mid-port still
    // declares one, but the manifest's ONE scenario is the writer of record and
    // it runs in the Gradle lane).
    let platform =
      options.platform
      ?? ((manifest.swiftPackageDirs.isEmpty || feature?.swiftSource.isEmpty == true
        || feature?.hasKotlinScenario == true)
        ? "kotlin" : nil)
    // Snapshot fixture bytes so the summary lists what THIS run rewrote (git diff
    // would also show unrelated uncommitted fixture changes).
    let before = fixtureDigests(repo)
    // The ceremony killer rides record (§2.2 — no separate pipeline step): the
    // Swift lane regenerates the committed sum coders BEFORE recording, so the
    // fixtures compile against current coders; in --check mode stale coders fail
    // fast, before any lane runs. Kotlin-platform record skips this — the coder
    // files are the Swift flavor's.
    if platform != "kotlin" {
      let regen = try CanonicalSumVerb.regenerate(
        repo: repo, manifest: manifest, check: options.check)
      if !regen.stale.isEmpty {
        if options.json {
          emitJSON(["status": "failed", "phase": "canonical-sum", "stale": regen.stale])
        } else {
          print("duet record --check: FAIL — stale generated coder file(s):")
          for path in regen.stale { print("  \(path)") }
          print("regenerate and commit: duet record (regen is folded in)")
        }
        return 1
      }
      if !regen.written.isEmpty, !options.json {
        print("duet record: regenerated \(regen.written.count) sum-coder file(s):")
        for path in regen.written { print("  \(path)") }
      }
    }
    // Stale artifacts from an earlier record pass must not re-materialize.
    RecordArtifacts.clear(repo)
    if options.check {
      try? FileManager.default.removeItem(
        at: repo.runsDir.appendingPathComponent("record-check"))
    }
    // Scoped Kotlin record pre-deletes the feature's declared fixtures: the
    // Kotlin FixtureRunner regenerates MISSING files only, and the lane task
    // also runs the feature's golden replays — so against a behavioral change
    // the committed files fail their own replay before the writer ever runs,
    // and the writer would skip them anyway. Deleting first turns both into
    // the regeneration path (bless-by-git makes the delete safe). `--check`
    // asks whether the committed files are stale, so it must replay them —
    // never pre-delete there. The Swift writer overwrites under REGEN and the
    // scoped Swift record filters to the scenario class, so the Swift path
    // needs none of this.
    var preDeleted: [String] = []
    if let feature = feature, platform == "kotlin", !options.check {
      for fixture in feature.fixtures {
        let file = "\(fixture).fixture.json"
        let url = repo.fixturesDir.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else { continue }
        try? FileManager.default.removeItem(at: url)
        preDeleted.append(file)
      }
      if !preDeleted.isEmpty, !options.json {
        print(
          "duet record: pre-deleted \(preDeleted.count) committed fixture(s) so the"
            + " Kotlin writer regenerates them (it skips existing files)")
      }
    }
    var results: [ProcessResult] = []
    if let chain = options.chain {
      // `record --chain <name>` (A30 R1): the manifest declares chains as
      // fixture names only — no per-chain module entry — so the recording
      // scope is DISCOVERED: the test sources that mention the fixture by
      // name (quoted), grouped into runnable scopes. That covers a chain
      // whose participants share no aggregator module, the case a --feature
      // scope cannot reach and the two-writers rule forbids reaching
      // unscoped.
      let hosts = chainHosts(of: chain, repo: repo, manifest: manifest)
      if hosts.gradleTaskStems.isEmpty && hosts.swiftRootStems.isEmpty {
        let message =
          "no test source under the manifest's roots mentions \"\(chain)\" — the chain"
          + " has no discoverable recording path; add its scenario (and replay test) first"
        if options.json {
          emitJSON(["status": "failed", "phase": "meta", "errors": [message]])
        } else {
          print("duet record: FAIL — \(message)")
        }
        return 1
      }
      var launches: [(Process, URL, Date)] = []
      if !hosts.gradleTaskStems.isEmpty, let androidDir = manifest.androidDir {
        var arguments = ["./gradlew"]
        for (task, stems) in hosts.gradleTaskStems.sorted(by: { $0.key < $1.key }) {
          arguments.append(task)
          // --tests binds to the task named right before it, like --rerun.
          for stem in stems.sorted() { arguments += ["--tests", "*.\(stem)"] }
          arguments.append("--rerun")
        }
        arguments += ["-PregenFixtures=1", "--console=plain"]
        launches.append(
          try launch(
            arguments, cwd: androidDir, extraEnv: gradleEnvironment(),
            logName: "record-chain"))
      }
      for (root, stems) in hosts.swiftRootStems.sorted(by: { $0.key.path < $1.key.path }) {
        var arguments = ["swift", "test"]
        for stem in stems.sorted() { arguments += ["--filter", stem] }
        launches.append(
          try launch(
            arguments, cwd: root, extraEnv: ["REGEN_FIXTURES": "1"],
            logName: "record-chain-\(root.lastPathComponent)"))
      }
      results = launches.map(finish)
    } else if platform == "kotlin" {
      // Reachable only by explicit --platform kotlin on a Swift-only manifest —
      // the defaulting above never picks kotlin without a Kotlin root.
      guard let androidDir = manifest.androidDir else {
        let message =
          "--platform kotlin: the manifest declares no `kotlin:` paths — "
          + "there is no Kotlin runner to record through"
        if options.json {
          emitJSON(["status": "failed", "phase": "meta", "errors": [message]])
        } else {
          print("duet record: FAIL — \(message)")
        }
        return 1
      }
      let tasks = feature?.gradleTestTask.map { [$0] } ?? manifest.unscopedGradleTasks
      // Per-task --rerun: same note as verify — it binds to the task named
      // right before it, and a mixed tree names one lane task per module shape.
      results.append(
        finish(
          try launch(
            ["./gradlew"] + tasks.flatMap { [$0, "--rerun"] }
              + ["-PregenFixtures=1", "--console=plain"],
            cwd: androidDir, extraEnv: gradleEnvironment(), logName: "record")))
    } else if let feature = feature {
      guard let own = manifest.swiftPackageDir(of: feature) else {
        print("duet record: cannot derive the Swift package root for '\(feature.name)'")
        return 1
      }
      var arguments = ["swift", "test"]
      if let scenario = feature.scenario {
        let className = URL(fileURLWithPath: scenario)
          .deletingPathExtension().lastPathComponent
        arguments += ["--filter", className]
      }
      results.append(
        finish(
          try launch(
            arguments, cwd: own, extraEnv: ["REGEN_FIXTURES": "1"], logName: "record")))
    } else {
      // Unscoped: every package root records its scenarios, in parallel — each
      // feature's writer touches only its own fixture files, chains record from
      // the aggregator, so concurrent lanes never contend on an output.
      var launches = try manifest.swiftPackageDirs.map { root in
        try launch(
          ["swift", "test"], cwd: root, extraEnv: ["REGEN_FIXTURES": "1"],
          logName: "record-\(root.lastPathComponent)")
      }
      // Mid-migration coexistence: a migrated feature's scenario lives in
      // Kotlin (its `swift:` twin is gone), so the Swift roots cannot
      // regenerate its fixtures — without this leg the unscoped drift gate
      // would silently stop covering every ported feature for the whole
      // sweep. One extra Gradle launch records exactly those features'
      // scoped lane tasks, in parallel with the Swift roots (per-feature
      // writers never contend on an output).
      let migratedTasks = manifest.features
        .filter(\.swiftSource.isEmpty).compactMap(\.gradleTestTask)
      // A non-empty task list implies a derivable Kotlin root (the tasks come
      // from `kotlin:` paths) — the binding is for the optional, not a branch.
      if !migratedTasks.isEmpty, let androidDir = manifest.androidDir {
        launches.append(
          try launch(
            ["./gradlew"] + migratedTasks.flatMap { [$0, "--rerun"] }
              + ["-PregenFixtures=1", "--console=plain"],
            cwd: androidDir, extraEnv: gradleEnvironment(),
            logName: "record-kotlin"))
      }
      results = launches.map(finish)
    }
    if results.contains(where: { $0.exitCode != 0 }) {
      // A red lane may have written a partial rewrite already (the Swift
      // runners write directly) — a failing --check leaves the fixture tree
      // byte-identical (A30 R2), on this path too.
      if options.check, !options.write { restoreFixtures(repo, to: before) }
      // A failed record must not leave the tree with fewer fixtures than it
      // found: put back what the pre-delete removed and the run did not
      // rewrite (partial rewrites stay, as on every non-check failure).
      for file in preDeleted {
        let url = repo.fixturesDir.appendingPathComponent(file)
        if !FileManager.default.fileExists(atPath: url.path), let original = before[file] {
          try? original.whole.write(to: url)
        }
      }
      var logs: [String] = []
      for result in results where result.exitCode != 0 {
        let log = (try? String(contentsOf: result.logURL, encoding: .utf8)) ?? ""
        logs.append(log)
        if !options.json {
          print(log.split(separator: "\n").suffix(30).joined(separator: "\n"))
        }
      }
      if options.json {
        emitJSON(["status": "failed", "log": logs.joined(separator: "\n")])
      } else {
        print("duet record: FAIL — fixtures not (fully) regenerated")
      }
      return 1
    }
    // The Kotlin runner records to compact artifacts (it ships no on-disk writer);
    // materialize them through the one §6 writer. The Swift runner writes files
    // directly through the same writer — its pass leaves no artifacts.
    _ = try RecordArtifacts.materialize(repo)
    let after = fixtureDigests(repo)
    let changed = after
      .filter { name, digest in before[name]?.whole != digest.whole }
      .keys.sorted()
    // The drift gate's split (the wave oracle): a scenario-language port
    // rewrites fixture METADATA (scenario.source, step label/line) by design —
    // the sole admissible diff — while a behavioral rewrite is a port defect.
    // `--check` gates the replay protocol's field set only and reports the
    // metadata half as admissible churn.
    let behavioralChanged = changed.filter { before[$0]?.behavioral != after[$0]?.behavioral }
    let metadataOnly = changed.filter { !behavioralChanged.contains($0) }
    if options.check {
      // A failing --check must not materialize its rewrite (A30 R2): the
      // recorded output moves to parity/.runs/record-check/ and the committed
      // tree is restored byte-identically, so a drift control needs a source
      // restore only, never a fixture-tree one. --write keeps the rewrite in
      // the tree (the inspect-in-place repair path).
      var rewriteDir: String?
      if !behavioralChanged.isEmpty, !options.write {
        rewriteDir = saveRecordCheckRewrite(repo, changed: changed)
        restoreFixtures(repo, to: before)
      }
      if options.json {
        var payload: [String: Any] = [
          "status": behavioralChanged.isEmpty ? "passed" : "failed",
          "stale": behavioralChanged, "metadataOnly": metadataOnly,
        ]
        if let rewriteDir {
          payload["fixtureTree"] = "untouched"
          payload["rewriteDir"] = rewriteDir
        }
        emitJSON(payload)
      } else if changed.isEmpty {
        print("duet record --check: fixtures are up to date with their scenarios")
      } else if behavioralChanged.isEmpty {
        print(
          "duet record --check: metadata-only churn in \(metadataOnly.count) fixture(s) "
            + "(admissible — behavioral fields unchanged):")
        for file in metadataOnly { print("  parity/fixtures/\(file)") }
        print("commit the refreshed metadata with the change that moved the scenario")
      } else {
        print(
          "duet record --check: FAIL — behavioral drift in \(behavioralChanged.count) fixture(s):")
        for file in behavioralChanged { print("  parity/fixtures/\(file)") }
        if !metadataOnly.isEmpty {
          print("  (+ \(metadataOnly.count) metadata-only rewrite(s) — admissible)")
        }
        if let rewriteDir {
          print("parity/fixtures is untouched — the would-be rewrite is under \(rewriteDir)/")
          print("materialize it with `duet record` (fixtures are build products — never hand-edit)")
        } else {
          print("commit the regenerated fixtures (fixtures are build products — never hand-edit)")
        }
      }
      return behavioralChanged.isEmpty ? 0 : 1
    }
    // A pre-deleted fixture the run did not regenerate is a REMOVAL, invisible
    // to the changed-vs-before diff (the file is simply absent from `after`) —
    // report it, or "no fixture changes" would read over a vanished file.
    let removed = preDeleted.filter { after[$0] == nil }
    if options.json {
      var payload: [String: Any] = [
        "status": "passed", "regenerated": changed, "metadataOnly": metadataOnly,
      ]
      if !removed.isEmpty { payload["removed"] = removed }
      emitJSON(payload)
    } else {
      if changed.isEmpty, removed.isEmpty {
        print("duet record: no fixture changes (recorded output identical)")
      } else {
        if !changed.isEmpty {
          print("duet record: rewrote \(changed.count) fixture(s):")
          for file in changed {
            let tag = metadataOnly.contains(file) ? "   (metadata-only)" : ""
            print("  parity/fixtures/\(file)\(tag)")
          }
        }
        if !removed.isEmpty {
          print(
            "duet record: \(removed.count) fixture(s) deleted and NOT regenerated —"
              + " the scenario no longer records them:")
          for file in removed { print("  parity/fixtures/\(file)") }
          print("retire them from parity/manifest.yaml, or restore via git if this is a defect")
        }
        print("review the diff (git diff -- parity/fixtures), then run `duet verify` for both lanes")
      }
    }
    return 0
  }

  /// Repo-root-relative rendering of an absolute path (for lane labels).
  static func relativePath(_ url: URL, in repo: Repo) -> String {
    let rootPath = repo.root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    return path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : path
  }

  /// Per-fixture snapshots, split for the drift gate: the whole file, and the
  /// BEHAVIORAL subset — the replay protocol's field set (leaves:
  /// `initialState` + each step's `action`/`expectedState`/`expectedEffects`;
  /// chains: `initialStates` + the step's `node` as well). Everything else
  /// (`scenario.source`, step `label`/`line`, `description`) is authoring
  /// metadata: a scenario-language port rewrites it by design, so
  /// `record --check` gates only the behavioral half.
  ///
  /// Full BYTES, deliberately not `Data.hashValue`: Foundation's Data hash
  /// considers only the first ~80 bytes plus the length (NSData `-hash`
  /// bridging, verified empirically), so a same-length change past the header
  /// hashes EQUAL — the earlier hash-based gate could read green over real
  /// drift. A corpus of fixtures is small; hold the bytes and compare them.
  struct FixtureDigest {
    let whole: Data
    let behavioral: Data
  }

  /// The features a chain fixture spans — its `initialStates` keys (one store
  /// per participant), the same derivation the spec↔fixture meta-check uses.
  /// Unreadable fixture → empty set, which keeps the strict default (the
  /// swift-lane row stays expected).
  static func chainParticipants(of chain: String, in repo: Repo) -> Set<String> {
    guard
      let data = try? Data(
        contentsOf: repo.fixturesDir.appendingPathComponent("\(chain).fixture.json")),
      let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let initialStates = document["initialStates"] as? [String: Any]
    else { return [] }
    return Set(initialStates.keys)
  }

  /// The runnable scopes hosting a chain's tests: Gradle lane task → test-class
  /// stems, Swift package root → test-class stems.
  struct ChainHosts {
    var gradleTaskStems: [String: Set<String>] = [:]
    var swiftRootStems: [URL: Set<String>] = [:]
  }

  /// Test sources that mention the chain fixture by name (quoted — the replay
  /// convention passes the fixture name as a string literal), grouped into
  /// runnable scopes. Only test source sets are searched: they are the only
  /// files a lane task can run, and deriving the task needs the source set
  /// anyway (`commonTest` runs on the JVM as `jvmTest`).
  private static func chainHosts(of chain: String, repo: Repo, manifest: Manifest)
    -> ChainHosts
  {
    var hosts = ChainHosts()
    let needle = "\"\(chain)\""
    if let androidDir = manifest.androidDir,
      let enumerator = FileManager.default.enumerator(
        at: androidDir, includingPropertiesForKeys: nil)
    {
      for case let url as URL in enumerator {
        let name = url.lastPathComponent
        if ["build", ".gradle", ".git", ".kotlin"].contains(name) {
          enumerator.skipDescendants()
          continue
        }
        guard name.hasSuffix(".kt") else { continue }
        let androidPath = androidDir.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(androidPath + "/") else { continue }
        let parts = path.dropFirst(androidPath.count + 1).split(separator: "/")
          .map(String.init)
        guard let srcIndex = parts.firstIndex(of: "src"), srcIndex > 0,
          srcIndex + 1 < parts.count
        else { continue }
        let taskName: String
        switch parts[srcIndex + 1] {
        case "test": taskName = "test"
        case "jvmTest", "commonTest": taskName = "jvmTest"
        default: continue
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8),
          content.contains(needle)
        else { continue }
        let module = parts[..<srcIndex].joined(separator: ":")
        let task = ":\(module):\(taskName)"
        let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        hosts.gradleTaskStems[task, default: []].insert(stem)
      }
    }
    for root in manifest.swiftPackageDirs {
      let testsDir = root.appendingPathComponent("Tests")
      guard
        let enumerator = FileManager.default.enumerator(
          at: testsDir, includingPropertiesForKeys: nil)
      else { continue }
      for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".swift") {
        guard let content = try? String(contentsOf: url, encoding: .utf8),
          content.contains(needle)
        else { continue }
        let stem = url.deletingPathExtension().lastPathComponent
        hosts.swiftRootStems[root, default: []].insert(stem)
      }
    }
    return hosts
  }

  /// Restores parity/fixtures to a byte snapshot: files whose bytes differ are
  /// rewritten from it, files it does not know are deleted, files it holds that
  /// vanished are re-created.
  private static func restoreFixtures(_ repo: Repo, to before: [String: FixtureDigest]) {
    let current = fixtureDigests(repo)
    for (name, digest) in current where before[name]?.whole != digest.whole {
      let url = repo.fixturesDir.appendingPathComponent(name)
      if let original = before[name] {
        try? original.whole.write(to: url)
      } else {
        try? FileManager.default.removeItem(at: url)
      }
    }
    for (name, digest) in before where current[name] == nil {
      try? digest.whole.write(to: repo.fixturesDir.appendingPathComponent(name))
    }
  }

  /// Copies the freshly recorded fixture files (before restore) into
  /// parity/.runs/record-check/ — the inspectable would-be rewrite.
  private static func saveRecordCheckRewrite(_ repo: Repo, changed: [String]) -> String {
    let dir = repo.runsDir.appendingPathComponent("record-check")
    try? FileManager.default.removeItem(at: dir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for name in changed {
      try? FileManager.default.copyItem(
        at: repo.fixturesDir.appendingPathComponent(name),
        to: dir.appendingPathComponent(name))
    }
    return "parity/.runs/record-check"
  }

  private static func fixtureDigests(_ repo: Repo) -> [String: FixtureDigest] {
    var digests: [String: FixtureDigest] = [:]
    for file in
      (try? FileManager.default.contentsOfDirectory(atPath: repo.fixturesDir.path)) ?? []
    where file.hasSuffix(".json") {
      let data =
        (try? Data(contentsOf: repo.fixturesDir.appendingPathComponent(file))) ?? Data()
      digests[file] = FixtureDigest(whole: data, behavioral: behavioralSubset(of: data))
    }
    return digests
  }

  /// Canonical serialization of the behavioral field subset. An unparseable
  /// document keeps whole-file identity — there is no metadata to except.
  static func behavioralSubset(of data: Data) -> Data {
    guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return data
    }
    var subset: [String: Any] = [:]
    for key in ["initialState", "initialStates"] {
      if let value = document[key] { subset[key] = value }
    }
    if let steps = document["steps"] as? [[String: Any]] {
      let kept: Set<String> = ["node", "action", "expectedState", "expectedEffects"]
      subset["steps"] = steps.map { step in step.filter { kept.contains($0.key) } }
    }
    guard
      let canonical = try? JSONSerialization.data(withJSONObject: subset, options: [.sortedKeys])
    else { return data }
    return canonical
  }

  static func emitJSON(_ object: [String: Any]) {
    var stamped = object
    // Receipts record which toolchain produced them without hand-assembly:
    // every --json report carries the version (the MCP tool results inherit
    // it via structuredContent).
    if stamped["toolchain"] == nil { stamped["toolchain"] = duetToolsVersion }
    if let data = try? JSONSerialization.data(
      withJSONObject: stamped, options: [.prettyPrinted, .sortedKeys]),
      let text = String(data: data, encoding: .utf8)
    {
      print(text)
    }
  }
}
