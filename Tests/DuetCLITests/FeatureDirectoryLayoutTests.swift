// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import XCTest

@testable import DuetCLI

/// A tree whose Gradle build is at the repository root and whose features
/// each sit in one directory with a folder per part: `subtrees/<name>/core`
/// (the multiplatform logic), `subtrees/<name>/ios/<X>Feature` (a Swift
/// core) and `subtrees/<name>/android/logic` (a JVM core). The mini trees
/// are moved into that shape on disk and in the manifest; the shapes they
/// started in keep their own tests in `ManifestLintTests`.
final class FeatureDirectoryLayoutTests: XCTestCase {

  // MARK: - Harness

  private func move(_ repo: Repo, _ from: String, _ to: String) throws {
    let target = repo.root.appendingPathComponent(to)
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: repo.root.appendingPathComponent(from), to: target)
  }

  private func write(_ repo: Repo, _ path: String, _ text: String) throws {
    let url = repo.root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  private func errors(_ repo: Repo) throws -> [String] {
    try ManifestLint.lint(repo: repo).errors
  }

  private func assertError(
    _ repo: Repo, containing needle: String, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let errors = try errors(repo)
    XCTAssertTrue(
      errors.contains { $0.contains(needle) }, "no error contains '\(needle)'; got \(errors)",
      file: file, line: line)
  }

  /// mini-kmp with its Gradle build at the repository root and each feature's
  /// module at `subtrees/<name>/core`.
  private func kmpAtTheRoot() throws -> Repo {
    let repo = try makeMiniTree("mini-kmp")
    for name in ["counter", "ticker"] {
      try move(repo, "src-kmp/subtrees/\(name)/logic", "subtrees/\(name)/core")
      try rewriteMiniTree(
        repo, "parity/manifest.yaml", "src-kmp/subtrees/\(name)/logic/", "subtrees/\(name)/core/")
    }
    try write(
      repo, "settings.gradle.kts",
      "rootProject.name = \"mini\"\ninclude(\":subtrees:counter:core\")\ninclude(\":subtrees:ticker:core\")\n")
    return repo
  }

  /// mini-twins with its Gradle build at the repository root: `greeter`'s
  /// Kotlin twin at `subtrees/greeter/android/logic`, and both features'
  /// Swift packages under `subtrees/<name>/ios/`.
  private func twinsInFeatureDirectories() throws -> Repo {
    let repo = try makeMiniTree("mini-twins")
    try move(repo, "src-android/settings.gradle.kts", "settings.gradle.kts")
    try move(repo, "src-android/replay-runner", "replay-runner")
    try move(repo, "src-android/subtrees/greeter/logic", "subtrees/greeter/android/logic")
    try rewriteMiniTree(
      repo, "parity/manifest.yaml", "src-android/subtrees/greeter/logic/", "subtrees/greeter/android/logic/")
    for (name, type) in [("greeter", "Greeter"), ("profile", "Profile")] {
      try move(repo, "src-ios/Subtrees/\(type)/\(type)Feature", "subtrees/\(name)/ios/\(type)Feature")
      try rewriteMiniTree(
        repo, "parity/manifest.yaml", "src-ios/Subtrees/\(type)/\(type)Feature/", "subtrees/\(name)/ios/\(type)Feature/")
    }
    return repo
  }

  // MARK: - The Gradle root

  func testTheGradleRootIsTheNearestAncestorHoldingASettingsFile() throws {
    let repo = try kmpAtTheRoot()
    let path = "subtrees/counter/core/src/commonMain/kotlin/com/mini/counter/CounterFeature.kt"
    XCTAssertEqual(GradleRoot.depth(ofKotlinPath: path, repoRoot: repo.root), 0)
    try write(repo, "subtrees/settings.gradle.kts", "")
    XCTAssertEqual(GradleRoot.depth(ofKotlinPath: path, repoRoot: repo.root), 1)
  }

  func testABuildInASubdirectoryResolvesAsItsFirstComponent() throws {
    let repo = try makeMiniTree("mini-twins")
    XCTAssertEqual(
      GradleRoot.depth(
        ofKotlinPath: "src-android/subtrees/greeter/logic/src/main/kotlin/com/mini/greeter/GreeterFeature.kt",
        repoRoot: repo.root),
      1)
    let manifest = try Manifest.load(repo: repo)
    XCTAssertEqual(manifest.androidDir?.path, repo.root.appendingPathComponent("src-android").path)
    XCTAssertEqual(manifest.feature(named: "greeter")?.kotlinModulePath, "subtrees/greeter/logic")
  }

  func testWithoutASettingsFileTheFirstComponentIsTheGradleRoot() throws {
    // mini-kmp declares no settings file: its root stays `src-kmp`.
    let repo = try makeMiniTree("mini-kmp")
    XCTAssertNil(
      GradleRoot.depth(
        ofKotlinPath: "src-kmp/subtrees/counter/logic/src/commonMain/kotlin/com/mini/counter/CounterFeature.kt",
        repoRoot: repo.root))
    XCTAssertEqual(try errors(repo), [])
    XCTAssertEqual(try Manifest.load(repo: repo).feature(named: "counter")?.gradleTestTask, ":subtrees:counter:logic:jvmTest")
  }

  func testABuildAtTheRepositoryRootDerivesItsModulesAndTasks() throws {
    let repo = try kmpAtTheRoot()
    XCTAssertEqual(try errors(repo), [])
    let manifest = try Manifest.load(repo: repo)
    XCTAssertEqual(manifest.androidDir?.standardizedFileURL.path, repo.root.standardizedFileURL.path)
    let counter = try XCTUnwrap(manifest.feature(named: "counter"))
    XCTAssertEqual(counter.kotlinModulePath, "subtrees/counter/core")
    XCTAssertEqual(counter.gradleTestTask, ":subtrees:counter:core:jvmTest")
  }

  func testScopeRoutesAModuleOfABuildAtTheRepositoryRoot() throws {
    let repo = try kmpAtTheRoot()
    let manifest = try Manifest.load(repo: repo)
    let feature = Scope.classify(
      "subtrees/counter/core/src/commonMain/kotlin/com/mini/counter/Other.kt", repo: repo, manifest: manifest)
    XCTAssertEqual(feature.feature, "counter")
    let build = Scope.classify("settings.gradle.kts", repo: repo, manifest: manifest)
    XCTAssertEqual(build.role, "Android build tree (outside any parity feature module)")
    let other = Scope.classify("README.md", repo: repo, manifest: manifest)
    XCTAssertEqual(other.role, "NOT governed by the duet parity gates")
  }

  // MARK: - `subtrees/<name>/core`

  func testTheMultiplatformCoreShapeUnderKotlinCoreJvmIsNamed() throws {
    let repo = try makeMiniTree("mini-twins")
    try move(repo, "src-android/subtrees/greeter/logic", "src-android/subtrees/greeter/core")
    try rewriteMiniTree(repo, "parity/manifest.yaml", "subtrees/greeter/logic/", "subtrees/greeter/core/")
    try assertError(
      repo,
      containing:
        "[greeter] kotlin module `subtrees/greeter/core` is the multiplatform shape, but the manifest"
        + " declares `kotlinCore: jvm`")
  }

  func testASingleSourceModuleOutsideTheSubtreesNamesBothShapes() throws {
    let repo = try kmpAtTheRoot()
    try move(repo, "subtrees/counter/core", "feature-counter")
    try rewriteMiniTree(repo, "parity/manifest.yaml", "subtrees/counter/core/", "feature-counter/")
    try assertError(
      repo,
      containing:
        "[counter] single-source kotlin module `feature-counter` must be `subtrees/counter/logic` or"
        + " `subtrees/counter/core`")
  }

  // MARK: - `subtrees/<name>/android/logic` and `subtrees/<name>/ios/<X>Feature`

  func testTwinsInFeatureDirectoriesPass() throws {
    let repo = try twinsInFeatureDirectories()
    XCTAssertEqual(try errors(repo), [])
    let manifest = try Manifest.load(repo: repo)
    let greeter = try XCTUnwrap(manifest.feature(named: "greeter"))
    XCTAssertEqual(greeter.kotlinModulePath, "subtrees/greeter/android/logic")
    XCTAssertEqual(greeter.gradleTestTask, ":subtrees:greeter:android:logic:test")
    XCTAssertEqual(greeter.swiftModule, "GreeterFeature")
    XCTAssertEqual(greeter.swiftPackageRelative, "subtrees/greeter/ios/GreeterFeature")
  }

  func testTheJvmCoreShapeWithoutKotlinCoreJvmIsNamed() throws {
    let repo = try twinsInFeatureDirectories()
    try rewriteMiniTree(repo, "parity/manifest.yaml", "kotlinCore: jvm\n", "")
    try assertError(
      repo,
      containing:
        "[greeter] kotlin module `subtrees/greeter/android/logic` is a JVM core's shape: declare"
        + " `kotlinCore: jvm`")
  }

  func testAJvmCoreBesideASwiftTwinInAnotherTreeIsNamed() throws {
    let repo = try twinsInFeatureDirectories()
    try move(repo, "subtrees/greeter/ios/GreeterFeature", "src-ios/Subtrees/Greeter/GreeterFeature")
    try rewriteMiniTree(
      repo, "parity/manifest.yaml", "subtrees/greeter/ios/GreeterFeature/", "src-ios/Subtrees/Greeter/GreeterFeature/")
    try assertError(
      repo,
      containing:
        "[greeter] subtree geometry diverges: swift is under `src-ios/Subtrees/Greeter/GreeterFeature`"
        + " and kotlin under `subtrees/greeter`")
  }

  func testASwiftTwinInAnotherFeaturesDirectoryIsNamed() throws {
    let repo = try twinsInFeatureDirectories()
    try move(repo, "subtrees/greeter/android/logic", "src-android/subtrees/greeter/logic")
    try move(repo, "settings.gradle.kts", "src-android/settings.gradle.kts")
    try rewriteMiniTree(
      repo, "parity/manifest.yaml", "subtrees/greeter/android/logic/", "src-android/subtrees/greeter/logic/")
    try assertError(
      repo,
      containing:
        "[greeter] subtree geometry diverges: swift is under `subtrees/greeter` and kotlin under"
        + " `src-android/subtrees/greeter`")
  }

  func testASwiftCoreInItsFeaturesIosFolderPasses() throws {
    let repo = try makeMiniTree("mini-swift")
    try move(repo, "src-ios/Subtrees/Counter/CounterFeature", "subtrees/counter/ios/CounterFeature")
    try rewriteMiniTree(
      repo, "parity/manifest.yaml", "src-ios/Subtrees/Counter/CounterFeature/", "subtrees/counter/ios/CounterFeature/")
    XCTAssertEqual(try errors(repo), [])
  }

  func testAGenericLeafInTheIosFolderBreaksTheSubtreeLayoutPin() throws {
    let repo = try makeMiniTree("mini-swift")
    try move(repo, "src-ios/Subtrees/Counter/CounterFeature", "subtrees/counter/ios")
    try rewriteMiniTree(
      repo, "parity/manifest.yaml", "src-ios/Subtrees/Counter/CounterFeature/", "subtrees/counter/ios/")
    try assertError(
      repo,
      containing:
        "[counter] subtree package root `subtrees/counter/ios` breaks the subtree-layout pin (want"
        + " `subtrees/counter/ios/CounterFeature/Sources/CounterFeature/`")
  }

  func testAFeatureDirectoryNamedForAnotherFeatureIsNamed() throws {
    let repo = try makeMiniTree("mini-swift")
    try move(repo, "src-ios/Subtrees/Counter/CounterFeature", "subtrees/timer/ios/CounterFeature")
    try rewriteMiniTree(
      repo, "parity/manifest.yaml", "src-ios/Subtrees/Counter/CounterFeature/", "subtrees/timer/ios/CounterFeature/")
    try assertError(repo, containing: "[counter] subtree dir `subtrees/timer` ≠ feature `counter` (mirror pin)")
  }

  // MARK: - `kotlinReplayRunner:`

  func testTheKotlinReplayRunnerDefaultsToTheReplayRunnerProject() throws {
    let manifest = try Manifest.load(repo: try makeMiniTree("mini-twins"))
    XCTAssertEqual(manifest.kotlinReplayRunnerProject, ":replay-runner")
    let gradleRoot = URL(fileURLWithPath: "/repo/src-android")
    let runner = ProtocolLane.kotlinRunner(project: manifest.kotlinReplayRunnerProject, gradleRoot: gradleRoot)
    XCTAssertEqual(runner.directory, "replay-runner")
    XCTAssertEqual(runner.launcher.path, "/repo/src-android/replay-runner/build/install/replay-runner/bin/replay-runner")
  }

  func testTheManifestNamesTheKotlinReplayRunnersProject() throws {
    let repo = try kmpAtTheRoot()
    try rewriteMiniTree(repo, "parity/manifest.yaml", "features:\n", "kotlinReplayRunner: :tools:replay-runner\n\nfeatures:\n")
    XCTAssertEqual(try errors(repo), [])
    let manifest = try Manifest.load(repo: repo)
    XCTAssertEqual(manifest.kotlinReplayRunnerProject, ":tools:replay-runner")
    let runner = ProtocolLane.kotlinRunner(project: manifest.kotlinReplayRunnerProject, gradleRoot: repo.root)
    XCTAssertEqual(runner.directory, "tools/replay-runner")
    XCTAssertEqual(
      runner.launcher.path,
      repo.root.appendingPathComponent("tools/replay-runner/build/install/replay-runner/bin/replay-runner").path)
  }

  func testAKotlinReplayRunnerThatIsNoGradleProjectPathIsNamed() throws {
    let repo = try kmpAtTheRoot()
    try rewriteMiniTree(repo, "parity/manifest.yaml", "features:\n", "kotlinReplayRunner: tools/replay-runner\n\nfeatures:\n")
    try assertError(
      repo,
      containing:
        "manifest.yaml: kotlinReplayRunner must be a Gradle project path such as :replay-runner or"
        + " :tools:replay-runner, got 'tools/replay-runner'")
  }

  func testGradleProjectPaths() {
    for valid in [":replay-runner", ":tools:replay-runner", ":a_b.c"] {
      XCTAssertTrue(ManifestParser.isGradleProjectPath(valid), valid)
    }
    for invalid in ["", ":", "replay-runner", ":tools::runner", ":tools:", ":a b", "tools/replay-runner"] {
      XCTAssertFalse(ManifestParser.isGradleProjectPath(invalid), invalid)
    }
  }
}
