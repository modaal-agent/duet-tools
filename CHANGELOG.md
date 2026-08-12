# Changelog

## 0.12.0 — 2026-08-12

Pre-1.0 minor: the CLI owns its manifest — the meta-checks that lived in
each adopter repo's `parity/scripts/lockstep-lint.py` are now the
toolchain's, in-process.

### Added — `duet lint`, the in-process manifest parser, and the grammar contract

`duet lint [--json]` runs the manifest meta-checks alone, no lanes — the
fast authoring-loop red while editing `parity/manifest.yaml` or moving
feature sources: scenario existence, fixture symmetry (listed ⊆ disk, no
orphans), the module-name mirror pin, the presentation ledger's entry
shape, and — while a feature declares BOTH `swift:` and `kotlin:` sources —
declaration parity (State property names, Action/EffectPayload case names,
camelCase ↔ PascalCase fold), the check every per-feature migration passes
through. Which rules apply to a feature is derived from the manifest itself
(which source keys exist, and whether the Kotlin path names a `commonMain`
source set), never from repo-level configuration. `--json` emits the plan
(status/errors/features/chains/presentation + top-level scalars) other
tools consume instead of re-parsing the yaml. Served over MCP as
`duet_lint`; `verify` runs the same checks as its first meta-gate,
unchanged in sequence.

The grammar the parser accepts is now a contract:
[contracts/manifest.md](contracts/manifest.md). One deliberate
strictness: unknown TOP-LEVEL manifest keys are a named error (listing the
known set) — the top level routes whole blocks, so a typo'd section header
(a misspelled `chains:`) would otherwise drop its entire block without a
sound, un-gating every chain fixture it declared. Strictness is safe under
the pin regime: the CLI version is pinned per repo, so a manifest never
meets an older parser that doesn't know its keys. Unknown PER-FEATURE keys
remain accepted and ride the plan verbatim.

The test surface gained the fixture-repo harness: three miniature adopter
trees (dual-source, Swift-only, KMP single-source) under `Tests/`, copied
to a temp directory and broken programmatically — every check row has at
least one negative control asserting its named error, and the red-tree
sequencing (lint stops `verify` before any lane) is asserted at the
function seam.

### Changed — manifest loading is in-process; no interpreter runtime needed

Loading the manifest no longer shells to a repo-local python script:
parsing and the meta-checks run inside the CLI, so every verb sheds a
subprocess per invocation and running the toolchain needs no python3
anywhere — build it, run it. An adopter repo's
`parity/scripts/lockstep-lint.py` is dead code from this version's pin
bump onward: delete it when bumping `parity/duet-tools.ref`, in the same
commit.

## 0.11.0 — 2026-08-12

Pre-1.0 minor: a new verb — the mutation drill.

### Added — `duet mutate`

`duet mutate [<name>]` seeds each behavioral mutation declared in
`parity/mutations.json` one at a time (an exact-string substitution that
must match its file exactly once), runs the full suite, and requires it to
go red, recording which lane caught it (swift/kotlin/meta/coverage). A
surviving mutation is a behavior the corpus does not pin — the run fails on
it. A stale row (`old` no longer matching exactly once) is a config-error
that also fails the run: mutation rows target sources, so they die with the
code they target, and the drill sweeps its own table instead of relying on
discipline. The clean tree is verified green before any seeding, and every
mutation is restored — the exact prior bytes, so uncommitted edits in the
target file survive — before the next row runs. `<name>` runs one row: the
authoring loop for a new row. Add at least one row per migration wave; the
row is the wave's permanent negative control.

A suite with no verdict within 10 minutes is treated as hung: the row
counts as caught (a hang never goes green), but the drill stops and fails,
reporting the remaining rows as skipped — the interrupted run's lane
children can still hold build locks, and verdicts taken behind those locks
would be noise.

Not served over MCP: the drill runs the full suite once per row plus a
baseline — minutes, not seconds — outside that surface's synchronous
contract.

### Changed — the version of record is `Sources/duet/Version.swift`

