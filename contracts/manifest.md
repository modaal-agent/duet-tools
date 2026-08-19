# The parity manifest — grammar and plan contract

`parity/manifest.yaml` declares a Duet repo's features, chains, and
presentation ledger. Everything the toolchain does is derived from this file:
which lanes exist, which Gradle tasks they run, which package roots resolve,
what `record` scopes to, which checks apply to which feature. The CLI is the
manifest's ONE parser (`duet lint` exposes the parse + meta-checks alone;
every other verb loads the manifest through the same code), and this document
is the grammar that parser accepts.

The format is a fixed YAML-shaped subset read by a hand-rolled line parser —
not a YAML engine. Keep the indentation shape exactly; a full YAML document
that strays from the forms below is rejected even where a YAML engine would
accept it.

## Grammar

- **Line-oriented.** Comments are stripped at the first `#` (anywhere in the
  line); blank lines are ignored; indentation steps are 2 spaces.
- **Top level** — exactly these forms:
  - `features:` — a map of feature entries (below).
  - `chains:` — a list of `- <fixture>` items at indent 2: chain fixtures,
    gated but owned by no single feature.
  - `presentation:` — the ledger (below).
  - `mocks:` — the code-generation section (below): the release-bundle pin
    and one generator row per committed generated file, `duet mocks`' config.
  - `replayRunner: <dir>` — optional scalar: the Swift package root owning
    the `Sources/replay-runner` executable, for repos whose replay glue
    lives outside every feature package.
- **Unknown top-level keys are an error**, named with the known set. The top
  level routes whole blocks, so a typo'd section header (a misspelled
  `chains:`) would otherwise drop its entire block silently — a misdeclared
  chain is a fixture nobody gates. Strictness is safe under the pin regime:
  the CLI version is pinned per repo (`parity/duet-tools.ref`), so a
  manifest never meets an older parser that doesn't know its keys. A
  top-level line that is neither a section, a known scalar, nor a comment is
  likewise a named error.

### Feature entries

```yaml
features:
  <name>:                 # indent 2; lower-case, one word
    swift: <path>         # indent 4 scalars, `key: value`
    kotlin: <path>
    state: <TypeName>
    action: <TypeName>
    effectPayload: <TypeName>
    scenario: <path>
    fixtures:             # indent 4
      - <fixture>         # indent 6+
```

- `swift:` / `kotlin:` — repo-relative source paths of the feature's
  declarations. Declare the sides the feature has: both (the dual,
  migration-window state), `swift:` only (the Swift-only flavor), or
  `kotlin:` only (the KMP flavor / a fully migrated feature).
  `kotlin: pending` declares a single-sided feature whose Kotlin port has
  not landed. A feature must declare at least one side.
- `state:` / `action:` / `effectPayload:` — the kernel type names; the
  declaration-parity check compares them across the two sources while both
  sides are declared.
- `scenario:` — the test source the feature's fixtures are compiled from;
  required, and the file must exist.
- `fixtures:` — the goldens the feature owns; every listed fixture must
  exist as `parity/fixtures/<name>.fixture.json`, and every fixture on disk
  must be listed (by a feature or a chain) — no orphans.
- **Unknown per-feature keys are accepted** and carried into the plan
  verbatim: feature entries are extensible, and the checks read only the
  keys they know.

### The presentation ledger

```yaml
presentation:
  waivers: []             # or a list of entries
  islands:
    - id: <feature>.<slug>
      feature: <name>
      boundary: <TypeName>
      reason: <text>
      since: YYYY-MM-DD
```

Waiver entries require `kind`, `feature`, `platform` (`ios`|`android`),
`manner`, `reason`, `since`; island entries require `id`, `feature`,
`boundary`, `reason`, `since`. `kind`/`id` are prefixed `<feature>.`, the
feature must exist, and `since` is a `YYYY-MM-DD` date. The lint checks
entry shape only — whether a waiver or island is justified stays review's
job.

### The mocks section

```yaml
mocks:
  bundle: 0.6.1           # the swift-sourcery-templates release tag
  generators:
    <name>:               # indent 4; one row per generated file
      output: <path>      # indent 6 scalars — the committed file, repo-relative
      template: <file>    # entry point inside the bundle's templates/
      package: <dir>      # optional: derive roots from this package's manifest
      sources:            # optional: explicit repo-relative scan roots
        - <dir>
      args:               # template args, key=value
        - import=Foundation
```

