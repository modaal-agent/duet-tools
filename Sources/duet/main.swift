// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import Foundation

/// Parsed command line. Deliberately hand-rolled (zero third-party dependencies —
/// swift-argument-parser would enter every toolchain build for one flag loop).
struct Options {
  var command: String?
  var feature: String?
  var chain: String?
  var platform: String?
  var runner: String?
  var target: String?
  var min: Int?
  var json = false
  var swiftOnly = false
  var kotlinOnly = false
  var clean = false
  var check = false
  var write = false

  enum OptionsError: Error, CustomStringConvertible {
    case unknownFeature(String)

    var description: String {
      switch self {
      case let .unknownFeature(name):
        return "unknown feature '\(name)' (not in parity/manifest.yaml)"
      }
    }
  }

  func resolveFeature(in manifest: Manifest) throws -> Feature? {
    guard let name = feature else { return nil }
    guard let found = manifest.feature(named: name) else {
      throw OptionsError.unknownFeature(name)
    }
    return found
  }

  static func parse(_ arguments: [String]) -> Options? {
    var options = Options()
    var rest = arguments.dropFirst()
    if let first = rest.first, !first.hasPrefix("-") {
      options.command = first
      rest = rest.dropFirst()
    }
    var iterator = rest.makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--feature":
        guard let value = iterator.next() else { return nil }
        options.feature = value
      case "--chain":
        guard let value = iterator.next() else { return nil }
        options.chain = value
      case "--min":
        guard let value = iterator.next(), let number = Int(value) else { return nil }
        options.min = number
      case "--platform":
        guard let value = iterator.next() else { return nil }
        options.platform = value
      case "--runner":
        guard let value = iterator.next() else { return nil }
        options.runner = value
      case "--json":
        options.json = true
      case "--swift-only":
        options.swiftOnly = true
      case "--kotlin-only":
        options.kotlinOnly = true
      case "--clean":
        options.clean = true
      case "--check":
        options.check = true
      case "--write":
        options.write = true
      case "-":
        options.target = "-"
      case "--help", "-h":
        options.command = "help"
      case "--version":
        options.command = "version"
      default:
        if argument.hasPrefix("-") { return nil }
        options.target = argument
      }
    }
    return options
  }
}

