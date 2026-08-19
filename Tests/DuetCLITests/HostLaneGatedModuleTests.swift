// Copyright (c) 2026 Modaal.dev
// Licensed under the MIT License. See LICENSE file for details.

import XCTest

@testable import DuetCLI

/// The gated-module line scan, rule by rule, on source text — no filesystem.
final class HostLaneGatedModuleTests: XCTestCase {

  private func scan(_ source: String) -> (errors: [String], projectPaths: [String]) {
    HostLane.scanGatedBuildScript(label: "subtrees/sample/logic", source: source)
  }

  func testFamilyShapeWithMockEngineWiringPasses() {
    let result = scan(
      """
      plugins {
        alias(libs.plugins.kotlin.multiplatform)
        alias(libs.plugins.kotlin.serialization)
        alias(libs.plugins.ksp)
      }
      kotlin {
        sourceSets {
          commonMain.dependencies {
            api(libs.duet.kernel)
            implementation(libs.kotlinx.serialization.json)
            api(project(":telemetry"))
          }
          jvmTest.dependencies {
            implementation(libs.duet.kernel.test)
            implementation(kotlin("test"))
            implementation(libs.kotlinx.coroutines.test)
          }
        }
      }
      dependencies {
        "kspJvmTest"(libs.mocks.processor)
      }
      ksp {
        arg("kspMocksTargets", "com.example.SampleEnvironment")
      }
      """)
    XCTAssertEqual(result.errors, [])
    XCTAssertEqual(result.projectPaths, ["telemetry"])
  }

  func testMainCompilationProcessorIsAPlacementViolation() {
    let result = scan("dependencies {\n  ksp(libs.mocks.processor)\n}")
    XCTAssertEqual(result.errors.count, 1)
    XCTAssertTrue(result.errors[0].contains("wires a symbol processor into `ksp`"))
    XCTAssertTrue(result.errors[0].contains("kspTest/kspJvmTest"))
  }

  func testNativeTargetProcessorConfigurationIsAPlacementViolation() {
    let result = scan("  kspIosArm64(libs.mocks.processor)")
    XCTAssertEqual(result.errors.count, 1)
    XCTAssertTrue(result.errors[0].contains("`kspIosArm64`"))
  }

  func testUnknownProcessorArtifactIsRejected() {
    let result = scan("  kspJvmTest(libs.other.processor)")
    XCTAssertEqual(result.errors.count, 1)
    XCTAssertTrue(result.errors[0].contains("outside the processor allowlist"))
  }

  func testAgpPluginAliasStaysRejected() {
    let result = scan("plugins {\n  alias(libs.plugins.android.library)\n}")
    XCTAssertEqual(result.errors.count, 1)
    XCTAssertTrue(result.errors[0].contains("outside the plugin"))
  }

  func testUnlistedExternalDependencyStaysRejected() {
    let result = scan("  implementation(libs.some.networking)")
    XCTAssertEqual(result.errors.count, 1)
    XCTAssertTrue(result.errors[0].contains("outside the dependency allowlist"))
  }

  func testUnquotedAccessorSpellingIsScannedToo() {
    let result = scan("  kspTest(libs.other.processor)")
    XCTAssertEqual(result.errors.count, 1)
    XCTAssertTrue(result.errors[0].contains("outside the processor allowlist"))
  }

  func testProcessorAsProjectDependencyRecursesInsteadOfMatching() {
    let result = scan("  kspJvmTest(project(\":tools:mock-processor\"))")
    XCTAssertEqual(result.errors, [])
    XCTAssertEqual(result.projectPaths, ["tools:mock-processor"])
  }
}
