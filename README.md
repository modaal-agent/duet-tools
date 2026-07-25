# duet-tools

[![ci](https://github.com/modaal-agent/duet-tools/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/modaal-agent/duet-tools/actions/workflows/ci.yml)

The open `duet` CLI — the verification toolchain for
[Duet](https://github.com/modaal-agent/duet) repos: dual-platform fixture
verification, scenario-driven recording, the replay-protocol lane, and the
Swift ceremony killer's codegen verb.

The CI matrix (each job writes its toolchain and verdict to the run's job
summary; both lanes build against the sibling `duet` checkout):

| lane | toolchain | proves |
| --- | --- | --- |
| `swift` · macos-26 | Xcode 26.6 (Swift 6.3.3) | the GA floor — the adopter toolchain |
| `swift` · xcode-27 | Xcode 27 beta (Swift 6.4) | the newest proven line |

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
  (lockstep + fixture symmetry), then both platform lanes in parallel, with the
  fixture coverage gate. The Swift lane runs one `swift test` per package root
  (per-feature roots derived from the manifest — multi-package repos with
  subtree packages are first-class; JSON: `lanes.swift` is an array).
- `duet record [--feature <name>] [--platform swift|kotlin] [--check]` —
  scenario-driven fixture regeneration through the framework's ONE §6 writer;
  sum-coder regen is folded in; `--check` is the CI drift gate (R10).
- `duet explain` / `duet materialize <fixture>#<step> --platform <p>` — render
  the last run's failures; emit a standalone failing unit test for one step.
- `duet protocol-run [--runner <path>]` — byte-gate the full corpus through any
  conforming replay-protocol runner (flavor-neutral).
- `duet canonical-sum [--check]` — (re)generate the committed sum coders for
  every `CanonicalSumCodable` enum (normally implicit via `record`).
- `duet write-fixtures` — materialize pending record artifacts into §6 fixture
  files (framework repos' own-corpus regen path).
- `duet scope <path>` — which gates govern a file, and the authoring loop for
  it (the module→gates map, both routing directions; derived from the
  manifest, no configuration).
- `duet mcp` — the same verification verbs as a stdio MCP server
  (`duet_verify`, `duet_record`, `duet_explain`, `duet_materialize`,
  `duet_scope`); tool results are the verbs' `--json` reports. The authoring
  verbs (scaffold/convert/audit) are not served — they are not part of the
  open toolchain.

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
