// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import Foundation

/// `duet mocks [--check]` — the manifest-driven codegen runner: every
/// `mocks:` generator row (contracts/manifest.md) regenerates its committed
/// file, or — under `--check` — validates the file's fingerprint block with
/// no engine run.
///
/// Layer split, deliberate: the bundle's `mock-templates` CLI is policy-free —
/// it fingerprints and validates the files it is pointed at, knowing nothing
/// about manifests or pins. Everything that knows those lives here: the
/// bundle tag comes from `mocks: bundle:`, the scan roots come from each
/// row's `sources:` and `package:`, and provisioning is the same pinned-tag,
/// checksum-verified release download the `tools/duet` wrapper uses for the
/// toolchain binary itself.
///
/// Provisioning is mode-sized. `--check` needs the CLI alone (kilobytes —
/// validation re-hashes the recorded inputs and the output body; no Sourcery
/// run, no template compile), so it downloads the standalone CLI zip unless a
/// full bundle is already cached. Regeneration downloads the full artifact
/// bundle — engine + templates + CLI, pinned together by one tag, so there is
/// no engine/templates version pair to keep matched. Both assets verify
/// against their published `.sha256` before unpacking; the per-tag cache
/// under `.build/` self-validates (a missing binary re-fetches).
///
/// Scan roots per row: the explicit `sources:` first, then — when `package:`
/// is declared — the roots DERIVED from that package's manifest (`swift
/// package dump-package`, a manifest compile: no resolution, no network):
/// every path dependency's sources, and every Duet family dependency at its
/// exact pin — `duet` scanned whole, `duet-services` scanned per LINKED
/// product (a product the repo does not link would generate mocks its test
/// target cannot compile), whichever dependency form the manifest carries
/// (a version pin, or a sibling checkout while iterating on the package).
/// Third-party remotes are deliberately out: none declares a protocol the
/// annotated ones refine, and parsing them costs seconds per run for nothing.
///
/// Rows run producer-before-consumer: a row whose scan roots contain another
/// row's output runs after it, so the recorded input hash is the post-write
/// one. The order is derived from the resolved roots at run time (derived
/// roots included — a lint could only see the explicit ones); declaration
/// order is the tiebreak, and rows whose roots contain each other's outputs
/// are a named config error.
///
/// Overrides, developer-owned (iterating on a template or the CLI itself):
/// `TEMPLATES_DIR` (a local templates/ tree), `SOURCERY` (an engine binary),
/// `MOCK_TEMPLATES` (a mock-templates binary). A file generated from
/// overridden templates records the pinned tag it did NOT come from — commit
/// only what the pinned bundle reproduces.
enum Mocks {
  static let bundleRepo = "https://github.com/modaal-agent/swift-sourcery-templates"
  /// The family packages the derivation scans (per-identity handling above).
  static let familyIdentities: Set<String> = ["duet", "duet-services"]

  enum MocksError: Error, CustomStringConvertible {
    case downloadFailed(String, String)
    case checksumMismatch(String, String)
    case missingExecutable(String)
    case derivation(String)

    var description: String {
      switch self {
      case let .downloadFailed(asset, detail):
        return "mocks: could not download \(asset) — \(detail)"
      case let .checksumMismatch(asset, dir):
        return "mocks: CHECKSUM MISMATCH for \(asset) — refusing to unpack it."
          + " The download is at \(dir) for inspection; a re-run re-downloads."
      case let .missingExecutable(path):
        return "mocks: no executable at \(path) after unpacking"
      case let .derivation(detail):
        return "mocks: \(detail)"
      }
    }
  }

