# duet-tools

[![ci](https://github.com/modaal-agent/duet-tools/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/modaal-agent/duet-tools/actions/workflows/ci.yml)

The open `duet` CLI — the verification toolchain for
[Duet](https://github.com/modaal-agent/duet) repos: dual-platform fixture
verification, scenario-driven recording, the replay-protocol lane, and the
Swift ceremony killer's codegen verb.

The CI matrix (each job writes its toolchain and verdict to the run's job
summary; both lanes resolve `duet` from its published tag):

| lane | toolchain | proves |
| --- | --- | --- |
| `swift` · macos-26 | Xcode 26.6 (Swift 6.3.3) | the GA floor — the adopter toolchain |
| `swift` · xcode-27 | Xcode 27 beta (Swift 6.4) | the newest proven line |

## Install

Each release publishes a prebuilt binary for macOS on Apple silicon
(macOS 13+) beside a checksum file:

```sh
TAG=0.10.0   # the version this repo is pinned to
BASE=https://github.com/modaal-agent/duet-tools/releases/download/$TAG
curl -fsSLO $BASE/duet-macos-arm64.zip
curl -fsSLO $BASE/duet-macos-arm64.zip.sha256
shasum -a 256 -c duet-macos-arm64.zip.sha256
unzip duet-macos-arm64.zip     # a bare 'duet' executable
./duet version                 # expect: duet 0.10.0
```

Put it on `PATH`, or point `DUET_BIN` at it — an adopter repo's `tools/duet`
wrapper takes either, and running it needs no Swift toolchain. The `.sha256`
file is `shasum` output, so verification is a command rather than a value to
compare by eye.

On any other platform, build from source at the pinned tag:

```sh
git clone --branch $TAG https://github.com/modaal-agent/duet-tools.git
cd duet-tools && swift build -c release   # .build/release/duet
```

## Why a separate repo

SwiftPM resolves package-level dependencies for every consumer regardless of
which products they link, and resolves one URL package per repository root.
The toolchain carries a swift-syntax dependency (for the sum-coder codegen);
if it lived inside the `duet` library repo, every Duet consumer would fetch
and pin swift-syntax forever. Here the pin stays in the tool's own graph —
apps and test lanes never see it.

## Verbs

```sh
swift run duet help
```

- `duet verify [--feature <name>] [--swift-only|--kotlin-only]` — meta-checks
  (lockstep + fixture symmetry + the host-lane rule + the spec↔fixture
  cross-reference when `parity/feature-specs/` exists: one-pager per feature,
  every declared fixture mentioned, chain participation claims true), then
  both platform lanes in parallel, with the fixture coverage gate
  (mid-migration coexistence: a feature with no `swift:` twin is expected
  kotlin-only, and a CHAIN expects a Swift row only while every participant —
  its fixture's `initialStates` keys — still has a twin). The Swift lane runs one
  `swift test` per package root (per-feature roots derived from the manifest —
  multi-package repos with subtree packages are first-class; JSON:
  `lanes.swift` is an array). The host-lane rule (`HostLane.swift`,
  toolchain-owned so no adopter copies a lint): a gated unit resolves the Duet
  family only — Swift host-root lockfiles pin family identities only, gated
  Kotlin modules declare the family plugin/dependency allowlist only
  (recursing `project(...)` edges), and kernel-shape declarations (reducers,
  State/Action/EffectPayload) live in gated packages only.
- `duet record [--feature <name>|--chain <name>] [--platform swift|kotlin]
  [--check [--write]]` — scenario-driven fixture regeneration through the
  framework's ONE §6 writer; sum-coder regen is folded in; `--check` is the
  CI drift gate: red on behavioral drift (the replay protocol's field set),
  green through metadata-only churn (scenario.source, step label/line — the
  admissible diff of a scenario-language port). A failing `--check` leaves
  `parity/fixtures` byte-identical: the would-be rewrite lands in
  `parity/.runs/record-check/` (`--write` materializes it into the tree
  anyway). `--chain` scopes to one chain fixture — the CLI finds the test
  sources that mention it (quoted) and runs exactly those, so a chain whose
  participants share no module records mid-migration without an unscoped
  pass. While any feature is dual-writer (a `swift:` twin plus a Kotlin
  `scenario:`), unscoped record refuses with the feature named — record per
  feature or per chain inside that window (the writer follows the manifest's
  scenario).
- `duet lanes` — the lane inventory as data: every lane task, package root,
  and filter the manifest derives (what `verify` runs), the chains and their
  participants, the protocol lane's runner, and what `verify` does NOT cover
  (gradle modules and Swift packages outside the manifest). Generate
  workflows and fallback runners from this instead of re-deriving lane sets
  by hand — `verify` prints the same non-coverage on every unscoped run.
- `duet assert-replayed <log|-> [--min <n>]` — the empty-pass gate for
  hand-written lane scripts: fail unless the log shows at least `--min`
  (default 1) executed tests, taking the MAXIMUM across runner summaries
  (XCTest's `Executed N tests`, swift-testing's `Test run with N tests`,
  Gradle's `N tests completed`) — `swift test` always prints both Swift
  summaries, so a zero line is normal on a green run. Works outside a parity
  repo (it reads a log, not a manifest).
- `duet explain` / `duet materialize <fixture>#<step> --platform <p>` — render
  the last run's failures; emit a standalone failing unit test for one step.
- `duet protocol-run [--platform swift|kotlin] [--runner <path>]` — byte-gate
  the full corpus through any conforming replay-protocol runner
  (flavor-neutral). Builds the repo's own runner itself: the Swift
  `replay-runner` product when the manifest has one, else the Kotlin lane's
  `:replay-runner:installDist`; `--platform` forces the choice.
- `duet canonical-sum [--check]` — (re)generate the committed sum coders for
  every `CanonicalSumCodable` enum (normally implicit via `record`).
- `duet write-fixtures` — materialize pending record artifacts into §6 fixture
  files (framework repos' own-corpus regen path).
- `duet scope <path>` — which gates govern a file, and the authoring loop for
  it (the module→gates map, both routing directions; derived from the
  manifest, no configuration).
- `duet doctor` — the declaration-vs-disk cross-check: every target declared
  in `.modaal/project.json` (platform present, template one the toolchain
  models, pair members agreeing on template, an iOS target's `xcodegen.yml`
  present, the template's implied shape matching the manifest's derived
  lanes), plus the worker-isolation lint — a `Working` conformer (direct,
  via a refining protocol, or via a superclass) declared
  `@unchecked Sendable` in non-test sources. The compiler accepts that stamp
  with no diagnostic even under complete concurrency checking, so only a
  lint can hold the rule. Third row: a Swift package outside the manifest
  that declares a test target and has no `Package.resolved` — nothing has
  ever resolved it as a root, so those tests have never run anywhere. Two
  shapes are exempt because for them the missing lock means nothing: a
  package whose dependencies are all local paths (SwiftPM writes it no lock
  ever), and a member of an aggregate `.xcworkspace` (the workspace holds
  the one lock for all its members). Read-only; exit 1 lists findings.
- `duet mcp` — the same verification verbs as a stdio MCP server
  (`duet_verify`, `duet_record`, `duet_explain`, `duet_materialize`,
  `duet_protocol_run`, `duet_scope`, `duet_lanes`, `duet_doctor`); tool
  results are the
  verbs' `--json` reports, each stamped with the toolchain version that
  produced it. The
  authoring verbs (scaffold/convert/audit) are not served — they are not part
  of the open toolchain.

Run from anywhere inside an adopter repo — the root is discovered via
`parity/fixtures`, and the platform roots are derived from the repo's own
parity manifest (no configuration).

## Agent harness setup (MCP)

One entry, launched with `cwd` inside the adopter repo:

```json
{
  "mcpServers": {
    "duet": { "command": "duet", "args": ["mcp"] }
  }
}
```

(Pre-publication, `command` is the adopter repo's `tools/duet` wrapper — same
verbs, run from the local checkout.) The server is synchronous by design:
every verb is seconds-fast on a warm tree, so there is no streaming and no
cancel surface; results carry `structuredContent` alongside the text report.

`CanonicalSumEmission` is exported for
[duet-macros](https://github.com/modaal-agent/duet-macros): both ceremony-killer
vehicles assemble from the one emission rule-set.

## License

MIT — see [LICENSE](LICENSE).