`duetToolsVersion` lives in its own file. A top-level global in `main.swift`
initializes only when the file's top-level code runs, so anything reading it
from a test process reads it uninitialized — the first in-process test
through a `--json` report path crashed on exactly that. The release
workflow's version gate and CONTRIBUTING's version-of-record pointer name
the new file.

## 0.10.0 — 2026-08-11

Pre-1.0 minor: the worker-isolation lint reads three shapes it used to read
wrong. Two of them change what the gate reports, which is what makes this a
minor rather than a patch.

### Fixed — attribute order on a `Sendable` conformance

`@retroactive @unchecked Sendable` declares the same conformance as
`@unchecked Sendable`, and the lint matched only the second spelling, so a
worker stamped the first way passed. The inheritance clause is now parsed
attribute-by-attribute in any order, with attribute arguments consumed
alongside the attribute (`@available(*, deprecated) Foo`), so
`extension Worker: @retroactive Working` also registers as the conformance
it is. No repo in the family stamps its own types with `@retroactive` — it
applies to conformances a module adds to another module's type — so this
widens what the gate catches without changing any current repo's result.

### Fixed — `extension Outer.Inner` attributed to `Outer`

The declaration regex captured the first identifier, so a conformance added
to a nested type marked its enclosing type instead: a stamped `Outer` was a
finding on the strength of `Inner`'s conformance, and a stamped `Inner` was
not. Dotted paths are now captured whole and attributed to their last
component, which is the type the conformance is added to.

### Changed — a worker finding carries its evidence

The finding named the stamped type and left the reader to find the
conformance. It now names the protocol or superclass the conformance came
through and, when that declaration is in another file, its path and line.

The lint resolves names textually: matching declarations by bare name across
the whole scan is what carries a conformance from the file declaring a seam
protocol to the file declaring the worker, and no textual parser can tell
two unrelated same-named types apart. When a name is declared in more than
one place the finding now says so and lists the declarations, so a false
positive from a name collision is read off the message instead of
reconstructed by hand.

### Fixed — doctor's own surfaces name all three rows

0.9.0 added the third row and left `duet doctor`'s usage text and both MCP
descriptions (the server instructions and the `duet_doctor` tool) describing
two. All three now name it.

## 0.9.0 — 2026-08-11

Pre-1.0 minor: `duet doctor` gains a third row, so a repo can no longer hold
a test target that nothing runs.

### Added — `doctor` row 3: tests that have never run

`verify` has printed every build unit outside the manifest since 0.6.0, so a
run states its own coverage boundary. Measured outcome on the reference
repo: the list named a package with a test target for months, on every run,
and nobody acted on it. The list is long and mixes packages another lane
genuinely covers with packages nothing runs at all, so it reads as
inventory, not as a defect.

This row is its narrow half. **A Swift package with no `Package.resolved`
has never been resolved as a root** — a package acquires one the first time
anything builds it standalone (`swift test`, `xcodebuild` against its
scheme) and never from being consumed as a dependency, because the
consumer's lock is the one that gets written. So a test target in such a
package has never run anywhere, and that is a finding.

Two conditions keep it from over-firing, both measured rather than guessed:

- **A test target must be declared.** A library no lane builds standalone is
  the normal case.
- **A remote dependency must be declared.** SwiftPM writes no lock for a
  package whose dependencies are all local paths, however often it is built.
  The reference repo's boundary-lane package runs on every push and has no
  lock for exactly this reason; without the condition it is a false positive.

- **No aggregate `.xcworkspace` may list the package.** A workspace that
  gathers several packages so one scheme runs them all — the "AllTests"
  shape — is a resolution root for its members and writes ONE lock, at
  `<workspace>/xcshareddata/swiftpm/Package.resolved`. Its members' own
  roots stay empty however often their tests run. Measured on a probe
  workspace over a single package, and the shape is in use: a sibling repo
  runs its whole suite this way and has no per-package lock anywhere.
  Membership alone is the exemption, whether or not the workspace's lock is
  committed — the signal cannot see through a workspace, so it must not
  claim through one either. A project's own `project.xcworkspace` is not an
  aggregate: the packages it lists are the project's dependencies, not
  roots.

