# Changelog

## 0.4.0 — 2026-08-03

Pre-1.0 minor: a changed gate (the family's breaking lane).

### Changed

- **`verify`'s chain coverage follows participants.** A chain fixture expects
  a Swift-lane report only while EVERY participant feature (the fixture's own
  `initialStates` keys — the spec↔fixture meta-check's derivation) still has a
  `swift:` twin. The aggregator's chain scenario cannot compile a retired
  twin's reducer, so its authoring retires with the twin and the committed
  fixture is frozen bytes — the Kotlin lane's chain replays and the protocol
  lane keep gating it — until the chain corpus itself ports.
  Falsifier pair on the adopter's first retired-participant chain
  (`chain-invitecode-finish`): 0.3.0 red (`missing … [swift]`) vs 0.4.0 green;
  negative control: an all-twin chain's dropped report still fails.
  (`record --check` needs no twin change: an unrecorded chain's committed file
  is untouched, so the digest comparison is naturally silent about it.)

## [0.3.0] — 2026-08-03

**Breaking per family convention** (pre-1.0 minors are the breaking lane):
gate semantics move — `record --check`'s red narrows to behavioral drift,
the unscoped Kotlin lane's task set widens on mixed trees, and `verify`
grows a meta-check (the spec↔fixture cross-reference) on repos that carry
`parity/feature-specs/`. This is the toolchain minor a per-feature
twin→single-source migration needs, folded with the approved graduation
rows: landed before the first port wave so the wave oracle, the
mixed-tree lane, and the graduated checks are toolchain-owned, not
per-repo scripts and aliases.

### Changed — `record --check` gates behavioral drift only (metadata-aware)

The drift gate used to hash whole fixture files, so a scenario-language port
— which rewrites `scenario.source` and step `label`/`line` metadata by design
— read as staleness: every fixture in a port wave would go red while being
behaviorally byte-identical. `--check` now splits the digest and gates only
the replay protocol's field set (leaves: `initialState` + each step's
`action`/`expectedState`/`expectedEffects`; chains: `initialStates` + the
step's `node` as well). Metadata-only churn reports green as the admissible
diff, with its own listing (`metadataOnly` in `--json` and the MCP report);
behavioral drift stays exit 1. Plain `record` annotates metadata-only
rewrites in its summary.

### Changed — per-module lane-task selection on mixed trees

A KMP module's JVM host lane is `jvmTest`; a plain JVM module's is `test`.
The unscoped lane task was picked all-or-nothing (`jvmTest` only when EVERY
manifest feature was KMP-shaped), so a mid-migration mixed tree ran `test`
and silently skipped every migrated module — caught only as missing fixture
reports, and until now bridged by a per-module `test`-task alias in the
adopter repo. The lane now derives the task SET from the manifest's source
sets (`test`, `jvmTest`, or both) and lets Gradle match them per module,
with a per-task `--rerun` (it is a task option — one trailing `--rerun`
would leave the earlier task UP-TO-DATE and its reports unwritten). The
adopter-side alias retires.

### Fixed — the drift digest compared prefix hashes, not bytes

Found while landing the split, red-team control in hand: the whole-file
digest used `Data.hashValue`, and Foundation's Data hash considers only the
first ~80 bytes plus the length (NSData `-hash` bridging — verified
empirically: two 200-byte blobs differing at offset 150 hash EQUAL). A
same-length fixture change past the header — e.g. a step's expected count
`1` → `9` deep in the file — hashed identical, so `record --check` since
0.1.0 could report "up to date" over real drift. Both halves of the new
split snapshot the full bytes and compare them directly.

Mixed-tree coexistence rides the same change end-to-end (a feature with no
`swift:` twin beside features that still have one):

- **verify's coverage gate** expects a migrated feature's fixtures on the
  Kotlin lane only (chains keep the manifest-level rule — they ride the
  aggregator's Swift lane until the chain corpus itself ports).
- **Scoped runs of a migrated feature** (`verify`/`record --feature X`) skip
  the Swift lane / default to the Kotlin runner instead of failing to derive
  a Swift package root.
- **Unscoped `record` (and so `record --check`)** adds one Gradle launch for
  the migrated features' scoped lane tasks beside the Swift package roots —
  without it the drift gate would silently stop covering every ported
  feature for the whole span of the migration.

### Added — the spec↔fixture cross-reference joins `verify`'s meta-checks

Graduated from the adopter repos' `parity/scripts/spec-fixture-lint.py`
(until now the one meta-check the CLI did not own), checks
verbatim: every manifest feature has a one-pager in `parity/feature-specs/`,
every declared leaf fixture is mentioned in its feature's spec (backticked
id or the `family.*` + `.slug` shorthand), every backticked `chain-*` token
names a real chain fixture, and every chain fixture is mentioned in every
participating feature's spec (participants = the chain's `initialStates`
keys). Applies only when `parity/feature-specs/` exists — the directory is
the adopter's opt-in to the prose discipline. The CLI has no config surface,
so the spec filename convention is `<feature>.md` exactly: a repo whose
historical spec stems differ renames the files when it adopts this release,
and retires its copy of the lint plus the separate CI step.

### Added — `protocol-run` builds either flavor's runner, speaks `--json`, and is MCP-visible

The flavor-neutral byte gate could not build its own runner on the
single-source flavor (no Swift `replay-runner` package to probe — the caller
had to hand-build `installDist` and pass `--runner`), and was absent from
the MCP catalog. Now: with no `--runner` override the
CLI builds the repo's own runner — the Swift `replay-runner` product when
the manifest has a package for it, else the Kotlin lane's
`:replay-runner:installDist` (convention: the `replay-runner` Gradle module
at the Android root); `--platform swift|kotlin` forces the choice on repos
carrying both, which is also how a mid-migration tree byte-gates the corpus
through the *other* flavor's runner. `protocol-run --json` emits the
structured report, and `duet_protocol_run` serves it over MCP.

### Added — every `--json` report is stamped with the toolchain version

`toolchain: "<version>"` rides every `--json` report (and so every MCP tool
result via `structuredContent`), so gate receipts record which toolchain ran
without hand-assembly.

## [0.2.1] — 2026-08-02

Gate semantics unchanged — a patch release.

### Fixed — a red lane with no fixture failures now names what failed

When a lane fails with zero failed fixture reports (a compile error, a crashed
suite, a red non-fixture test), `verify` used to print only a fixed 30-line
log tail — which can scroll past the one line naming the failing test, and
did, in the first adopter CI run under the CLI shape: the output showed
"Executed 97 tests, with 1 failure" with the failing row's name
unrecoverable. `verify` now mines the red lane's log for failure-shaped lines
and prints them above the tail: XCTest case + assertion lines, swift-testing
issues, Swift traps, swiftc/kotlinc compile errors, and Gradle test-row /
task / build failures, capped at 40 with an elision count (a looping test's
repeated assertion details fill the cap — every such line still carries the
test's name, and the count points at the log). `--json` lane entries (and so
the MCP verbs' reports) carry the same lines as `failureLines`, present only
on a red lane.

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
