# Changelog

## [0.2.0] — 2026-08-01

**Breaking per family convention** (pre-1.0 minors are the breaking lane): the
gate grew — a repo green under 0.1.0 can be red under this release. Nothing
about the lanes, the fixture dialect, or the framework pin changed; the new
red is a meta-check verdict, repaired in the adopter repo (move the offending
dependency to its node package / app side), never by pinning the toolchain
back.

### Added — the host-lane meta-check (`duet verify`)

`verify` now gates **the host-lane rule** — a gated unit resolves the Duet
family and nothing else — in the meta phase beside the lockstep lint, on both
build systems (`HostLane.swift`). SwiftPM's `condition: .when(platforms:)`
gates linking only; version resolution and build-tool-plugin planning walk
straight through it, so an app library reachable from a host-lane root puts
its whole toolchain surface (codegen plugins included) inside the parity
gate's blast radius. Three checks, with gated units derived from the manifest
exactly as the lanes are — coverage is total by construction, and a new
feature package arrives pre-gated:

- **Swift host-root lockfiles** — every host-lane root's `Package.resolved`
  pins family identities only. No lockfile is legal exactly when the root's
  manifest declares no remote dependency (the private phase's local-path
  family graph); a remote dependency without a committed lock is red.
- **The Gradle twin** — every gated Kotlin module declares the family
  plugin/dependency allowlist only, recursing `project(...)` edges so a
  module reached through one must hold the line too (errors name the path).
  `kotlin.multiplatform` is allowed for the single-source flavor's gated
  modules; AGP plugins are not, anywhere.
- **Kernel declaration scope** — reducers, and the manifest's
  State/Action/EffectPayload types, may be declared in gated packages only;
  outside a lane a declaration is invisible to both declaration-parity and
  the fixture gate.

The allowlists are toolchain-owned family constants — adopter repos get the
gate without copying a lint, and there is no repo override. App-local growth
needs none: Swift path dependencies never enter a lockfile and Gradle
`project(...)` dependencies recurse instead of matching, so only a new
EXTERNAL artifact inside a gated unit is a family decision. `record` stays
ungated — it is how a red tree gets repaired.

### Added — `duet version`

Prints the toolchain version (matches the release tag; `--version` aliases
it), resolving before repo discovery so it works from anywhere — gate
receipts can now record which toolchain produced them.

## [0.1.0] — 2026-07-29

The first tagged release — the toolchain pin matching duet `0.1.0`
(`DuetReplay`, the byte-gate writer, resolved from the published tag: the
package is self-contained, no sibling checkout). The `duet` CLI's initial
verb surface:

- `verify` — meta-checks (lockstep lint + fixture symmetry), then both
  platform lanes in parallel with the per-fixture coverage gate. One
  `swift test` per package root, derived from the manifest — multi-package
  repos (subtree feature packages beside an aggregator) are first-class.
- `record` / `record --check` — scenario-driven fixture regeneration through
  the framework's one canonical writer, sum-coder regen folded in; `--check`
  is the CI drift gate.
- `explain`, `materialize`, `scope` — failure rendering, standalone failing
  tests per fixture step, and the module→gates map.
- `protocol-run` — byte-gates the corpus through any replay-protocol runner
  (the repo's own Swift runner by default; `--runner` drives a prebuilt
  flavor, e.g. the Kotlin lane's installDist output).
- `write-fixtures`, `canonical-sum` — the record pipeline's standalone
  halves.
- `mcp` — the verification verbs as a stdio MCP server.
- Single-source (KMP-flavor) repos: kotlin-only manifests (no `swift:`
  twins → no Swift lane), `record` defaults to the Kotlin runner, KMP
  modules' lane task is `jvmTest`, and the manifest-level `replayRunner:`
  key covers repos whose replay glue lives outside every feature package.
- The CLI module is `DuetCLI` while the product stays `duet` (a module named
  `duet` case-collides with the framework's `Duet` library on
  case-insensitive APFS).