  static func run(repo: Repo, options: Options) throws -> Int32 {
    let manifest = try Manifest.load(repo: repo)
    guard manifest.lintOK else {
      print("mocks: manifest meta-check FAIL")
      for error in manifest.lintErrors { print("  ✗ \(error)") }
      return 1
    }
    guard !manifest.mockGenerators.isEmpty, let tag = manifest.mocksBundle else {
      if options.json {
        Lanes.emitJSON(["status": "ok", "rows": [[String: Any]](), "note": "no mocks: generator rows"])
      } else {
        print("mocks: no generator rows in parity/manifest.yaml — nothing to generate")
      }
      return 0
    }

    let tools = try provision(repo: repo, tag: tag, check: options.check)
    if options.check {
      print("bundle \(tag) · mock-templates validate (no engine run)")
    } else {
      print("bundle \(tag) · templates \(tools.templatesDir!.path)")
    }

    var rows: [[String: Any]] = []
    var failed = false
    var derivedCache: [String: [URL]] = [:]
    var resolved: [(generator: ParsedManifest.MockGenerator, roots: [URL], output: URL)] = []
    for generator in manifest.mockGenerators {
      var roots = generator.sources.map { repo.root.appendingPathComponent($0) }
      if let package = generator.keys["package"] {
        if derivedCache[package] == nil {
          derivedCache[package] = try derivedRoots(packageRelative: package, repo: repo)
        }
        roots += derivedCache[package]!
      }
      resolved.append(
        (generator, roots, repo.root.appendingPathComponent(generator.keys["output"] ?? "")))
    }
    for (generator, roots, output) in try producersFirst(resolved) {
      var arguments: [String]
      if options.check {
        arguments = [tools.mockTemplates.path, "validate", "--file", output.path,
                     "--root", repo.root.path]
        for root in roots { arguments += ["--sources", root.path] }
        arguments += ["--expect-bundle", tag]
      } else {
        try FileManager.default.createDirectory(
          at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        arguments = [tools.mockTemplates.path, "generate"]
        for root in roots { arguments += ["--sources", root.path] }
        arguments += ["--sourcery", tools.sourcery!.path,
                      "--templates", tools.templatesDir!.appendingPathComponent(
                        generator.keys["template"] ?? "").path]
        for arg in generator.args { arguments += ["--args", arg] }
        arguments += ["--bundle-version", tag, "--root", repo.root.path,
                      "--output", output.path]
      }
      let result = Lanes.finish(try Lanes.launch(
        arguments, cwd: repo.root, logName: "mocks-\(generator.name)"))
      let ok = result.exitCode == 0
      // validate's per-file verdict names what drifted — always worth showing;
      // generate's log matters only when it failed.
      if !ok || options.check,
        let log = try? String(contentsOf: result.logURL, encoding: .utf8), !log.isEmpty
      {
        print(log.trimmingCharacters(in: .newlines))
      }
      if ok, !options.check, let body = try? String(contentsOf: output, encoding: .utf8) {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        let types = lines.filter {
          $0.hasPrefix("final class ") || $0.hasPrefix("class ")
        }.count
        print("  \(output.lastPathComponent) — \(types) types, \(lines.count) lines")
      }
      failed = failed || !ok
      rows.append([
        "name": generator.name,
        "output": generator.keys["output"] ?? "",
        "action": options.check ? "validate" : "generate",
        "ok": ok,
      ])
    }

    if options.json {
      Lanes.emitJSON(["status": failed ? "fail" : "ok", "bundle": tag, "rows": rows])
    } else if options.check {
      if failed {
        print("")
        print("Generated code is stale.")
        print("  A recorded input changed, a source file was added, or the output was")
        print("  edited after generation. Run:")
        print("    tools/duet mocks")
        print("  and commit the result — files under Generated/ are build products.")
      } else {
        print("Generated code is current ✓")
      }
    }
    return failed ? 1 : 0
  }

  // MARK: - Run order

  /// Stable topological order over "this row's roots contain that row's
  /// output": producers first, declaration order as the tiebreak.
  static func producersFirst(
    _ rows: [(generator: ParsedManifest.MockGenerator, roots: [URL], output: URL)]
  ) throws -> [(generator: ParsedManifest.MockGenerator, roots: [URL], output: URL)] {
    func contains(_ root: URL, _ file: URL) -> Bool {
      file.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    }
    let producers: [[Int]] = rows.indices.map { consumer in
      rows.indices.filter { producer in
        producer != consumer
          && rows[consumer].roots.contains { contains($0, rows[producer].output) }
      }
    }
    var done = Set<Int>()
    var order: [Int] = []
    while order.count < rows.count {
      guard
        let next = rows.indices.first(where: { index in
          !done.contains(index) && producers[index].allSatisfy(done.contains)
        })
      else {
        let names = rows.indices.filter { !done.contains($0) }
          .map { rows[$0].generator.name }.joined(separator: ", ")
        throw MocksError.derivation(
          "generator rows scan each other's outputs in a cycle: \(names)"
            + " — narrow the sources: roots so one direction remains")
      }
      done.insert(next)
      order.append(next)
    }
    return order.map { rows[$0] }
  }

  // MARK: - Provisioning

  struct Tools {
    let mockTemplates: URL
    /// nil under `--check` — validation never runs the engine.
    let sourcery: URL?
    let templatesDir: URL?
  }

  static func provision(repo: Repo, tag: String, check: Bool) throws -> Tools {
    let env = ProcessInfo.processInfo.environment
    let fm = FileManager.default
    let cacheRoot = repo.root.appendingPathComponent(".build/swift-sourcery-templates-\(tag)")
    let bundleDir = cacheRoot.appendingPathComponent(
      "swift-sourcery-templates-\(tag).artifactbundle")
    let overrideCLI = env["MOCK_TEMPLATES"].map(URL.init(fileURLWithPath:))
    let overrideSourcery = env["SOURCERY"].map(URL.init(fileURLWithPath:))
    let overrideTemplates = env["TEMPLATES_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }

    let bundledCLI = bundleDir.appendingPathComponent("mock-templates/bin/mock-templates")
    if check {
      if let overrideCLI {
        return Tools(mockTemplates: overrideCLI, sourcery: nil, templatesDir: nil)
      }
      // A full bundle cached by a regenerate run already holds the same binary.
      if fm.isExecutableFile(atPath: bundledCLI.path) {
        return Tools(mockTemplates: bundledCLI, sourcery: nil, templatesDir: nil)
      }
      let cli = cacheRoot.appendingPathComponent("cli/mock-templates")
      if !fm.isExecutableFile(atPath: cli.path) {
        try fetchVerified(
          asset: "mock-templates-\(tag)-macos.zip", tag: tag,
          into: cacheRoot.appendingPathComponent("cli"))
      }
      guard fm.isExecutableFile(atPath: cli.path) else {
        throw MocksError.missingExecutable(cli.path)
      }
      return Tools(mockTemplates: cli, sourcery: nil, templatesDir: nil)
    }

    if let overrideCLI, let overrideSourcery, let overrideTemplates {
      return Tools(
        mockTemplates: overrideCLI, sourcery: overrideSourcery, templatesDir: overrideTemplates)
    }
    if !fm.isExecutableFile(atPath: bundledCLI.path) {
      try fetchVerified(
        asset: "swift-sourcery-templates-\(tag).artifactbundle.zip", tag: tag, into: cacheRoot)
      guard fm.isExecutableFile(atPath: bundledCLI.path) else {
        throw MocksError.missingExecutable(bundledCLI.path)
      }
    }
    return Tools(
      mockTemplates: overrideCLI ?? bundledCLI,
      sourcery: overrideSourcery ?? bundleDir.appendingPathComponent("sourcery/bin/sourcery"),
      templatesDir: overrideTemplates ?? bundleDir.appendingPathComponent("templates"))
  }

  /// One release asset + its published `.sha256`, verified before unpacking —
  /// the wrapper's rung for the toolchain binary, reused for the bundle. A
  /// download failure names the asset; a checksum mismatch hard-stops and
  /// leaves the download for inspection.
  static func fetchVerified(asset: String, tag: String, into dir: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    print("mocks: fetching \(asset) …")
    for name in [asset, "\(asset).sha256"] {
      let fetch = Lanes.finish(try Lanes.launch(
        ["curl", "-fsSL", "--retry", "2", "--connect-timeout", "10",
         "-o", dir.appendingPathComponent(name).path,
         "\(bundleRepo)/releases/download/\(tag)/\(name)"],
        cwd: dir, logName: "mocks-fetch"))
      guard fetch.exitCode == 0 else {
        try? fm.removeItem(at: dir.appendingPathComponent(name))
        throw MocksError.downloadFailed(
          name, "offline, or tag \(tag) has no published release asset")
      }
    }
    let verify = Lanes.finish(try Lanes.launch(
      ["shasum", "-a", "256", "-c", "\(asset).sha256"], cwd: dir, logName: "mocks-shasum"))
    guard verify.exitCode == 0 else { throw MocksError.checksumMismatch(asset, dir.path) }
    let unzip = Lanes.finish(try Lanes.launch(
      ["unzip", "-qo", asset], cwd: dir, logName: "mocks-unzip"))
    guard unzip.exitCode == 0 else {
      throw MocksError.downloadFailed(asset, "unzip failed (truncated download?)")
    }
    for candidate in ["mock-templates", "swift-sourcery-templates-\(tag).artifactbundle/mock-templates/bin/mock-templates",
                      "swift-sourcery-templates-\(tag).artifactbundle/sourcery/bin/sourcery"] {
      let path = dir.appendingPathComponent(candidate).path
      if fm.fileExists(atPath: path) {
        _ = Lanes.finish(try Lanes.launch(["chmod", "+x", path], cwd: dir, logName: "mocks-chmod"))
      }
    }
    try? fm.removeItem(at: dir.appendingPathComponent(asset))
  }

  // MARK: - Source-root derivation (`package:`)

  static func derivedRoots(packageRelative: String, repo: Repo) throws -> [URL] {
    let fm = FileManager.default
    let packageDir = repo.root.appendingPathComponent(packageRelative)
    // stdout alone — a manifest-compile warning on stderr must not corrupt
    // the JSON (Lanes.launch merges the two streams into one log).
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["swift", "package", "dump-package"]
    process.currentDirectoryURL = packageDir
    process.standardInput = FileHandle.nullDevice
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = FileHandle.standardError
    try process.run()
    let data = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
      let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw MocksError.derivation("swift package dump-package failed in \(packageRelative)")
    }

    var roots: [URL] = []
    let dependencies = manifest["dependencies"] as? [[String: Any]] ?? []

    // Path dependencies: `<path>/Sources`, or the framework's `swift/Sources`
    // spelling for a family sibling checkout. duet-services is deferred to the
    // per-product scan below, whichever form it takes here.
    var servicesSourcesDir: URL?
    for dep in dependencies {
      for fs in dep["fileSystem"] as? [[String: Any]] ?? [] {
        guard let rawPath = fs["path"] as? String else { continue }
        let path = rawPath.hasPrefix("/")
          ? URL(fileURLWithPath: rawPath)
          : packageDir.appendingPathComponent(rawPath).standardizedFileURL
        let identity = fs["identity"] as? String ?? ""
        let name = fs["nameForTargetDependencyResolutionOnly"] as? String ?? ""
        if identity == "duet-services" || name == "duet-services" {
          servicesSourcesDir = path.appendingPathComponent("Sources")
          continue
        }
        if fm.fileExists(atPath: path.appendingPathComponent("Sources").path) {
          roots.append(path.appendingPathComponent("Sources"))
        } else if fm.fileExists(atPath: path.appendingPathComponent("swift/Sources").path) {
          roots.append(path.appendingPathComponent("swift/Sources"))
        } else {
          FileHandle.standardError.write(
            Data("mocks: path dependency has no Sources/ — skipping \(path.path)\n".utf8))
        }
      }
    }

    // Family URL pins, at their exact versions. Prefer the checkout SwiftPM
    // already made for the build (same revision, no network, no credentials);
    // fall back to a shallow clone at the pin — the fresh-runner case.
    for dep in dependencies {
      for sc in dep["sourceControl"] as? [[String: Any]] ?? [] {
        guard let identity = sc["identity"] as? String, familyIdentities.contains(identity),
          let requirement = sc["requirement"] as? [String: Any],
          let exact = (requirement["exact"] as? [String])?.first,
          let location = sc["location"] as? [String: Any],
          let url = ((location["remote"] as? [[String: Any]])?.first?["urlString"] as? String)
            ?? ((location["remote"] as? [String])?.first)
        else { continue }
        let checkout = repo.root.appendingPathComponent(
          ".build/SourcePackages/checkouts/\(identity)")
        let source: URL
        if fm.fileExists(atPath: checkout.path) {
          source = checkout
        } else {
          source = try familyClone(identity: identity, url: url, version: exact, repo: repo)
        }
        if identity == "duet-services" {
          servicesSourcesDir = source.appendingPathComponent("Sources")
          continue
        }
        for candidate in ["swift/Sources", "Sources"] {
          let root = source.appendingPathComponent(candidate)
          if fm.fileExists(atPath: root.path) {
            roots.append(root)
            break
          }
        }
      }
    }

    // duet-services, per LINKED product: the package keeps one source
    // directory per product, so the linked product names ARE the directories.
    if let servicesSourcesDir {
      var products: [String] = []
      for target in manifest["targets"] as? [[String: Any]] ?? [] {
        for dependency in target["dependencies"] as? [[String: Any]] ?? [] {
          if let product = dependency["product"] as? [Any], product.count >= 2,
            let productName = product[0] as? String,
            let packageName = product[1] as? String, packageName == "duet-services",
            !products.contains(productName)
          {
            products.append(productName)
          }
        }
      }
      for product in products {
        let root = servicesSourcesDir.appendingPathComponent(product)
        if fm.fileExists(atPath: root.path) {
          roots.append(root)
        } else {
          FileHandle.standardError.write(
            Data("mocks: no \(product) directory in the duet-services sources — skipping\n".utf8))
        }
      }
    }
    return roots
  }

  /// `.build/duet-sources/<identity>` at the exact pin, reused when the
  /// cached clone already sits on that tag.
  static func familyClone(identity: String, url: String, version: String, repo: Repo) throws -> URL
  {
    let cache = repo.root.appendingPathComponent(".build/duet-sources/\(identity)")
    let describe = Lanes.finish(try Lanes.launch(
      ["git", "-C", cache.path, "describe", "--tags", "--exact-match"],
      cwd: repo.root, logName: "mocks-describe"))
    let current = (try? String(contentsOf: describe.logURL, encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    if describe.exitCode == 0, current == version { return cache }
    print("mocks: cloning \(identity)@\(version) …")
    try? FileManager.default.removeItem(at: cache)
    try FileManager.default.createDirectory(
      at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
    let clone = Lanes.finish(try Lanes.launch(
      ["git", "clone", "--quiet", "--depth", "1", "--branch", version,
       "-c", "advice.detachedHead=false", url, cache.path],
      cwd: repo.root, logName: "mocks-clone"))
    guard clone.exitCode == 0 else {
      throw MocksError.derivation(
        "could not clone \(identity)@\(version) from \(url) (log: \(clone.logURL.path))")
    }
    return cache
  }
}