Both spellings of a remote dependency are recognised (`url:` first, or after
`name:`), across line breaks, and `//` comments are stripped first — with
string literals tracked, so the `//` in an `https://` URL is not mistaken
for one.

Scope is packages OUTSIDE the manifest; the ones inside it are what `verify`
itself runs. The signal is existence on disk, which in CI — a fresh
checkout, where this gates — is exactly "committed". A local tree holding an
untracked lock from a one-off build makes the check silent there: it
under-reports rather than misreports.

Also exposed, unchanged in meaning, for a workflow that generates its steps:
`duet lanes` prints the list under the existing outside-the-manifest block,
and both `lanes --json` and `verify --json` carry it as
`swiftPackagesWithUnrunTests`.

## 0.8.0 — 2026-08-11

Pre-1.0 minor: a new verb — `duet doctor` joins the gate surface.

### Added — `duet doctor`: the declaration-vs-disk cross-check

A repo carries a declaration layer the byte gates never read:
`.modaal/project.json` names the app targets, their platform, the template
each was emitted from, and the cross-platform pair they belong to. Nothing
validated it — a target claiming a template whose shape the repo does not
have, or a template name nothing models, stayed green through every lane.
`duet doctor` reads the declarations and answers: this repo says X; here is
what X implies; here is what is on disk.

Row 1 — declarations. Findings for: a missing or unparseable
`.modaal/project.json`; a target without `platform`; a `template` the
toolchain does not model (models: `duet-kmp`, `duet-swift-ios`,
`duet-swift-scene`); `pair` without `template`; pair members disagreeing on
`template`; an iOS target whose `xcodegen.yml` is absent at the declared (or
default) `xcodegen_root`; and a template whose implied shape contradicts the
manifest — `duet-kmp` on a repo whose manifest derives no Kotlin lane, a
single-core swift template on a repo whose manifest derives one, an Android
target on a template with no Android arm. Targets that declare no `template`
are outside the row's jurisdiction — absence of the marker marks nothing.

Row 2 — the worker-isolation lint. A `Working` conformer declared
`@unchecked Sendable` in non-test sources is a finding, at file:line.
Conformance is closed transitively over the scanned declarations — a seam
protocol refining `Working`, a superclass, or an `extension` adding the
conformance all count, because that is how workers actually conform. The
compiler cannot hold this rule: under complete concurrency checking a
`@MainActor` class is already implicitly `Sendable`, so the redundant
`@unchecked` stamp compiles with no diagnostic while silencing the checking
on a worker that is not isolated. Test sources are out of scope — a double
conforming to a `@MainActor` protocol infers isolation whatever `Sendable`
conformance it declares, so linting it buys nothing.

Boundaries, on purpose: doctor is read-only and rewrites nothing; gate
derivation stays manifest-only — this is the CLI's only `.modaal` consumer;
the source scan is textual (the lint runs on repos whose sources need not
compile on this host) and skips build products, checkouts, and any directory
component ending in `Tests`. Served over MCP as `duet_doctor`.

## 0.7.0 — 2026-08-10

Pre-1.0 minor: changed `record --feature` semantics on the Kotlin path and a
widened host-lane check — gate semantics move, the family's breaking lane.

### Changed — the lockless host-lane check sweeps path dependencies

With no committed `Package.resolved` at a Swift host-lane root, the check used
to grep the ROOT manifest alone for `.package(url:` — a remote dependency
declared in a `.package(path:` child was invisible until a resolution wrote
the root's lockfile, and the meta-check runs before the lanes, so a fresh
checkout (every CI run) passed green with an outside artifact one build away.
The no-lockfile branch now walks the manifest tree: `.package(path:` edges
recursed (both declaration forms, cycle-guarded, comments stripped), any
`.package(url:` in the tree flagged with the path chain that reaches it — the
mirror of the Gradle half's `project(...)` recursion. A path dependency whose
manifest cannot be read is flagged at the declaring edge. Roots with a
committed lockfile are unaffected: the resolved set is already the receipt,
and path-dep growth still needs no allowlist entry.

