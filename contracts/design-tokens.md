# The design-token config — grammar and generated shape

`parity/design-tokens.yaml` is a repo's design-token master: one app-authored
document carrying the semantic vocabularies and their values.
`duet design-tokens` generates the vocabulary enums and the value tables in
every language the config declares a target for, and
`duet design-tokens --check` fails while a generated file disagrees with the
config. This document is the grammar that generator accepts.

The format is YAML, read with a YAML engine — the config nests lists of maps
and carries folded block scalars for every token's prose. Strictness lives at
the schema walk instead of at the parser: every key is checked against the
known set for its position, and an unknown one is an error naming the token it
sits on, so a misspelled `lightAlpha` cannot silently drop an alpha channel.

## What is generated, and what is not

Generated — the two layers that have a twin on the other platform:

| layer | Swift | Kotlin |
| --- | --- | --- |
| vocabulary | `SemanticColor.swift`, `SemanticFont.swift`, `SemanticGradient.swift` | `SemanticColor.kt`, `SemanticFont.kt`, `SemanticGradient.kt` |
| values | `<theme>Palette.swift` | `<palette>.kt` |

Hand-authored — everything whose shape is one platform's alone:

- **The role bindings.** Which token fills `onSurfaceVariant`, which fills an
  Apple role. Material slots and Apple roles are different sets, so a binding
  has no twin to drift from.
- **The resolvers.** Turning a family token and its axes into a registered
  face reads app-owned font resources: `R.font.*` on Android, a bundle
  registration on Apple.
- **The theme type and its registration** — `MainTheme`, the `Themeable` and
  `ThemeDefaulting` conformances, and Swift's `fontSet(for:)`, which builds a
  `FontSet` from the generated `fontToken(for:)` record.

Cross-language name and value identity holds by construction: both languages
are emitted from one input, in one declaration order.

## Grammar

```yaml
version: 1                   # the schema version; required

swift:                       # optional; declare the targets this repo has
  output: <dir>              # repo-relative directory the files are written to
  engine: DuetTheming        # the theming module the generated files import
  theme: MainTheme           # the Assetable type the value tables extend

kotlin:                      # optional
  output: <dir>
  package: com.example.theming            # the generated declarations' package
  engine: dev.modaal.duet.services.theming  # where the value types come from
  palette: MainPalette                    # the object the value tables go in

colors:
  - group: Labels            # optional heading, emitted as a section comment
    tokens:
      - name: labelPrimary   # lowerCamelCase; becomes a case in both languages
        doc: >-              # optional; the vocabulary case's doc comment
          What the token means and where it is used.
        note: >-             # optional; the palette entry's comment
          Why the value is what it is.
        light: "#14130F"     # two-appearance form
        dark: "#ECE9E0"
        lightAlpha: 0.24     # optional, 0…1; defaults to 1
        darkAlpha: 0.5
      - name: avatarText
        value: "#FFFFFF"     # one-value form: the same colour in both
        alpha: 1             # optional, 0…1

fonts:
  - group: Body — the serif face
    tokens:
      - name: bodyRegular
        doc: >-
          …
        note: >-
          …
        family: serif        # serif | sans | mono
        weight: 400
        size: 17
        lineHeight: 26
        tracking: 0.08       # optional; a fraction of the em, default 0
        opticalSize: 17      # optional; the `opsz` axis
        softness: 20         # optional; the `SOFT` axis
        width: 100           # optional; the `wdth` axis
        swift:
          textStyle: body    # UIFont.TextStyle the cut scales against

gradients:
  - name: mainColorBg
    doc: >-
      …
    note: >-
      …
    stops: ["#F1F0EC", "#F1F0EC"]   # one-value form; two or more, `#RRGGBB`
  - name: heroWash
    light: ["#FBFAF7", "#FFFFFF"]        # two-appearance form
    dark: ["#141414", "#1E1E1E"]
```

- **At least one of `swift:` / `kotlin:` is required.** A config with neither
  generates nothing.
- **Colours are `#RRGGBB`** — six hex digits, always hashed, so a value reads
  the same in the config as in a design tool. Alpha is authored as a fraction
  because the fraction is what the Apple table states; the Kotlin table
  carries `0xAARRGGBB`, where `AA` is the fraction times 255 rounded half away
  from zero — the rule Android's own float-to-byte conversion uses.
- **`value:` and `light:`/`dark:` are alternatives.** `value:` takes `alpha:`;
  the two-appearance form takes `lightAlpha:` / `darkAlpha:`.
- **`swift: { textStyle: … }` is required on every font token whenever a
  `swift:` target is declared** — the Apple side has no default that is right,
  and the generated switch is exhaustive.
- **A gradient takes `stops:` or both `light:` and `dark:`**, the same
  alternative the colours take — a colour's `light:`/`dark:` is one value each,
  a gradient's is one stop list each. Each list carries two or more `#RRGGBB`
  stops and no alpha — a gradient's transparency belongs to the surface it is
  painted on. Both languages get the values: Swift a `GradientSet`, Kotlin a
  `GradientToken`, each carrying the stops per appearance. Direction is not a
  token column — a stop list is the whole value, and the surface picks the
  axis (`LinearGradient(gradient:startPoint:endPoint:)` on Apple, a `Brush`
  factory under Compose).
- **`family:` is one of `serif`, `sans`, `mono`** — the three the engine's
  family token names. The app's resolver maps them to faces.
- **Prose is authored as a folded scalar** (`doc: >-` / `note: >-`). The
  generator re-wraps it to the generated file's column, and a blank line in
  the config stays a paragraph break in the comment.
- **Groups are optional and shared.** A `group:` heading is emitted into both
  the vocabulary and the value file, in both languages, so the two trees'
  grouping is one decision.
- **Token names are lowerCamelCase letters and digits.** The name becomes an
  enum case in both languages, and one spelling per token makes a token grep
  once instead of twice.
- **A token name is declared once per vocabulary.**
- **Unknown keys are an error**, at every position, named against the token
  they sit on.
- **`version:` must be the schema this toolchain reads.** A config from a
  newer schema is refused by name rather than half-read.

## The check

`duet design-tokens --check` regenerates every file in memory and compares.
The generator is compiled into the binary and a run costs milliseconds, so
there is no fingerprint block to amortize a slow regeneration and no input
list to keep accurate: the comparison is the whole file, which makes a
hand-edit anywhere in a generated file red.

Two failure shapes, both named with the path:

- **stale** — the file on disk differs from what the config generates. Either
  the config changed and the generator has not run, or the file was
  hand-edited.
- **orphaned** — a file one of the targets owns that the config no longer
  declares, left behind by dropping a vocabulary. It still compiles, so the
  check reports it rather than leaving it to be noticed.

A repo with no `parity/design-tokens.yaml` generates nothing and passes.

## The authoring loop

```sh
$EDITOR parity/design-tokens.yaml
tools/duet design-tokens          # regenerate
git add -A && git commit          # generated sources are committed build products
```

The generated files carry a `GENERATED by` banner and are reviewed like any
other diff: a value change shows up as the value.
