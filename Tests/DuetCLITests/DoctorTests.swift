// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import XCTest

@testable import DuetCLI

final class DoctorTests: XCTestCase {

  // MARK: - [declarations]

  /// `swiftShaped` defaults to the opposite of `kotlinShaped` — the
  /// single-lane manifest the shape rows answer for. The mixed and featureless
  /// states pass it explicitly.
  private func geometry(
    kotlinShaped: Bool, swiftShaped: Bool? = nil,
    existing: Set<String> = ["src-ios/App/xcodegen.yml"]
  ) -> Doctor.Geometry {
    Doctor.Geometry(
      kotlinShaped: kotlinShaped, swiftShaped: swiftShaped ?? !kotlinShaped,
      fileExists: { existing.contains($0) })
  }

  private func json(_ text: String) -> Data { Data(text.utf8) }

  func testMissingFileIsNoFinding() {
    // A repo without .modaal/project.json keeps no declaration layer.
    XCTAssertEqual(
      Doctor.declarationFindings(projectJSON: nil, geometry: geometry(kotlinShaped: true)), [])
    XCTAssertEqual(
      Doctor.declarationFindings(projectJSON: nil, geometry: geometry(kotlinShaped: false)), [])
  }

  func testRepoWithoutDeclarationsPasses() throws {
    // mini-kmp carries no .modaal/ directory.
    let repo = try makeMiniTree("mini-kmp")
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: repo.root.appendingPathComponent(".modaal/project.json").path))
    var options = Options()
    options.command = "doctor"
    XCTAssertEqual(try Doctor.run(repo: repo, options: options), 0)
    options.json = true
    XCTAssertEqual(try Doctor.run(repo: repo, options: options), 0)
  }

  func testRepoWithoutDeclarationsStillRunsTheWorkerLint() throws {
    let repo = try makeMiniTree("mini-kmp")
    let dir = repo.root.appendingPathComponent("src-ios/Sources/App")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(
      "final class SessionWorker: Working, @unchecked Sendable {}\n".utf8
    ).write(to: dir.appendingPathComponent("Workers.swift"))
    var options = Options()
    options.command = "doctor"
    XCTAssertEqual(try Doctor.run(repo: repo, options: options), 1)
  }

  func testInvalidJSONIsAFinding() {
    let findings = Doctor.declarationFindings(
      projectJSON: json("not json"), geometry: geometry(kotlinShaped: true))
    XCTAssertEqual(findings.count, 1)
    XCTAssertTrue(findings[0].contains("not a JSON object"))
  }

  func testHandMigratedShapePasses() {
    // The reference repo's shape: two duet-kmp targets without `pair`, an
    // unmarked non-Duet target, a bootstrap block, keys the check has no
    // name for. Kotlin-shaped manifest, xcodegen.yml on disk.
    let text = """
      {
        "bootstrap": {"project_name": "SampleApp"},
        "xcodegen_root": "src-ios/App",
        "custom": 1,
        "targets": {
          "SampleApp": {"platform": "iOS", "architecture": "duet", "template": "duet-kmp"},
          "SampleAppWidgets": {"platform": "iOS", "architecture": "mvvm"},
          "SampleAppAndroid": {"platform": "Android", "architecture": "duet", "template": "duet-kmp", "extra": true}
        }
      }
      """
    XCTAssertEqual(
      Doctor.declarationFindings(projectJSON: json(text), geometry: geometry(kotlinShaped: true)),
      [])
  }

  func testUnmodeledTemplateIsAFinding() {
    let text = """
      {"targets": {"FreshAndroid": {"platform": "Android", "template": "duet-does-not-exist"}}}
      """
    let findings = Doctor.declarationFindings(
      projectJSON: json(text), geometry: geometry(kotlinShaped: true))
    XCTAssertEqual(findings.count, 1)
    XCTAssertTrue(findings[0].contains("duet-does-not-exist"))
    XCTAssertTrue(findings[0].contains("FreshAndroid"))
  }

  func testSwiftTemplateOnKotlinShapedRepoIsAFinding() {
    // The measured mis-declaration: the repo's manifest derives a Kotlin
    // lane while the target claims the single-core swift template.
    let text = """
      {"targets": {"Fresh": {"platform": "iOS", "template": "duet-swift-ios"}}}
      """
    let findings = Doctor.declarationFindings(
      projectJSON: json(text), geometry: geometry(kotlinShaped: true))
    XCTAssertEqual(findings.count, 1)
    XCTAssertTrue(findings[0].contains("derives a Kotlin lane"))
  }

  func testKmpTemplateOnSwiftOnlyRepoIsAFinding() {
    let text = """
      {"targets": {"FreshiOS": {"platform": "iOS", "template": "duet-kmp"}}}
      """
    let findings = Doctor.declarationFindings(
      projectJSON: json(text), geometry: geometry(kotlinShaped: false))
    XCTAssertEqual(findings.count, 1)
    XCTAssertTrue(findings[0].contains("derives no Kotlin lane"))
  }

  func testAMixedManifestHoldsBothShapeRows() {
    // The per-feature migration window: rows cross one at a time, so the app
    // being migrated declares its Swift template while the manifest already
    // derives a Kotlin lane. Neither shape row has a case to answer, and the
    // other rows still do (this target's xcodegen.yml is on disk).
    let text = """
      {"targets": {
        "TrailJournal": {"platform": "iOS", "template": "duet-swift-ios"},
        "TrailJournalAndroid": {"platform": "Android", "template": "duet-kmp"}
      }}
      """
    XCTAssertEqual(
      Doctor.declarationFindings(
        projectJSON: json(text), geometry: geometry(kotlinShaped: true, swiftShaped: true)),
      [])
  }

  func testAFeaturelessManifestHoldsBothShapeRows() {
    // Day 0 of a Kotlin-shaped repo: no features yet, so the manifest derives
    // neither lane and cannot contradict either template claim.
    let text = """
      {"targets": {
        "Fresh": {"platform": "iOS", "template": "duet-kmp"},
        "FreshAndroid": {"platform": "Android", "template": "duet-kmp"}
      }}
      """
    XCTAssertEqual(
      Doctor.declarationFindings(
        projectJSON: json(text), geometry: geometry(kotlinShaped: false, swiftShaped: false)),
      [])
  }

  func testTheMigrationMarkersOwnTargetsAreHeldAndOthersAreNot() {
    // The grafted Android target declares the Kotlin shape before the first
    // `kotlin:` row exists; a target the marker does not name is checked as
    // usual, so the swift-only manifest still answers for 'OtheriOS'.
    let text = """
      {
        "migration": {"route": "duet-swift-to-kmp", "targets": {
          "ios": "TrailJournal", "android": "TrailJournalAndroid"}},
        "targets": {
          "TrailJournalAndroid": {"platform": "Android", "template": "duet-kmp"},
          "OtheriOS": {"platform": "iOS", "template": "duet-kmp"}
        }
      }
      """
    let findings = Doctor.declarationFindings(
      projectJSON: json(text), geometry: geometry(kotlinShaped: false))
    XCTAssertEqual(findings.count, 1)
    XCTAssertTrue(findings[0].contains("OtheriOS"), findings[0])
    XCTAssertTrue(findings[0].contains("derives no Kotlin lane"))
  }

  func testAndroidTargetOnSwiftTemplateIsAFinding() {
    let text = """
      {"targets": {"FreshAndroid": {"platform": "Android", "template": "duet-swift-ios"}}}
      """
    let findings = Doctor.declarationFindings(
      projectJSON: json(text), geometry: geometry(kotlinShaped: false))
    XCTAssertEqual(findings.count, 1)
    XCTAssertTrue(findings[0].contains("no Android target shape"))
  }

  func testIOSTargetWithoutXcodegenIsAFinding() {
    let text = """
      {"targets": {"FreshiOS": {"platform": "iOS", "template": "duet-swift-ios"}}}
      """
    let findings = Doctor.declarationFindings(
      projectJSON: json(text), geometry: geometry(kotlinShaped: false, existing: []))
    XCTAssertEqual(findings.count, 1)
    XCTAssertTrue(findings[0].contains("xcodegen.yml is absent"))
  }

  func testPairMembersMustAgreeOnTemplate() {
    let text = """
      {"targets": {
        "FreshiOS": {"platform": "iOS", "template": "duet-swift-ios", "pair": "Fresh"},
        "FreshAndroid": {"platform": "Android", "template": "duet-kmp", "pair": "Fresh"}
      }}
      """
    let findings = Doctor.declarationFindings(
      projectJSON: json(text), geometry: geometry(kotlinShaped: true))
    XCTAssertTrue(findings.contains { $0.contains("pair 'Fresh'") && $0.contains("disagree") })
  }

  func testPairWithoutTemplateIsAFinding() {
    let text = """
      {"targets": {"FreshiOS": {"platform": "iOS", "pair": "Fresh"}}}
      """
    let findings = Doctor.declarationFindings(
      projectJSON: json(text), geometry: geometry(kotlinShaped: false))
    XCTAssertEqual(findings.count, 1)
    XCTAssertTrue(findings[0].contains("`pair` without `template`"))
  }

  func testMissingPlatformIsAFinding() {
    let text = """
      {"targets": {"Mystery": {"architecture": "mv"}}}
      """
    let findings = Doctor.declarationFindings(
      projectJSON: json(text), geometry: geometry(kotlinShaped: false))
    XCTAssertEqual(findings.count, 1)
    XCTAssertTrue(findings[0].contains("declares no `platform`"))
  }

  func testDuetBlockShapesAreChecked() {
    let text = """
      {"duet": {"template": "no-such", "flavor": "objc"}}
      """
    let findings = Doctor.declarationFindings(
      projectJSON: json(text), geometry: geometry(kotlinShaped: false))
    XCTAssertEqual(findings.count, 2)
    XCTAssertTrue(
      findings.contains { $0.contains("'objc' — this toolchain models 'swift', 'kmp' and 'twins'") },
      "\(findings)")
  }

  // MARK: - [declarations] at `layout` 2

  /// Three apps on a Gradle build at the repository root: `foyer` with an
  /// iOS and an Android target, its variant `foyerlite`, and the Android-only
  /// `tally`.
  private static let layout2 = """
    {
      "layout": 2,
      "duet": {"template": "duet-kmp", "flavor": "kmp", "projectName": "Suite", "kotlinPackage": "com.acme"},
      "apps": {
        "foyer": {"name": "Foyer", "kotlinPackage": "com.acme.foyer"},
        "foyerlite": {"name": "FoyerLite", "variantOf": "foyer"},
        "tally": {"name": "Tally", "kotlinPackage": "com.acme.tally"}
      },
      "targets": {
        "Foyer": {"platform": "iOS", "architecture": "duet", "template": "duet-kmp", "app": "foyer"},
        "FoyerAndroid": {"platform": "Android", "architecture": "duet", "template": "duet-kmp", "app": "foyer"},
        "FoyerLite": {"platform": "iOS", "architecture": "duet", "template": "duet-kmp", "app": "foyerlite"},
        "TallyAndroid": {"platform": "Android", "architecture": "duet", "template": "duet-kmp", "app": "tally"}
      }
    }
    """

  private func layout2Findings(
    _ text: String = DoctorTests.layout2, existing: Set<String> = ["apps/foyer/ios/xcodegen.yml"]
  ) -> [String] {
    Doctor.declarationFindings(
      projectJSON: json(text), geometry: geometry(kotlinShaped: true, existing: existing))
  }

  func testALayout2RegistryPasses() {
    XCTAssertEqual(layout2Findings(), [])
  }

  func testAnIOSTargetsSpecIsItsAppsAndAVariantsIsItsBaseApps() {
    let findings = layout2Findings(existing: [])
    XCTAssertEqual(
      findings,
      [
        "[declarations] target 'Foyer' declares an iOS target but apps/foyer/ios/xcodegen.yml is absent",
        "[declarations] target 'FoyerLite' declares an iOS target but apps/foyer/ios/xcodegen.yml is absent",
      ])
  }

  func testAnAppNeedsExactlyOneOfAPackageAndABase() {
    let both = DoctorTests.layout2.replacingOccurrences(
      of: #""variantOf": "foyer"}"#, with: #""variantOf": "foyer", "kotlinPackage": "com.acme.lite"}"#)
    XCTAssertEqual(
      layout2Findings(both),
      ["[declarations] .modaal/project.json: app 'foyerlite' needs exactly one of `kotlinPackage` and `variantOf`"])
    let neither = DoctorTests.layout2.replacingOccurrences(
      of: #"{"name": "Tally", "kotlinPackage": "com.acme.tally"}"#, with: #"{"name": "Tally"}"#)
    XCTAssertEqual(
      layout2Findings(neither),
      ["[declarations] .modaal/project.json: app 'tally' needs exactly one of `kotlinPackage` and `variantOf`"])
  }

  func testAVariantNamesAnAppThatIsNoVariant() {
    let unknown = DoctorTests.layout2.replacingOccurrences(
      of: #""variantOf": "foyer""#, with: #""variantOf": "atlas""#)
    XCTAssertTrue(
      layout2Findings(unknown).contains(
        "[declarations] .modaal/project.json: app 'foyerlite': `variantOf` names no app: 'atlas'"),
      "\(layout2Findings(unknown))")
    let chained = DoctorTests.layout2.replacingOccurrences(
      of: #""tally": {"name": "Tally", "kotlinPackage": "com.acme.tally"}"#,
      with: #""tally": {"name": "Tally", "variantOf": "foyerlite"}"#)
    XCTAssertEqual(
      layout2Findings(chained),
      ["[declarations] .modaal/project.json: app 'tally': a variant of a variant ('foyerlite')"])
  }

  func testATargetNamesAnAppOfTheRegistry() {
    let unknown = DoctorTests.layout2.replacingOccurrences(of: #""app": "tally""#, with: #""app": "atlas""#)
    XCTAssertEqual(
      layout2Findings(unknown),
      ["[declarations] .modaal/project.json: target 'TallyAndroid' names no app of the `apps` registry: 'atlas'"])
    let missing = DoctorTests.layout2.replacingOccurrences(of: #", "app": "tally""#, with: "")
    XCTAssertEqual(
      layout2Findings(missing),
      [
        "[declarations] .modaal/project.json: target 'TallyAndroid' declares no `app` — at `layout` 2"
          + " each templated target names its app in the `apps` registry"
      ])
  }

  func testAnAppsTargetsAgreeOnTemplateAndAVariantCountsAsItsBase() {
    let text = DoctorTests.layout2.replacingOccurrences(
      of: #""FoyerLite": {"platform": "iOS", "architecture": "duet", "template": "duet-kmp""#,
      with: #""FoyerLite": {"platform": "iOS", "architecture": "duet", "template": "duet-twins""#)
    XCTAssertEqual(
      layout2Findings(text),
      [
        "[declarations] app 'foyer': targets disagree on `template` (Foyer → 'duet-kmp', FoyerAndroid → 'duet-kmp',"
          + " FoyerLite → 'duet-twins') — an app's targets are emitted from one template"
      ])
  }

  func testPairIsALayout1Key() {
    let text = DoctorTests.layout2.replacingOccurrences(
      of: #""app": "tally"}"#, with: #""app": "tally", "pair": "Tally"}"#)
    XCTAssertEqual(
      layout2Findings(text),
      [
        "[declarations] .modaal/project.json: target 'TallyAndroid': `pair` is a layout-1 key (at `layout` 2"
          + " a target names its `app`)"
      ])
  }

  func testLayout2NeedsARegistry() {
    let text = """
      {"layout": 2, "targets": {"Foyer": {"platform": "iOS", "template": "duet-kmp", "app": "foyer"}}}
      """
    let findings = layout2Findings(text)
    XCTAssertEqual(findings.first, "[declarations] .modaal/project.json: `layout` is 2 and `apps` is not a non-empty object")
  }

  func testAnUnmodeledOrMalformedLayoutIsAFinding() {
    XCTAssertEqual(
      layout2Findings(#"{"layout": 3}"#),
      ["[declarations] .modaal/project.json: `layout` is 3 — this toolchain models 1 and 2"])
    XCTAssertEqual(
      layout2Findings(#"{"layout": "2"}"#),
      ["[declarations] .modaal/project.json: `layout` is not an integer"])
  }

  func testWithoutLayoutTheRegistryIsNotReadAndTheSpecIsTheXcodegenRoots() {
    // The layout-1 rows: `pair` groups, the spec at `xcodegen_root`.
    let text = """
      {"apps": {"x": {}}, "targets": {
        "Foyer": {"platform": "iOS", "template": "duet-kmp", "pair": "Foyer"},
        "FoyerAndroid": {"platform": "Android", "template": "duet-kmp", "pair": "Foyer"}
      }}
      """
    XCTAssertEqual(layout2Findings(text, existing: ["src-ios/App/xcodegen.yml"]), [])
  }

  // MARK: - [declarations] on a twins tree

  /// The doctor verb end to end on a copy of a mini tree: the declaration rows
  /// read its `.modaal/project.json`, the shape rows the manifest's lanes.
  private func doctorExit(_ repo: Repo) throws -> Int32 {
    var options = Options()
    options.command = "doctor"
    options.json = true
    return try Doctor.run(repo: repo, options: options)
  }

  private func treeFindings(_ repo: Repo) throws -> [String] {
    let manifest = try Manifest.load(repo: repo)
    return Doctor.declarationFindings(
      projectJSON: try Data(contentsOf: repo.root.appendingPathComponent(".modaal/project.json")),
      geometry: Doctor.Geometry(
        kotlinShaped: manifest.androidDir != nil,
        swiftShaped: !manifest.swiftPackageDirs.isEmpty,
        fileExists: { FileManager.default.fileExists(atPath: repo.root.appendingPathComponent($0).path) }))
  }

  func testATwinsDeclarationOverATwoSidedManifestPasses() throws {
    // Two paired targets on `duet-twins`, `duet.flavor: twins`, and a manifest
    // deriving both lanes: one row with a twin on each side.
    let repo = try makeMiniTree("mini-twins")
    let manifest = try Manifest.load(repo: repo)
    XCTAssertNotNil(manifest.androidDir)
    XCTAssertFalse(manifest.swiftPackageDirs.isEmpty)
    XCTAssertEqual(try treeFindings(repo), [])
    XCTAssertEqual(try doctorExit(repo), 0)
  }

  func testATwinsDeclarationOverAKotlinOnlyManifestPasses() throws {
    // The tree before the Swift twin joins: the Kotlin twin alone, a plain JVM
    // module, recorded by its own Kotlin scenario. The template is
    // Kotlin-shaped, so the single Kotlin lane answers for it.
    let repo = try makeMiniTree("mini-twins")
    try Data(
      """
      features:
        greeter:
          kotlin: src-android/subtrees/greeter/logic/src/main/kotlin/com/mini/greeter/GreeterFeature.kt
          state: GreeterState
          action: GreeterAction
          effectPayload: GreeterEffectPayload
          scenario: src-android/subtrees/greeter/logic/src/test/kotlin/com/mini/greeter/GreeterScenarioTest.kt
          fixtures:
            - greeter
      """.utf8
    ).write(to: repo.manifestFile)
    try FileManager.default.removeItem(
      at: repo.fixturesDir.appendingPathComponent("profile.fixture.json"))
    try FileManager.default.removeItem(
      at: repo.fixturesDir.appendingPathComponent("greeter.handoff.fixture.json"))
    let manifest = try Manifest.load(repo: repo)
    XCTAssertNotNil(manifest.androidDir)
    XCTAssertTrue(manifest.swiftPackageDirs.isEmpty)
    XCTAssertEqual(try treeFindings(repo), [])
    XCTAssertEqual(try doctorExit(repo), 0)
  }

  func testATwinsDeclarationOverASwiftOnlyManifestIsAFinding() {
    // The negative control for the row above: `duet-twins` implies a Kotlin
    // lane, so a manifest deriving only the Swift lane contradicts it.
    let text = """
      {"targets": {"Mini": {"platform": "iOS", "template": "duet-twins"}}}
      """
    let findings = Doctor.declarationFindings(
      projectJSON: json(text), geometry: geometry(kotlinShaped: false))
    XCTAssertEqual(findings.count, 1)
    XCTAssertTrue(findings[0].contains("derives no Kotlin lane"), findings[0])
  }

  func testAnUnknownTemplateOnATwinsTreeIsStillAFinding() throws {
    let repo = try makeMiniTree("mini-twins")
    try rewriteMiniTree(
      repo, ".modaal/project.json",
      #""MiniAndroid": {"platform": "Android", "architecture": "duet", "template": "duet-twins""#,
      #""MiniAndroid": {"platform": "Android", "architecture": "duet", "template": "duet-twin""#)
    let findings = try treeFindings(repo)
    XCTAssertTrue(
      findings.contains {
        $0.contains("target 'MiniAndroid' names no template this toolchain models: 'duet-twin'")
          && $0.contains("duet-twins")
      },
      "\(findings)")
    XCTAssertEqual(try doctorExit(repo), 1)
  }

  func testAnUnknownFlavorOnATwinsTreeIsStillAFinding() throws {
    let repo = try makeMiniTree("mini-twins")
    try rewriteMiniTree(
      repo, ".modaal/project.json", #""flavor": "twins""#, #""flavor": "twin""#)
    XCTAssertEqual(
      try treeFindings(repo),
      [
        "[declarations] .modaal/project.json: `duet.flavor` is 'twin' — this toolchain models "
          + "'swift', 'kmp' and 'twins'"
      ])
    XCTAssertEqual(try doctorExit(repo), 1)
  }

  // MARK: - [workers]

  func testDirectConformerStampedUncheckedIsAFinding() {
    let source = """
      final class FreshnessWorker: Working, @unchecked Sendable {
        func run() async {}
      }
      """
    let findings = Doctor.workerFindings(files: [("Sources/App/FreshnessWorker.swift", source)])
    XCTAssertEqual(findings.count, 1)
    XCTAssertTrue(findings[0].contains("FreshnessWorker.swift:1"))
    XCTAssertTrue(findings[0].contains("'FreshnessWorker'"))
  }

  func testRefiningProtocolConformerIsAFinding() {
    // The reference shape: the worker conforms through a seam protocol.
    let seam = """
      protocol LocationWorking: Working {
        func fetch() async
      }
      """
    let worker = """
      final class LocationWorker: LocationWorking, @unchecked Sendable {
        func run() async {}
      }
      """
    let findings = Doctor.workerFindings(
      files: [("Sources/App/Seam.swift", seam), ("Sources/App/Worker.swift", worker)])
    XCTAssertEqual(findings.count, 1)
    XCTAssertTrue(findings[0].contains("'LocationWorker'"))
    // The seam is named, so the reader does not re-derive the chain.
    XCTAssertTrue(findings[0].contains("via 'LocationWorking'"))
  }

  func testRetroactiveUncheckedStampIsAFinding() {
    // Attribute order is the author's choice; both spellings are the same
    // conformance.
    let source = """
      final class AudioWorker: Working {
        func run() async {}
      }

      extension AudioWorker: @retroactive @unchecked Sendable {}
      """
    let findings = Doctor.workerFindings(files: [("Sources/App/AudioWorker.swift", source)])
    XCTAssertEqual(findings.count, 1)
    XCTAssertTrue(findings[0].contains("AudioWorker.swift:5"))
  }

  func testNestedExtensionAttributesToTheInnerType() {
    // `extension Outer.Inner` adds the conformance to Inner. Outer carries
    // the stamp and is NOT a worker.
    let source = """
      final class Outer: @unchecked Sendable {
        final class Inner {}
      }

      extension Outer.Inner: Working {}
      """
    XCTAssertEqual(Doctor.workerFindings(files: [("Sources/App/Outer.swift", source)]), [])
  }

  func testStampedInnerTypeIsAFinding() {
    // The positive control for the case above: move the stamp to Inner and
    // the same extension marks it.
    let source = """
      final class Outer {
        final class Inner: @unchecked Sendable {}
      }

      extension Outer.Inner: Working {}
      """
    let findings = Doctor.workerFindings(files: [("Sources/App/Outer.swift", source)])
    XCTAssertEqual(findings.count, 1)
    XCTAssertTrue(findings[0].contains("'Inner'"))
  }

  func testANameDeclaredTwiceIsReportedAsSuch() {
    // Two unrelated types sharing a name share their inheritance clauses —
    // textual name resolution is what carries a seam protocol across files.
    // The finding says where the conformance came from and that the name is
    // not unique, which is what makes it triageable.
    let worker = """
      final class Freshness: Working {
        func run() async {}
      }
      """
    let unrelated = """
      final class Freshness: @unchecked Sendable {
        let cache = NSCache<NSString, NSData>()
      }
      """
    let findings = Doctor.workerFindings(
      files: [("Sources/App/Freshness.swift", worker), ("Sources/Net/Freshness.swift", unrelated)])
    XCTAssertEqual(findings.count, 1)
    XCTAssertTrue(findings[0].contains("Sources/Net/Freshness.swift:1"))
    XCTAssertTrue(findings[0].contains("declared at Sources/App/Freshness.swift:1"))
    XCTAssertTrue(findings[0].contains("declared in 2 places"))
  }

  func testExtensionAddedStampIsAFinding() {
    let source = """
      final class AudioWorker: Working {
        func run() async {}
      }

      extension AudioWorker: @unchecked Sendable {}
      """
    let findings = Doctor.workerFindings(files: [("Sources/App/AudioWorker.swift", source)])
    XCTAssertEqual(findings.count, 1)
    XCTAssertTrue(findings[0].contains("AudioWorker.swift:5"))
  }

  func testWorkingSuffixedNameIsNotAConformance() {
    // `LocationWorking` as a PROPERTY TYPE or an unrelated conformance must
    // not mark the declaring type; word-bounded matching only.
    let source = """
      final class LiveEnvironment: AppleEnvironment, @unchecked Sendable {
        let locationWorker: LocationWorking
        init(locationWorker: LocationWorking) { self.locationWorker = locationWorker }
      }
      """
    XCTAssertEqual(Doctor.workerFindings(files: [("Sources/App/Env.swift", source)]), [])
  }

  func testUncheckedWithoutWorkingIsClean() {
    let source = """
      final class CaptureMediaStaging: @unchecked Sendable {
        private let lock = NSLock()
      }
      """
    XCTAssertEqual(Doctor.workerFindings(files: [("Sources/App/Staging.swift", source)]), [])
  }

  func testWorkerWithoutStampIsClean() {
    let source = """
      @MainActor
      final class FreshnessWorker: Working {
        func run() async {}
      }
      """
    XCTAssertEqual(Doctor.workerFindings(files: [("Sources/App/Worker.swift", source)]), [])
  }

  func testGenericConstraintDoesNotMarkTheDeclaringType() {
    // `Working` in a generic parameter list is a constraint, not a
    // conformance of the declaring type.
    let source = """
      public final class WorkerBox<W: Working>: @unchecked Sendable {
        let worker: W
        init(worker: W) { self.worker = worker }
      }
      """
    XCTAssertEqual(Doctor.workerFindings(files: [("Sources/App/Box.swift", source)]), [])
  }

  // MARK: - scan scope

  func testTestDirectoriesAreNotScanned() {
    XCTAssertFalse(Doctor.isScannedDirectory("Tests"))
    XCTAssertFalse(Doctor.isScannedDirectory("SampleAppMainTests"))
    XCTAssertFalse(Doctor.isScannedDirectory(".build"))
    XCTAssertFalse(Doctor.isScannedDirectory("checkouts"))
    XCTAssertTrue(Doctor.isScannedDirectory("Sources"))
    XCTAssertTrue(Doctor.isScannedDirectory("Workers"))
  }
}
