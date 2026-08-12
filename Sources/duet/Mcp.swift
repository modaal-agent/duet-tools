// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import Foundation

/// `duet mcp` — the agent surface: a stdio MCP server over the same verification
/// verbs, so any agent harness (Claude Code, etc.) gets the toolchain with one
/// `mcpServers` entry. Hand-rolled JSON-RPC on newline-delimited stdio, zero
/// third-party dependencies — the transport is ~a page, and an MCP SDK would
/// enter every toolchain build for it.
///
/// Each tool call re-invokes THIS executable as a subprocess with the mapped verb
/// and `--json`. That is deliberate, not laziness: the verbs print to stdout, and
/// in-process dispatch would corrupt the JSON-RPC stream; the subprocess boundary
/// also means a verb failure can never take the server down. Every verb's `--json`
/// report is the tool contract, so the tool result IS the structured report — an
/// agent never parses fixture JSON or greps Gradle logs.
///
/// No streaming and no cancel: every verb is seconds-fast on a warm tree, so a
/// synchronous call carries no progress a caller could act on.
enum Mcp {
  static let latestProtocolVersion = "2025-06-18"
  static let knownProtocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18"]
  static let serverVersion = "0.1.0"

  static func run(repo: Repo, options: Options) throws -> Int32 {
    let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
    FileHandle.standardError.write(
      Data("duet mcp: serving \(repo.root.path) (stdio; ^D to stop)\n".utf8))
    while let line = readLine(strippingNewline: true) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty { continue }
      guard
        let message = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)))
          as? [String: Any]
      else {
        send(error(id: NSNull(), code: -32700, message: "parse error: each line must be one JSON-RPC message"))
        continue
      }
      guard let id = message["id"] else { continue }  // notifications need no reply
      let method = message["method"] as? String ?? ""
      let params = message["params"] as? [String: Any] ?? [:]
      switch method {
      case "initialize":
        send(result(id: id, initializeResult(clientVersion: params["protocolVersion"] as? String)))
      case "ping":
        send(result(id: id, [:]))
      case "tools/list":
        send(result(id: id, ["tools": toolCatalog()]))
      case "tools/call":
        send(callTool(id: id, params: params, executable: executable, repo: repo))
      default:
        send(error(id: id, code: -32601, message: "method not found: \(method)"))
      }
    }
    return 0
  }

  // MARK: - Handlers

  static func initializeResult(clientVersion: String?) -> [String: Any] {
    let version = clientVersion.flatMap { knownProtocolVersions.contains($0) ? $0 : nil }
    return [
      "protocolVersion": version ?? latestProtocolVersion,
      "capabilities": ["tools": [String: Any]()],
      "serverInfo": ["name": "duet", "version": serverVersion],
      // The mini-playbook: the rules an agent must know before its first call,
      // phrased for the harness's system prompt.
      "instructions": """
        Duet parity toolchain. Fixtures under parity/fixtures are build products \
        compiled from scenario tests — NEVER edit them by hand; a red gate is \
        repaired by fixing code/scenarios and re-recording, not by editing fixtures. \
        Loop: duet_verify → on failure duet_explain (structured failure report) → \
        duet_materialize for a standalone failing test of one step. Behavior \
        changes: author the scenario, run duet_record, then review the fixture \
        diff like code. duet_record with check=true is the CI drift gate (red on \
        behavioral drift; metadata-only churn passes). duet_protocol_run \
        byte-gates the corpus through a flavor's replay runner. duet_scope \
        reports which gates govern a file. duet_lanes reports the lane \
        inventory the manifest derives — and what verify does NOT cover. \
        duet_doctor cross-checks the repo's target declarations \
        (.modaal/project.json) against the manifest's derived shape, \
        lints Working conformers stamped '@unchecked Sendable', and \
        flags Swift packages whose declared tests have never run \
        anywhere (no lane has ever resolved them as a root).
        """,
    ]
  }

  /// The verification verbs only — the authoring verbs (scaffold/convert/audit)
  /// are not part of this toolchain and are not served here.
  static func toolCatalog() -> [[String: Any]] {
    [
      [
        "name": "duet_verify",
        "description": "Byte-gate the fixture corpus: meta-checks (declaration lockstep + fixture symmetry), then both platform lanes in parallel, with the fixture coverage gate. Scope with `feature`; restrict to one lane with `lane`. Returns the structured run report; on failure call duet_explain next.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "feature": ["type": "string", "description": "feature name from parity/manifest.yaml (omit = full corpus)"],
            "lane": ["type": "string", "enum": ["swift", "kotlin"], "description": "run one platform lane only (omit = both)"],
          ] as [String: Any],
        ] as [String: Any],
      ],
      [
        "name": "duet_record",
        "description": "Recompile fixtures from their scenarios (fixtures are build products — review the resulting git diff like code). `check: true` = CI drift gate: fails on BEHAVIORAL drift (the replay protocol's field set) or a stale generated coder; metadata-only churn (scenario.source, step label/line — a scenario port's admissible diff) passes, reported as `metadataOnly`.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "feature": ["type": "string", "description": "feature name (omit = everything)"],
            "chain": ["type": "string", "description": "chain fixture name — records exactly the test sources that mention it (the mid-migration scope)"],
            "platform": ["type": "string", "enum": ["swift", "kotlin"], "description": "record through one platform's runner (default swift)"],
            "check": ["type": "boolean", "description": "drift gate — red on behavioral drift only; a failing check leaves parity/fixtures untouched (rewrite lands in parity/.runs/record-check/)"],
          ] as [String: Any],
        ] as [String: Any],
      ],
      [
        "name": "duet_lanes",
        "description": "The lane inventory as data: every lane task, package root, and filter the manifest derives (what duet_verify runs), chains with participants, and what verify does NOT cover (gradle modules and Swift packages outside the manifest, the protocol lane). Generate workflows or fallback runners from this instead of re-deriving lane sets by hand.",
        "inputSchema": ["type": "object", "properties": [String: Any]()] as [String: Any],
      ],
      [
        "name": "duet_explain",
        "description": "Re-render the last run's failures from the machine reports (no logs, no re-run): fixture, step label, first-divergence JSON path, both canonical fragments, and the scenario source line.",
        "inputSchema": ["type": "object", "properties": [String: Any]()] as [String: Any],
      ],
      [
        "name": "duet_materialize",
        "description": "Emit a standalone failing unit test for one fixture step on one platform — the step to debug in isolation. `target` is `<fixture>#<step>` exactly as duet_explain reports it.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "target": ["type": "string", "description": "<fixture>#<step>, e.g. profile.delete-arm#3"],
            "platform": ["type": "string", "enum": ["swift", "kotlin"]],
          ] as [String: Any],
          "required": ["target", "platform"],
        ] as [String: Any],
      ],
      [
        "name": "duet_protocol_run",
        "description": "Byte-gate the FULL corpus (leaves and chains) through a replay-protocol runner subprocess — the flavor-neutral lane: the runner exposes only decode→reduce→encode, and the CLI drives fixtures and compares bytes. Default: build+drive the repo's own runner (the Swift replay-runner product when the manifest has one, else the Kotlin lane's :replay-runner:installDist); `platform` forces a flavor's runner on repos carrying both, `runner` a prebuilt executable path.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "platform": ["type": "string", "enum": ["swift", "kotlin"], "description": "build+drive this flavor's own runner"],
            "runner": ["type": "string", "description": "path to a prebuilt conforming runner (overrides platform)"],
          ] as [String: Any],
        ] as [String: Any],
      ],
      [
        "name": "duet_scope",
        "description": "Which parity gates govern a file, and the authoring loop for it (fixture → its owning feature and the record loop; feature source → the verify/record commands; app trees → not governed, with a pointer). Ask before editing anything unfamiliar.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "path": ["type": "string", "description": "file or directory, absolute or repo-relative"]
          ] as [String: Any],
          "required": ["path"],
        ] as [String: Any],
      ],
      [
        "name": "duet_doctor",
        "description": "Cross-check the repo's declaration layer against what is on disk: every target in .modaal/project.json (platform present, template one this toolchain models, pair members agreeing on template, an iOS target's xcodegen.yml present, the template's implied shape matching the manifest's derived lanes), plus the worker-isolation lint — a Working conformer declared '@unchecked Sendable' in non-test sources, which compiles with no diagnostic even under complete concurrency checking — plus the unrun-tests row: a Swift package outside the manifest with a test target, a remote dependency, and no Package.resolved has never been resolved as a root, so those tests have never run (path-only-dependency packages and aggregate-.xcworkspace members are exempt). Read-only.",
        "inputSchema": ["type": "object", "properties": [String: Any]()] as [String: Any],
      ],
    ]
  }

  /// Tool name + arguments → the CLI argv (past the executable). Returns nil with
  /// a message when the arguments don't satisfy the tool's contract.
  static func cliArguments(tool: String, arguments: [String: Any]) -> (args: [String], problem: String?) {
    switch tool {
    case "duet_verify":
      var args = ["verify", "--json"]
      if let feature = arguments["feature"] as? String { args += ["--feature", feature] }
      if let lane = arguments["lane"] as? String {
        guard lane == "swift" || lane == "kotlin" else {
          return ([], "lane must be \"swift\" or \"kotlin\"")
        }
        args.append(lane == "swift" ? "--swift-only" : "--kotlin-only")
      }
      return (args, nil)
    case "duet_record":
      var args = ["record", "--json"]
      if let feature = arguments["feature"] as? String { args += ["--feature", feature] }
      if let chain = arguments["chain"] as? String { args += ["--chain", chain] }
      if let platform = arguments["platform"] as? String { args += ["--platform", platform] }
      if arguments["check"] as? Bool == true { args.append("--check") }
      return (args, nil)
    case "duet_lanes":
      return (["lanes", "--json"], nil)
    case "duet_explain":
      return (["explain", "--json"], nil)
    case "duet_materialize":
      guard let target = arguments["target"] as? String,
        let platform = arguments["platform"] as? String
      else {
        return ([], "duet_materialize needs `target` (<fixture>#<step>) and `platform` — duet_explain reports both")
      }
      return (["materialize", target, "--platform", platform, "--json"], nil)
    case "duet_protocol_run":
      var args = ["protocol-run", "--json"]
      if let runner = arguments["runner"] as? String { args += ["--runner", runner] }
      if let platform = arguments["platform"] as? String {
        guard platform == "swift" || platform == "kotlin" else {
          return ([], "platform must be \"swift\" or \"kotlin\"")
        }
        args += ["--platform", platform]
      }
      return (args, nil)
    case "duet_scope":
      guard let path = arguments["path"] as? String else {
        return ([], "duet_scope needs `path`")
      }
      return (["scope", path, "--json"], nil)
    case "duet_doctor":
      return (["doctor", "--json"], nil)
    default:
      return ([], "unknown tool '\(tool)' — tools/list names the surface (verification verbs only; authoring is not served here)")
    }
  }

  static func callTool(id: Any, params: [String: Any], executable: String, repo: Repo) -> [String: Any] {
    let name = params["name"] as? String ?? ""
    let arguments = params["arguments"] as? [String: Any] ?? [:]
    let (args, problem) = cliArguments(tool: name, arguments: arguments)
    if let problem { return error(id: id, code: -32602, message: problem) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    process.currentDirectoryURL = repo.root
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    do {
      try process.run()
    } catch {
      return self.error(id: id, code: -32603, message: "could not launch \(executable): \(error)")
    }
    // Drain before wait — a verb writing more than a pipe buffer must not deadlock.
    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let out = String(decoding: outData, as: UTF8.self)
    let err = String(decoding: errData, as: UTF8.self)
    let failed = process.terminationStatus != 0

    var text = out.trimmingCharacters(in: .whitespacesAndNewlines)
    if failed, !err.isEmpty {
      text += (text.isEmpty ? "" : "\n") + "stderr:\n" + err.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var payload: [String: Any] = [
      "content": [["type": "text", "text": text]],
      "isError": failed,
    ]
    // The verbs' --json output is a single object — surface it structured too,
    // so clients on 2025-06-18 get the report without re-parsing the text.
    if let structured = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] {
      payload["structuredContent"] = structured
    }
    return result(id: id, payload)
  }

  // MARK: - JSON-RPC plumbing

  static func result(id: Any, _ value: [String: Any]) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "result": value]
  }

  static func error(id: Any, code: Int, message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
  }

  static func send(_ response: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
    else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
  }
}
