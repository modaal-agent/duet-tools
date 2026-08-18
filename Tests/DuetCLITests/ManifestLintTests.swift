// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import XCTest

@testable import DuetCLI

/// The fixture-repo harness: each test copies one of the miniature adopter
/// trees (Tests/DuetCLITests/Resources/) into a temp directory, breaks the
/// copy programmatically, and asserts the named violation — one negative
/// control per check row minimum, so a check without a control is not counted
/// ported.
final class ManifestLintTests: XCTestCase {

  // MARK: - Harness

  private func makeTree(_ name: String) throws -> Repo {
    // A top-level directory literally named "Resources" makes Bundle adopt the
    // Resources-style layout, so resourceURL may already point INSIDE the
    // copied directory — probe both spellings.
    let base = try XCTUnwrap(Bundle.module.resourceURL)
    let candidates = [
      base.appendingPathComponent("Resources/\(name)"),
      base.appendingPathComponent(name),
    ]
    let source = try XCTUnwrap(
      candidates.first { FileManager.default.fileExists(atPath: $0.path) },
      "missing mini tree \(name) under \(base.path)")
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("duet-manifest-lint-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: source, to: root)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return Repo(root: root)
  }

  /// Exact-string breakage of a file in the temp copy — asserts the anchor
  /// exists so a drifted mini tree fails loudly instead of testing nothing.
  private func rewrite(
    _ repo: Repo, _ path: String, _ old: String, _ new: String,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let url = repo.root.appendingPathComponent(path)
    let text = try String(contentsOf: url, encoding: .utf8)
    XCTAssertTrue(text.contains(old), "anchor '\(old)' not found in \(path)", file: file, line: line)
    try Data(text.replacingOccurrences(of: old, with: new).utf8).write(to: url)
  }

  private func delete(_ repo: Repo, _ path: String) throws {
    try FileManager.default.removeItem(at: repo.root.appendingPathComponent(path))
  }

  private func lintErrors(_ repo: Repo) throws -> [String] {
    try ManifestLint.lint(repo: repo).errors
  }

  private func assertError(
    _ repo: Repo, containing needle: String, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let errors = try lintErrors(repo)
    XCTAssertTrue(
      errors.contains { $0.contains(needle) },
      "no error contains '\(needle)'; got \(errors)", file: file, line: line)
  }

  // MARK: - Goldens: the three trees are green and derive their layouts

  func testMiniDualGoldenPlanAndDerivedLanes() throws {
    let repo = try makeTree("mini-dual")
    let result = try ManifestLint.lint(repo: repo)
    XCTAssertEqual(result.errors, [])
    XCTAssertEqual(result.fixturesOnDisk, 2)
    XCTAssertEqual(result.pendingCount, 0)
    XCTAssertEqual(result.singleSourceCount, 0)
    XCTAssertEqual(result.parsed.waivers.count, 1)
    XCTAssertEqual(result.parsed.islands.count, 1)

    let manifest = try Manifest.load(repo: repo)
    XCTAssertTrue(manifest.lintOK)
    XCTAssertEqual(manifest.chains, ["greeter.wave"])
    XCTAssertEqual(manifest.features.map(\.name), ["greeter"])
    let greeter = try XCTUnwrap(manifest.feature(named: "greeter"))
    XCTAssertEqual(greeter.swiftModule, "GreeterFeature")
    XCTAssertEqual(greeter.stateType, "GreeterState")
    XCTAssertEqual(greeter.gradleTestTask, ":feature-greeter:test")
    XCTAssertFalse(greeter.isDualWriter)  // the scenario is Swift-authored
    XCTAssertEqual(
      manifest.swiftPackageDirs.map(\.path),
      [repo.root.appendingPathComponent("src-ios").path])
    XCTAssertEqual(
      manifest.androidDir?.path, repo.root.appendingPathComponent("src-android").path)
    XCTAssertEqual(manifest.unscopedGradleTasks, ["test"])
  }

  func testMiniSwiftGoldenPlanAndDerivedLanes() throws {
    let repo = try makeTree("mini-swift")
    let result = try ManifestLint.lint(repo: repo)
    XCTAssertEqual(result.errors, [])
    XCTAssertEqual(result.parsed.scalars, ["replayRunner": "src-ios/Replay"])
    XCTAssertTrue(result.parsed.chains.isEmpty)

    let manifest = try Manifest.load(repo: repo)
    XCTAssertTrue(manifest.lintOK)
    XCTAssertNil(manifest.androidDir)
    XCTAssertEqual(
      manifest.swiftPackageDirs.map(\.path),
      [repo.root.appendingPathComponent("src-ios/Subtrees/Counter/CounterFeature").path])
    XCTAssertEqual(
      manifest.replayRunnerPackageDir?.path,
      repo.root.appendingPathComponent("src-ios/Replay").path)
  }

  func testMiniKmpGoldenPlanAndDerivedLanes() throws {
    let repo = try makeTree("mini-kmp")
    let result = try ManifestLint.lint(repo: repo)
    XCTAssertEqual(result.errors, [])
    XCTAssertEqual(result.singleSourceCount, 2)

    let manifest = try Manifest.load(repo: repo)
    XCTAssertTrue(manifest.lintOK)
    XCTAssertTrue(manifest.swiftPackageDirs.isEmpty)
    XCTAssertEqual(manifest.androidDir?.path, repo.root.appendingPathComponent("src-kmp").path)
    XCTAssertEqual(manifest.unscopedGradleTasks, ["jvmTest"])
    let counter = try XCTUnwrap(manifest.feature(named: "counter"))
    XCTAssertTrue(counter.isKmpSourceSet)
    XCTAssertEqual(counter.gradleTestTask, ":subtrees:counter:logic:jvmTest")
  }

  func testPlanShapeMatchesTheContract() throws {
    let repo = try makeTree("mini-swift")
    let plan = ManifestLint.plan(of: try ManifestLint.lint(repo: repo))
    XCTAssertTrue(JSONSerialization.isValidJSONObject(plan))
    XCTAssertEqual(plan["status"] as? String, "ok")
    XCTAssertEqual(plan["errors"] as? [String], [])
    XCTAssertEqual(plan["replayRunner"] as? String, "src-ios/Replay")
    let features = try XCTUnwrap(plan["features"] as? [String: Any])
    let counter = try XCTUnwrap(features["counter"] as? [String: Any])
    XCTAssertEqual(counter["fixtures"] as? [String], ["counter"])
    XCTAssertEqual(counter["state"] as? String, "CounterState")
    let presentation = try XCTUnwrap(plan["presentation"] as? [String: Any])
    XCTAssertEqual((presentation["waivers"] as? [[String: String]])?.count, 0)
  }

  func testLintVerbExitCodes() throws {
    let repo = try makeTree("mini-kmp")
    var options = Options()
    options.command = "lint"
    options.json = true
    XCTAssertEqual(try ManifestLint.run(repo: repo, options: options), 0)
    try delete(repo, "parity/fixtures/counter.fixture.json")
    XCTAssertEqual(try ManifestLint.run(repo: repo, options: options), 1)
  }

  // MARK: - Row 1: parsing (the strict top level, against a real tree)

  func testMisspelledChainsSectionIsNamedAndOrphansItsFixture() throws {
    let repo = try makeTree("mini-dual")
    try rewrite(repo, "parity/manifest.yaml", "chains:", "chanis:")
    let errors = try lintErrors(repo)
    XCTAssertTrue(
      errors.contains(
        "manifest.yaml: unknown top-level key 'chanis' (known: chains, features, mocks, presentation, replayRunner)"),
      "got \(errors)")
    // The failure mode the strictness exists for: the block's chain fixture is
    // no longer gated — and now that is loud, not silent.
    XCTAssertTrue(
      errors.contains("fixture on disk but not in manifest: greeter.wave"), "got \(errors)")
  }

  // MARK: - Row 2: scenario existence

  func testMissingScenarioKey() throws {
    let repo = try makeTree("mini-swift")
    try rewrite(
      repo, "parity/manifest.yaml",
      "    scenario: src-ios/Subtrees/Counter/CounterFeature/Tests/CounterFeatureTests/CounterScenarioTests.swift\n",
      "")
    try assertError(
      repo, containing: "[counter] missing scenario: key (fixtures are compiled from scenarios)")
  }

  func testMissingScenarioFile() throws {
    let repo = try makeTree("mini-kmp")
    try delete(
      repo, "src-kmp/subtrees/counter/logic/src/jvmTest/kotlin/com/mini/counter/CounterScenarioTest.kt")
    try assertError(
      repo,
      containing:
        "[counter] scenario file missing on disk: src-kmp/subtrees/counter/logic/src/jvmTest/kotlin/com/mini/counter/CounterScenarioTest.kt")
  }

  // MARK: - Row 3: fixture symmetry

  func testListedFixtureMissingOnDisk() throws {
    let repo = try makeTree("mini-swift")
    try delete(repo, "parity/fixtures/counter.fixture.json")
    let errors = try lintErrors(repo)
    XCTAssertTrue(
      errors.contains(
        "[counter] fixture listed but missing on disk: counter — just declared? run: tools/duet record --feature counter"),
      "got \(errors)")
  }

  func testOrphanFixtureOnDisk() throws {
    let repo = try makeTree("mini-kmp")
    try Data("{}\n".utf8).write(
      to: repo.root.appendingPathComponent("parity/fixtures/stray.fixture.json"))
    let errors = try lintErrors(repo)
    XCTAssertTrue(errors.contains("fixture on disk but not in manifest: stray"), "got \(errors)")
  }

  func testChainFixtureMissingOnDisk() throws {
    let repo = try makeTree("mini-dual")
    try delete(repo, "parity/fixtures/greeter.wave.fixture.json")
    let errors = try lintErrors(repo)
    XCTAssertTrue(
      errors.contains(
        "[chains] fixture listed but missing on disk: greeter.wave — just declared? run: tools/duet record"),
      "got \(errors)")
  }

  // MARK: - Row 4: the module-name mirror pin

  func testWrongSwiftModuleSuffix() throws {
    let repo = try makeTree("mini-dual")
    try rewrite(
      repo, "parity/manifest.yaml",
      "src-ios/Sources/GreeterFeature/GreeterFeature.swift",
      "src-ios/Sources/GreeterCore/GreeterFeature.swift")
    try assertError(
      repo,
      containing:
        "[greeter] swift module `GreeterCore` breaks the mirror pin (want `<X>Feature` with lower(X) == `greeter`)")
  }

  func testWrongKotlinModuleDir() throws {
    let repo = try makeTree("mini-dual")
    try rewrite(
      repo, "parity/manifest.yaml",
      "src-android/feature-greeter/src/main", "src-android/feature-hello/src/main")
    try assertError(
      repo,
      containing:
        "[greeter] kotlin module `feature-hello` breaks the mirror pin (want `feature-greeter` or `subtrees/greeter/logic`)")
  }

  func testSubtreeGeometryDiverges() throws {
    let repo = try makeTree("mini-dual")
    try rewrite(
      repo, "parity/manifest.yaml",
      "swift: src-ios/Sources/GreeterFeature/GreeterFeature.swift",
      "swift: src-ios/Subtrees/Greeter/GreeterFeature/Sources/GreeterFeature/GreeterFeature.swift")
    try assertError(
      repo,
      containing:
        "[greeter] subtree geometry diverges: swift IS under Subtrees/ but kotlin is NOT under subtrees/greeter/logic")
  }

  func testSingleSourceOutsideSubtrees() throws {
    let repo = try makeTree("mini-kmp")
    try rewrite(
      repo, "parity/manifest.yaml",
      "src-kmp/subtrees/counter/logic/src/commonMain",
      "src-kmp/feature-counter/src/commonMain")
    try assertError(
      repo,
      containing:
        "[counter] single-source kotlin module `feature-counter` must be `subtrees/counter/logic`")
  }

  func testGenericSwiftPMLeafBreaksTheSubtreeLayoutPin() throws {
    let repo = try makeTree("mini-swift")
    try rewrite(
      repo, "parity/manifest.yaml",
      "swift: src-ios/Subtrees/Counter/CounterFeature/Sources/CounterFeature/CounterFeature.swift",
      "swift: src-ios/Subtrees/Counter/Sources/CounterFeature/CounterFeature.swift")
    try assertError(
      repo,
      containing:
        "[counter] subtree package root `src-ios/Subtrees/Counter` breaks the subtree-layout pin")
  }

  func testSubtreeDirMismatch() throws {
    let repo = try makeTree("mini-swift")
    try rewrite(repo, "parity/manifest.yaml", "Subtrees/Counter/", "Subtrees/Timer/")
    try assertError(
      repo, containing: "[counter] subtree dir `Subtrees/Timer` ≠ feature `counter` (mirror pin)")
  }

  func testKotlinOnlyFeatureMustBeCommonMain() throws {
    let repo = try makeTree("mini-kmp")
    try rewrite(
      repo, "parity/manifest.yaml",
      "ticker/logic/src/commonMain", "ticker/logic/src/jvmMain")
    try assertError(
      repo, containing: "[ticker] single-source feature must live in commonMain, got src/jvmMain/")
  }

  func testKotlinPathWithoutSrcSegment() throws {
    let repo = try makeTree("mini-kmp")
    try rewrite(
      repo, "parity/manifest.yaml",
      "kotlin: src-kmp/subtrees/counter/logic/src/commonMain/kotlin",
      "kotlin: src-kmp/subtrees/counter/logic/commonMain/kotlin")
    try assertError(repo, containing: "[counter] kotlin path has no <module>/src/ segment")
  }

  func testFeatureWithNoSourcePath() throws {
    let repo = try makeTree("mini-kmp")
    try rewrite(
      repo, "parity/manifest.yaml",
      "    kotlin: src-kmp/subtrees/counter/logic/src/commonMain/kotlin/com/mini/counter/CounterFeature.kt\n",
      "")
    try assertError(repo, containing: "[counter] declares no source path (`swift:` or `kotlin:`)")
  }

  // MARK: - Row 5: the presentation ledger's entry shape

  func testWaiverMissingKey() throws {
    let repo = try makeTree("mini-dual")
    try rewrite(repo, "parity/manifest.yaml", "      manner: banner fade duration differs\n", "")
    try assertError(
      repo,
      containing: "[presentation] waivers entry greeter.banner-fade: missing keys ['manner']")
  }

  func testWaiverBadPlatform() throws {
    let repo = try makeTree("mini-dual")
    try rewrite(repo, "parity/manifest.yaml", "platform: ios", "platform: macos")
    try assertError(
      repo,
      containing:
        "[presentation] waiver greeter.banner-fade: platform must be ios|android, got 'macos'")
  }

  func testWaiverBadSinceDate() throws {
    let repo = try makeTree("mini-dual")
    try rewrite(
      repo, "parity/manifest.yaml",
      "reason: platform animation defaults\n      since: 2026-08-12",
      "reason: platform animation defaults\n      since: yesterday")
    try assertError(
      repo,
      containing:
        "[presentation] waivers entry greeter.banner-fade: since must be YYYY-MM-DD, got 'yesterday'")
  }

  func testUnprefixedIslandId() throws {
    let repo = try makeTree("mini-dual")
    try rewrite(repo, "parity/manifest.yaml", "id: greeter.map", "id: map.main")
    try assertError(
      repo, containing: "[presentation] islands entry map.main: id must be prefixed 'greeter.'")
  }

  func testWaiverUnknownFeature() throws {
    let repo = try makeTree("mini-dual")
    try rewrite(
      repo, "parity/manifest.yaml",
      "- kind: greeter.banner-fade\n      feature: greeter",
      "- kind: greeter.banner-fade\n      feature: ghost")
    try assertError(repo, containing: "unknown feature 'ghost'")
  }

  // MARK: - Row 6: declaration parity (the migration-window check)

  private let kotlinGreeter =
    "src-android/feature-greeter/src/main/kotlin/com/mini/greeter/GreeterFeature.kt"

  func testStateFieldDivergence() throws {
    let repo = try makeTree("mini-dual")
    try rewrite(repo, kotlinGreeter, "val waveCount", "val waves")
    let errors = try lintErrors(repo)
    XCTAssertTrue(
      errors.contains(
        "[greeter] State lockstep violation: swift-only=['waveCount'] kotlin-only=['waves']"),
      "got \(errors)")
  }

  func testActionCaseDivergenceWithTheCaseFold() throws {
    let repo = try makeTree("mini-dual")
    try rewrite(repo, kotlinGreeter, "data class Reset", "data class ResetAll")
    let errors = try lintErrors(repo)
    // PascalCase folds to the Swift camelCase spelling before comparing.
    XCTAssertTrue(
      errors.contains(
        "[greeter] Action lockstep violation: swift-only=['reset'] kotlin-only=['resetAll']"),
      "got \(errors)")
  }

  func testEffectPayloadCaseDivergence() throws {
    let repo = try makeTree("mini-dual")
    try rewrite(repo, kotlinGreeter, "data class Log", "data class Emit")
    let errors = try lintErrors(repo)
    XCTAssertTrue(
      errors.contains(
        "[greeter] EffectPayload lockstep violation: swift-only=['log'] kotlin-only=['emit']"),
      "got \(errors)")
  }

  func testDeclarationNotFound() throws {
    let repo = try makeTree("mini-dual")
    try rewrite(
      repo, "src-ios/Sources/GreeterFeature/GreeterFeature.swift",
      "public enum GreeterAction", "public enum GreeterActions")
    try assertError(repo, containing: "GreeterAction: declaration not found")
  }

  // MARK: - Sequencing: a lint-red tree stops verify before any lane

  func testRedTreeStopsVerifyAtTheMetaGate() throws {
    let repo = try makeTree("mini-dual")
    try delete(repo, "parity/fixtures/greeter.fixture.json")
    let manifest = try Manifest.load(repo: repo)
    XCTAssertFalse(manifest.lintOK)
    var options = Options()
    options.command = "verify"
    options.json = true
    // Returns at the meta gate — no platform lane subprocess is launched, so
    // this is safe (and fast) to call on a tree with no buildable packages.
    XCTAssertEqual(try Lanes.run(repo: repo, options: options), 1)
  }

  // MARK: - The mocks section (shape checks — bundle download and file
  // currency are `duet mocks`' own job, so lint stays offline)

  private func appendManifest(_ repo: Repo, _ block: String) throws {
    let url = repo.root.appendingPathComponent("parity/manifest.yaml")
    let text = try String(contentsOf: url, encoding: .utf8)
    try Data((text + "\n" + block + "\n").utf8).write(to: url)
  }

  private let goldenMocks = """
    mocks:
      bundle: 0.6.0
      generators:
        counter_mocks:
          output: src-ios/Subtrees/Counter/CounterFeature/Tests/CounterFeatureTests/Generated/CounterMocks.swift
          template: Mocks.swifttemplate
          sources:
            - src-ios/Subtrees/Counter/CounterFeature/Sources
          args:
            - import=Foundation
    """

  func testMocksGoldenRowIsGreenAndRidesThePlan() throws {
    let repo = try makeTree("mini-swift")
    try appendManifest(repo, goldenMocks)
    let result = try ManifestLint.lint(repo: repo)
    XCTAssertEqual(result.errors, [])
    let plan = ManifestLint.plan(of: result)
    let mocks = try XCTUnwrap(plan["mocks"] as? [String: Any])
    XCTAssertEqual(mocks["bundle"] as? String, "0.6.0")
    let generators = try XCTUnwrap(mocks["generators"] as? [String: Any])
    let row = try XCTUnwrap(generators["counter_mocks"] as? [String: Any])
    XCTAssertEqual(row["template"] as? String, "Mocks.swifttemplate")
    XCTAssertEqual(row["args"] as? [String], ["import=Foundation"])

    let manifest = try Manifest.load(repo: repo)
    XCTAssertEqual(manifest.mocksBundle, "0.6.0")
    XCTAssertEqual(manifest.mockGenerators.map(\.name), ["counter_mocks"])
  }

  func testMocksRowsWithoutBundleTagAreNamed() throws {
    let repo = try makeTree("mini-swift")
    try appendManifest(repo, goldenMocks)
    try rewrite(repo, "parity/manifest.yaml", "  bundle: 0.6.0\n", "")
    try assertError(repo, containing: "[mocks] generator rows declared but no bundle: tag")
  }

  func testMocksBundleTagFormIsChecked() throws {
    let repo = try makeTree("mini-swift")
    try appendManifest(repo, goldenMocks)
    try rewrite(repo, "parity/manifest.yaml", "bundle: 0.6.0", "bundle: main")
    try assertError(repo, containing: "[mocks] bundle: expected a swift-sourcery-templates release tag")
  }

  func testMocksRowRequiredKeysAndRootsAreChecked() throws {
    let repo = try makeTree("mini-swift")
    try appendManifest(repo, goldenMocks)
    try rewrite(repo, "parity/manifest.yaml", "      template: Mocks.swifttemplate\n", "")
    try rewrite(
      repo, "parity/manifest.yaml",
      "- src-ios/Subtrees/Counter/CounterFeature/Sources",
      "- src-ios/Subtrees/Counter/NoSuchDir")
    let errors = try lintErrors(repo)
    XCTAssertTrue(
      errors.contains { $0.contains("[mocks.counter_mocks] missing template:") }, "got \(errors)")
    XCTAssertTrue(
      errors.contains { $0.contains("sources: root missing on disk: src-ios/Subtrees/Counter/NoSuchDir") },
      "got \(errors)")
  }

  func testMocksRowNeedsSourcesOrPackageAndValidArgs() throws {
    let repo = try makeTree("mini-swift")
    try appendManifest(
      repo,
      """
      mocks:
        bundle: 0.6.0
        generators:
          rootless:
            output: src-ios/Generated/X.swift
            template: Mocks.swifttemplate
            args:
              - importFoundation
      """)
    let errors = try lintErrors(repo)
    XCTAssertTrue(
      errors.contains { $0.contains("[mocks.rootless] needs sources: roots or a package:") },
      "got \(errors)")
    XCTAssertTrue(
      errors.contains { $0.contains("args: entry is not key=value: 'importFoundation'") },
      "got \(errors)")
  }

  func testMocksPackageWithoutManifestIsNamed() throws {
    let repo = try makeTree("mini-swift")
    try appendManifest(
      repo,
      """
      mocks:
        bundle: 0.6.0
        generators:
          derived:
            output: src-ios/Generated/X.swift
            template: Mocks.swifttemplate
            package: src-ios/NoSuchPackage
      """)
    try assertError(repo, containing: "[mocks.derived] package: src-ios/NoSuchPackage has no Package.swift")
  }
}