- `bundle:` — the release tag of the swift-sourcery-templates artifact
  bundle every row generates with. The bundle carries engine, templates and
  the `mock-templates` CLI together, so this one pin replaces an
  engine/templates version pair. Required once any generator row exists;
  bare semver.
- `generators:` — rows keep declaration order. Each row needs `output:`,
  `template:`, and at least one of `sources:` / `package:`.
- `sources:` — the roots the row owns, scanned first, in order. Keep them as
  narrow as the annotations require: every `.swift` file under a root joins
  the output's fingerprint, so a too-wide root turns unrelated edits into
  staleness churn.
- `package:` — a Swift package directory whose manifest DERIVES the rest of
  the roots (`swift package dump-package`): every path dependency's sources,
  and every Duet family dependency at its exact pin — `duet` scanned whole,
  `duet-services` scanned per linked product — whichever dependency form the
  manifest carries. A family pin is always scanned out of
  `.build/duet-sources/<identity>`, the prefix the fingerprint records — a
  checkout left by a local build supplies the content when it sits on the
  pin, and never moves the paths. The package's own `Sources/` is NOT
  implied; a row that wants it lists it under `sources:`.
- `args:` — `key=value` pairs passed to the template (`import=…`,
  `testable=…`). Unknown per-row keys are accepted and carried into the
  plan, like feature entries.
- At generation, rows run producers-first — a row whose resolved roots
  contain another row's output runs after it — derived from the roots at run
  time; declaration order is the tiebreak, and rows whose roots contain each
  other's outputs are a named error.
- A row whose scan matches no annotated declaration still generates:
  template bundles from **0.6.2** render one marker comment under the header
  instead of an empty file, so the committed output exists — and `--check`
  validates it — before the row's first annotation. Older bundles write
  nothing on an empty render and the row fails generation on the missing
  output, so a row registered ahead of its first annotation needs the
  `bundle:` pin at 0.6.2 or later.

## The checks (`duet lint`, and every verb's manifest load)

Which rules apply to a feature is derived from the manifest itself — which
per-feature keys exist and which source set the Kotlin path names — never
from repo-level configuration:

| derivation | rules applied |
| --- | --- |
| `swift:` declared | the Swift module is `<X>Feature` with `lower(X)` == the feature name; in a split subtree, the package layout is `Subtrees/<Name>/<X>Feature/Sources/<X>Feature/` (a feature-named leaf — SwiftPM derives a path dependency's identity from the lowercased leaf directory alone, so a generic leaf collides with the next subtree's) |
| `kotlin:` declared (not `pending`) | the module dir is `feature-<name>` (flat) or `subtrees/<name>/logic` (subtree); the path carries a `<module>/src/<sourceSet>/` shape |
| both declared | declaration parity — State property names, Action and EffectPayload case names (Kotlin PascalCase folds to Swift camelCase) — and subtree geometry moves in lockstep (swift under `Subtrees/<Name>/` iff kotlin under `subtrees/<name>/`) |
| `src/commonMain/` source set | the module is single-source (the ONE implementation): geometry lockstep is not asserted, and the subtree shape is mandatory |
| `kotlin:` only | the feature must BE single-source (`commonMain`) |

Plus, independent of flavor: scenario existence, fixture symmetry (listed ⊆
disk, no orphans), the ledger's entry shape, and the mocks section's shape —
parse errors, the scalar set (`bundle` is the only known scalar), the
bundle-tag form, each row's required keys, on-disk existence of `sources:`
roots and the `package:` manifest, `key=value` args, and row-name uniqueness.
Lint stays offline: the bundle download and the generated files' currency are
`duet mocks --check`'s job, never lint's. `verify` runs all of this
as its first meta-gate — a lint failure stops the run before any lane.

## The plan (`duet lint --json`)

One JSON object: `status` (`ok`|`fail`), `errors` (every violation, in check
order), `features` (each entry's scalars verbatim plus its `fixtures` list),
`chains`, `presentation` (`waivers`/`islands` as parsed), `mocks` (bundle +
generator rows, when the section exists), the known top-level scalars
(`replayRunner`), and the `toolchain` stamp every `duet` JSON report
carries. Consume the plan instead of re-parsing the yaml —
that is what the CLI itself does.