### Changed — `record --feature` pre-deletes the feature's committed fixtures on the Kotlin path

A behavioral re-record of an EXISTING feature through the Kotlin runner used
to require hand-deleting its fixture files first: the Kotlin writer
regenerates MISSING files only, and the feature's lane task also runs its
golden replays — so the committed files failed their own replay before the
writer ran, and the writer would have skipped them anyway. `record --feature
<name>` now deletes the feature's manifest-declared fixture files before the
lane runs (the recording is bless-by-git; the delete is part of the rewrite),
prints what it pre-deleted, and turns both paths into regeneration.

Boundaries, unchanged on purpose:

- `--check` never pre-deletes: it asks whether the committed files are stale,
  so it must replay them.
- The scoped Swift path needs none of this — the Swift writer overwrites
  under REGEN and the scoped run filters to the scenario class.
- A failed record restores whatever the pre-delete removed and the run did
  not rewrite, so a red lane leaves no fixture missing.
- A pre-deleted fixture the run does NOT regenerate is reported as a removal
  (`removed` in `--json`) instead of disappearing behind "no fixture
  changes" — the manifest still declares it, so retire it from the manifest
  or restore it via git.

## 0.6.0 — 2026-08-09

Pre-1.0 minor: two new verbs, a new advisory meta-check, and changed `record`
semantics (a failing `--check` no longer mutates the fixture tree, unscoped
`record` refuses in the dual-writer window) — gate semantics move, the
family's breaking lane.

### Added — `duet lanes`: the lane inventory as a queryable contract

`verify` computes which Gradle task each module's lane needs, which package
roots resolve, and which fixture×platform pairs must report — and none of it
was reachable from outside the process, so every consumer around the CLI (a
workflow, a fallback runner, a doc) re-derived the lane set by hand.
`duet lanes [--json]` exposes the same derivation: per-feature lane tasks and
filters, the unscoped task set, chains with participants, the protocol lane's
runner, and what `verify` does NOT cover (gradle modules and Swift packages
outside the manifest). Generate workflows from this instead of re-deriving.
Also served over MCP as `duet_lanes`.

### Added — `verify` reports its non-coverage

Silence read as coverage twice: a fallback runner's `./gradlew test` reached
no feature module after a KMP conversion, and a CI comment asserted the host
lane covered every module's JVM battery while `jvmTest` and `test` reach
disjoint module sets. Every unscoped `verify` now ends with the units it makes
no claim about — gradle modules and Swift packages outside the manifest, and
the protocol lane — as a printed footer and a `notCovered` object in `--json`.
Scoped runs state their scope instead.

### Added — `duet assert-replayed`: the empty-pass gate as a verb

`swift test` exits 0 on a target that discovers zero tests, so every
hand-written lane script re-acquires the empty-pass hole the coverage gate
closes inside `verify`. `duet assert-replayed <log|-> [--min <n>]` fails
unless the log shows at least `--min` (default 1) executed tests, taking the
MAXIMUM across runner summaries — XCTest's `Executed N tests`, swift-testing's
`Test run with N tests`, and Gradle's `N tests completed`; `swift test` always
prints both Swift summaries, so a zero line is normal on a green run. Runs
outside a parity repo (it reads a log, not a manifest) — usable from any CI.

### Added — lane-task shape lint (advisory) in `verify`'s meta phase

A KMP migration swaps a module's lane task from `test` to `jvmTest`; the CLI
models that in the unscoped task set while the repo's own automation keeps its
old task list and silently stops reaching migrated modules. `verify` now scans
`.github/workflows/*.yml` and `parity/scripts/*.sh` for `gradlew` lines whose
unqualified lane-family tasks name FEWER tasks than the manifest derives, and
warns with file, line, and the missing task. Module-qualified tasks
(`:app:test`), extra tasks (a superset runs more, not less), and comment lines
stay silent. Warnings never fail the run; `--json` carries them as `warnings`.