let usage = """
  duet — the Duet parity toolchain CLI

  usage:
    duet verify [--feature <name>] [--swift-only|--kotlin-only] [--json]
        meta-checks (lockstep + fixture symmetry + the host-lane rule: a gated
        unit resolves the Duet family only, on both build systems + the
        spec↔fixture cross-reference when parity/feature-specs/ exists), then
        the manifest's platform lanes in parallel (a single-source manifest —
        `swift:` or `kotlin:` paths only — runs its one lane; a lane flag
        naming the missing lane is a meta-error); failures render with step
        label, JSON path, and scenario line.
    duet lint [--json]
        the manifest meta-checks alone, no lanes — the fast authoring-loop
        red: parse parity/manifest.yaml (the CLI's own parser; grammar in
        contracts/manifest.md — unknown TOP-LEVEL keys are an error so a
        typo'd section cannot silently drop its block), then scenario
        existence, fixture symmetry (listed ⊆ disk, no orphans), the
        module-name mirror pin, the presentation ledger's entry shape, and —
        for features declaring BOTH `swift:` and `kotlin:` — declaration
        parity (State fields, Action/EffectPayload cases, camelCase ↔
        PascalCase fold), the migration-window check. --json emits the plan
        (status/errors/features/chains/presentation + top-level scalars).
        `verify` runs the same checks as its first meta-gate.
    duet record [--feature <name>|--chain <name>] [--platform swift|kotlin]
                [--check [--write]] [--json]
        recompile fixtures from scenarios (scoped when --feature or --chain
        given), then a review summary of what changed. Fixtures are build
        products — review the diff like code. --chain scopes to one chain
        fixture: the CLI finds the test sources that mention it and runs
        exactly those, so a chain records mid-migration without an unscoped
        pass. --platform kotlin records through the Kotlin runner: it emits
        compact artifacts and the CLI materializes the fixtures (one writer).
        --check = CI regen gate: exit 1 on BEHAVIORAL drift (the replay
        protocol's field set); metadata-only churn (scenario.source, step
        label/line — a scenario port's admissible diff) reports green. A
        failing --check leaves parity/fixtures byte-identical — the would-be
        rewrite lands in parity/.runs/record-check/ instead (--write
        materializes it into the tree anyway). While any feature is
        dual-writer (a `swift:` twin plus a Kotlin `scenario:`), unscoped
        record refuses — record per feature or per chain inside that window.
    duet lanes [--json]
        the lane inventory as data: every lane task, package root, and filter
        the manifest derives (what `verify` runs), the chains and their
        participants, and what verify does NOT cover (gradle modules and
        Swift packages outside the manifest, the protocol lane) — generate
        workflows and fallback runners from this instead of re-deriving.
    duet assert-replayed <log|-> [--min <n>] [--json]
        fail unless a lane log shows at least --min (default 1) executed
        tests — the empty-pass gate for hand-written lane scripts (`swift
        test` exits 0 on a target that discovers zero tests). Counts the
        MAXIMUM across runner summaries (XCTest "Executed N tests",
        swift-testing "Test run with N tests", Gradle "N tests completed") —
        both Swift summaries print on every run, so a zero line is normal.
    duet explain [--json]
        re-render the last run's failures from parity/.runs (no logs, no re-run).
    duet materialize <fixture>#<step> --platform swift|kotlin [--json]
        emit a standalone failing unit test for one fixture step on one platform.
    duet materialize --clean
        delete every generated Materialized_* test.
    duet protocol-run [--platform swift|kotlin] [--runner <path>] [--json]
        byte-gate the full corpus through a replay-protocol runner
        (contracts/replay-protocol-v1.md). Default: build + drive the repo's
        own runner — the Swift `replay-runner` product when the manifest has
        a package for it, else the Kotlin lane's `:replay-runner:installDist`
        (built by the CLI). --platform forces a flavor's runner on repos
        carrying both; --runner drives any conforming prebuilt runner.
    duet write-fixtures [--json]
        materialize pending record artifacts (parity/.runs/record/**) into
        pretty fixture files — the framework repos' own-corpus regen path; adopter
        repos normally just run `duet record`.
    duet canonical-sum [--check] [--json]
        (re)generate the committed sum-coder files for every enum declaring
        CanonicalSumCodable (scans the package's Sources/**). Normally implicit:
        `duet record` regenerates first, and `record --check` gates coder drift
        — the standalone verb covers a first generation on a new type.
    duet scope <path> [--json]
        which gates govern a file (and the authoring loop for it) — the
        module→gates map, derived from the manifest: fixture → its owning
        feature and the record loop; feature source → the feature's verify/
        record commands; app trees → "not governed" with a pointer.
    duet doctor [--json]
        cross-check the repo's declaration layer against what is on disk.
        Row 1: every target in .modaal/project.json — platform present,
        template one this toolchain models, pair members agreeing on
        template, an iOS target's xcodegen.yml present, and the template's
        implied shape matching the manifest's derived lanes ("this repo
        says duet-kmp; the manifest derives no Kotlin lane" is a finding).
        Row 2: the worker-isolation lint — a Working conformer (direct,
        via a refining protocol, or via a superclass) declared
        '@unchecked Sendable' in non-test sources; the compiler accepts
        that stamp with no diagnostic even under complete concurrency
        checking, so only a lint can hold the rule.
        Row 3: tests that have never run — a Swift package outside the
        manifest that declares a test target, names a remote dependency,
        and has no Package.resolved has never been resolved as a root.
        Path-only-dependency packages and members of an aggregate
        .xcworkspace are exempt (for them the missing lock means
        nothing). Never rewrites.
    duet mutate [<name>] [--json]
        the mutation drill — test the tests: seed each behavioral mutation
        from parity/mutations.json one at a time (exact-string substitution,
        must match the file exactly once), run the full suite, and require
        it to go red, recording which lane caught it (swift/kotlin/meta/
        coverage). A surviving mutation is a behavior the corpus does not
        pin — the run fails on it, and on any stale row (`old` no longer
        matching once: sources move, so the drill sweeps its own table).
        The clean tree is verified green first; every mutation is restored
        before the next runs. <name> runs one row — the authoring loop for
        a new row. Add at least one row per migration wave. Minutes, not
        seconds: the full suite runs once per row plus a baseline.
    duet mcp
        serve the verification verbs as a stdio MCP server (duet_verify,
        duet_record, duet_explain, duet_materialize, duet_protocol_run,
        duet_scope, duet_doctor) — one mcpServers entry gives any agent
        harness the toolchain; tool results are the verbs' --json reports
        (each stamped with the toolchain version). Launch with cwd inside
        the repo.
    duet version
        print the toolchain version (matches the release tag), so gate
        receipts can record which toolchain ran. Works outside a repo.

  Run from anywhere inside the repo (root is found via parity/fixtures).
  """

guard let options = Options.parse(CommandLine.arguments), let command = options.command
else {
  print(usage)
  exit(2)
}
if command == "help" {
  print(usage)
  exit(0)
}
// Version resolves before repo discovery — receipts ask it from anywhere.
if command == "version" {
  print("duet \(duetToolsVersion)")
  exit(0)
}
// So does assert-replayed: it reads a log, not a repo — lane scripts outside
// any parity tree (a framework repo's own CI) get the empty-pass gate too.
if command == "assert-replayed" {
  exit(AssertReplayed.run(options: options))
}
guard let repo = Repo.discover() else {
  FileHandle.standardError.write(
    Data("duet: not inside a parity repo (no parity/fixtures found walking up)\n".utf8))
  exit(2)
}

do {
  let code: Int32
  switch command {
  case "verify":
    code = try Lanes.run(repo: repo, options: options)
  case "lint":
    code = try ManifestLint.run(repo: repo, options: options)
  case "record":
    code = try Lanes.record(repo: repo, options: options)
  case "explain":
    code = Explain.run(repo: repo, options: options)
  case "materialize":
    code = try Materialize.run(repo: repo, options: options)
  case "protocol-run":
    code = try ProtocolLane.run(repo: repo, options: options)
  case "write-fixtures":
    code = try RecordArtifacts.run(repo: repo, options: options)
  case "canonical-sum":
    code = try CanonicalSumVerb.run(repo: repo, options: options)
  case "lanes":
    code = try Inventory.run(repo: repo, options: options)
  case "scope":
    code = try Scope.run(repo: repo, options: options)
  case "doctor":
    code = try Doctor.run(repo: repo, options: options)
  case "mutate":
    code = try Mutate.run(repo: repo, options: options)
  case "mcp":
    code = try Mcp.run(repo: repo, options: options)
  default:
    print("duet: unknown command '\(command)'\n")
    print(usage)
    code = 2
  }
  exit(code)
} catch {
  FileHandle.standardError.write(Data("duet: \(error)\n".utf8))
  exit(1)
}
