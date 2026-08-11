// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import XCTest

@testable import DuetCLI

final class DoctorTests: XCTestCase {

  // MARK: - [declarations]

  private func geometry(
    kotlinShaped: Bool, existing: Set<String> = ["src-ios/App/xcodegen.yml"]
  ) -> Doctor.Geometry {
    Doctor.Geometry(kotlinShaped: kotlinShaped, fileExists: { existing.contains($0) })
  }

  private func json(_ text: String) -> Data { Data(text.utf8) }

  func testMissingFileIsAFinding() {
    let findings = Doctor.declarationFindings(
      projectJSON: nil, geometry: geometry(kotlinShaped: true))
    XCTAssertEqual(findings.count, 1)
    XCTAssertTrue(findings[0].contains("missing"))
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
        "bootstrap": {"project_name": "WikiMemory"},
        "xcodegen_root": "src-ios/App",
        "custom": 1,
        "targets": {
          "WikiMemory": {"platform": "iOS", "architecture": "duet", "template": "duet-kmp"},
          "WikiMemoryWidgets": {"platform": "iOS", "architecture": "mvvm"},
          "WikiMemoryAndroid": {"platform": "Android", "architecture": "duet", "template": "duet-kmp", "extra": true}
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
    XCTAssertFalse(Doctor.isScannedDirectory("WikiMemoryMainTests"))
    XCTAssertFalse(Doctor.isScannedDirectory(".build"))
    XCTAssertFalse(Doctor.isScannedDirectory("checkouts"))
    XCTAssertTrue(Doctor.isScannedDirectory("Sources"))
    XCTAssertTrue(Doctor.isScannedDirectory("Workers"))
  }
}