### Added — `record --chain <name>`: a chain's own recording scope

The manifest declares chains as fixture names only, so a chain had no scoped
recording path — `--feature` reaches it only when the chain's tests happen to
live in a feature's module, and unscoped `record` is exactly what the
dual-writer window forbids. `record --chain <name>` discovers the test sources
that mention the fixture by name (quoted), derives their lane scopes (Gradle
task + `--tests` filter per module, `swift test --filter` per package root),
and runs exactly those under the regen flag.

### Changed — a failing `record --check` leaves the fixture tree byte-identical

`record --check` used to materialize its rewrite before reporting failure, so
every scenario-drift control needed a fixture-tree restore, not just a source
restore. The rewrite now lands in `parity/.runs/record-check/` and
`parity/fixtures` is restored byte-identically on every failing path —
behavioral drift AND a red lane (Swift runners write directly, so a crashed
pass could leave a partial rewrite). `--write` keeps the rewrite in the tree
(the inspect-in-place repair path, exit code unchanged). Green paths are
unchanged: metadata-only churn still materializes for committing.

### Changed — unscoped `record` refuses in the dual-writer window

A feature declaring BOTH a `swift:` twin and a Kotlin `scenario:` has two
writers for the same fixture files, and an unscoped pass runs every Swift root
under REGEN — the retiring twin re-records fixtures the Kotlin scenario owns.
The CLI can see the condition exactly and now refuses unscoped `record`
(including `--check`) with the dual-writer features named; `--feature` and
`--chain` are the in-window recording paths. Scoped record on a dual-writer
feature now follows the manifest's scenario: a Kotlin `scenario:` records
through the Gradle lane even while the `swift:` twin is still declared
(previously the platform default picked the Swift branch and filtered on a
Kotlin class name — zero tests).

## 0.5.0 — 2026-08-08

Pre-1.0 minor: manifest representation widens (a Swift-only manifest becomes
legal), and two silent-green holes become named meta-errors — gate semantics
move, the family's breaking lane.

### Changed — Swift-only manifests are legal (the KMP mirror)

A manifest with no `kotlin:` paths (the single-lane `duet-swift-ios` shape)
used to die in `Manifest.load` — `layoutUnderivable: no feature kotlin: path
names the Android root directory` — before any verb ran. The Android root is
now derived as optional, the exact mirror of the `swift:` side the KMP flavor
already enjoys: `verify` runs the Swift lanes only and the kotlin half of the
coverage gate doesn't apply; `record` / `record --check` default to the Swift
runner; `protocol-run` builds the Swift `replay-runner` product; `scope`
classifies without an Android tree. Kotlin-rooted repos are unaffected — the
lane derivation reads the same manifest fields it always did. The only
remaining `layoutUnderivable` is a manifest declaring NEITHER side, which no
lane flag can repair.

Mid-migration coexistence gets the mirror too: a fixture owned by a feature
with no Kotlin lane (`kotlin:` empty or `pending`) expects no kotlin-lane
report, and a chain expects one only while every participant has a Kotlin
lane — the participant rule from 0.4.0, applied in both directions.

### Changed — lane flags that name a missing lane are meta-errors

`verify --swift-only` on a KMP-flavor repo (no `swift:` twins) used to skip
BOTH lanes and report PASS having replayed nothing — the coverage gate
expects nothing when both halves are excused. That run, `verify
--kotlin-only` on a Swift-only repo, `record --platform kotlin` without a
Kotlin root, and `protocol-run --platform kotlin` without one now fail with
named errors (exit 1) instead of a silent green or a crash.

### Fixed — `scope` misclassified every path on single-source repos

Rule 4 matched paths against each feature's declared sources with
`hasPrefix`; a single-source feature's undeclared side is the empty string,
and every path has the empty prefix — so on a KMP-flavor repo any path
outside rules 1–3 classified as the alphabetically first feature's module
source. Undeclared sides (empty or `pending`) are now excluded from the
match, and the lockstep note renders as `single-source reducer: <path>` when
only one side exists.

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
