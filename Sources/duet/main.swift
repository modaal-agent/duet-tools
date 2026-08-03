// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import Foundation

/// Parsed command line. Deliberately hand-rolled (zero third-party dependencies —
/// swift-argument-parser would enter every toolchain build for one flag loop).
struct Options {
  var command: String?
  var feature: String?
  var platform: String?
  var runner: String?
  var target: String?
  var json = false
  var swiftOnly = false
  var kotlinOnly = false
  var clean = false
  var check = false

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
        both platform lanes in parallel; failures render with step label,
        JSON path, and scenario line.
    duet record [--feature <name>] [--platform swift|kotlin] [--check] [--json]
        recompile fixtures from scenarios (scoped when --feature given), then a
        review summary of what changed. Fixtures are build products — review the
        diff like code. --platform kotlin records through the Kotlin runner: it
        emits compact artifacts and the CLI materializes the §6 files (one
        writer). --check = CI regen gate: exit 1 on BEHAVIORAL drift (the
        replay protocol's field set); metadata-only churn (scenario.source,
        step label/line — a scenario port's admissible diff) reports green.
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
        materialize pending record artifacts (parity/.runs/record/**) into §6
        fixture files — the framework repos' own-corpus regen path; adopter
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
    duet mcp
        serve the verification verbs as a stdio MCP server (duet_verify,
        duet_record, duet_explain, duet_materialize, duet_protocol_run,
        duet_scope) — one mcpServers entry gives any agent harness the
        toolchain; tool results are the verbs' --json reports (each stamped
        with the toolchain version). Launch with cwd inside the repo.
    duet version
        print the toolchain version (matches the release tag), so gate
        receipts can record which toolchain ran. Works outside a repo.

  Run from anywhere inside the repo (root is found via parity/fixtures).
  """

/// Bumped with each release tag — the tag is the version of record (pre-1.0
/// minors are breaking by family convention: a new or changed gate is a minor).
let duetToolsVersion = "0.3.0"

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
  case "scope":
    code = try Scope.run(repo: repo, options: options)
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
