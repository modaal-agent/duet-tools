# The design-token config — sources and generated shape

`parity/design-tokens.yaml` declares a repo's design-token targets and where
the tokens come from. `duet design-tokens` generates the vocabulary enums and
the value tables in every language the config declares a target for, and the
web target's stylesheet and manifest; `duet design-tokens --check` fails while
a generated file disagrees with the source. This document is what that
generator accepts.

The config has two versions:

- **Version 2** names a resolver document in the W3C Design Tokens format
  (Design Tokens Community Group, 2025.10: the Format, Color and Resolver
  modules), and the tokens live in the token files the resolver names. Design
  tools and other token toolchains read and write the same files.
- **Version 1** carries the tokens itself, in the grammar below.
  `duet design-tokens migrate` rewrites a version-1 config as version 2.

Both are read with a real parser — Yams, which reads JSON as YAML 1.2's flow
style and keeps object keys in document order, which the generated
vocabularies follow. Strictness lives at the schema walk: every key is
checked against the known set for its position, and an unknown one is an
error naming the token it sits on, so a misspelled key cannot silently drop a
value.

## What is generated, and what is not

Generated — the layers that have a twin on every platform:

| layer | Swift | Kotlin | Web (`css:`) |
| --- | --- | --- | --- |
| vocabulary | `SemanticColor.swift`, `SemanticFont.swift`, `SemanticGradient.swift` | `SemanticColor.kt`, `SemanticFont.kt`, `SemanticGradient.kt`, and `SemanticFontFamily.kt` for a config that declares its own families | `tokens.json` |
| values | `<theme>Palette.swift` | `<palette>.kt` | `tokens.css`, and `fonts/` |

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

Cross-language name and value identity holds by construction: every target
is emitted from one input, in one declaration order.

## Version 2: the targets, and a DTCG source

```yaml
version: 2
tokens: design-tokens.resolver.json   # the resolver, relative to this file

swift:                       # the targets, as in version 1
  output: <dir>
  engine: DuetTheming
  theme: MainTheme

kotlin:
  output: <dir>
  package: com.example.theming
  engine: dev.modaal.duet.services.theming
  palette: MainPalette

css:
  output: <dir>              # where tokens.css, tokens.json and fonts/ go
```

The config holds the targets and comments; the resolver and the token files
are plain DTCG, valid against the format's published JSON schemas. The
layout `duet design-tokens migrate` writes, and the one the generator is
tested against:

```
parity/design-tokens.yaml                      the config above
parity/design-tokens.resolver.json             modifier "appearance" (light | dark, default light), set "styles"
parity/design-tokens/color.light.tokens.json   every colour, light appearance
parity/design-tokens/color.dark.tokens.json    every colour, dark appearance
parity/design-tokens/type.tokens.json          fontFamily and typography tokens
parity/design-tokens/gradient.tokens.json      gradients
```

One colour file per appearance, each holding every colour: a design tool that
imports one file per mode creates a variable only for a token present in
every file.

**The resolver.** Its `resolutionOrder` holds sets and one modifier,
`appearance`, whose contexts are exactly `light` (the default) and `dark`.
A source is a token group written inline, or `{"$ref": "<file>"}` relative to
the resolver; a JSON Pointer into a file is not read. Later sources win, a
token replacing the earlier token at its path whole. `version` must be
`"2025.10"`. A token defined only in the `dark` context is refused: every
token is declared for the light appearance first.

**What the generator reads** (anything else is refused by name):

| `$type` | value |
| --- | --- |
| `color` | `{colorSpace: "srgb", components: [r, g, b], alpha?, hex?}`, components 0…1, read to 8 bits; `hex`, when present, must agree with the components |
| `fontFamily` | a name or a list of names, the family's stack; its key names the family |
| `typography` | `fontFamily` an alias of a `fontFamily` token; `fontWeight` 1–1000 or a weight name; `fontSize` in `px`; `lineHeight` a number, the multiple of the size; `letterSpacing` in `px` |
| `gradient` | stops `{color, position}`, two or more, at even positions, opaque |
| any other type | counted and skipped with a notice: no target has a vocabulary for it |

- **Values per appearance.** Each token is resolved in both appearances. A
  colour or gradient whose two values are equal is generated as one value,
  whichever files hold them; the generated code depends on the resolved values
  only. Aliases (`{color.Labels.labelPrimary}`) resolve within each
  appearance, so a gradient stop that names a colour token follows it.
- **Type metrics.** A typography token's line height is read back as
  `round(size × lineHeight, 2)` points and its tracking as
  `round(letterSpacing / size, 6)` em: the format allows `px` and `rem` for a
  dimension, and the generated tables carry points and em.
- **Names.** A token's key is its case name in every language and, in kebab
  case, its CSS name. The group between the top-level group and the token
  (`color.Labels.labelPrimary`) is its heading, emitted as a section comment.
  `$description` is the case's doc comment.
- **Extensions.** `$extensions["dev.modaal.duet"]` carries what the format
  has no field for, and an unknown key in it is refused. Other namespaces
  (a design tool's own) are kept and ignored.

  | on | key | meaning |
  | --- | --- | --- |
  | `typography` | `textStyle` | the `UIFont.TextStyle` the cut scales against; required when a `swift:` target is declared |
  | `typography` | `axes` | `{opticalSize?, softness?, width?}`: the `opsz`, `SOFT` and `wdth` axes |
  | `typography`, `color`, `gradient` | `note` | the value's comment in the generated tables |
  | `fontFamily` | `files` | `[{path, weight}]`: the family's font files, `path` relative to the repository root, `weight` a number or a variable face's `[min, max]`; the web target copies and declares them |

- **Families.** The families are the `fontFamily` tokens, in declaration
  order. The Swift target generates `FontFamilyToken` with one case per
  family. The Kotlin target names the engine's own `FontFamilyToken.Serif`,
  `.Sans` and `.Mono` when the families are exactly those three keys
  (`serif`, `sans`, `mono`); a config that declares any other family gets
  `enum class SemanticFontFamily : FontFamilyToken` with one entry per family
  (`display` → `Display`), and the palette names its entries. That enum needs
  a theming engine whose `FontFamilyToken` is an interface; the app's
  resolver switches over `SemanticFontFamily`.

## Version 1: the tokens in the config

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

css:                         # optional; the web target
  output: <dir>
  families:                  # optional; a family's stack, by family
    serif: '"Source Serif 4", ui-serif, Georgia, serif'

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

- **At least one of `swift:`, `kotlin:` and `css:` is required.** A config
  with none generates nothing.
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
- **`version:` must be a schema this toolchain reads** (1 or 2). A config
  from a newer schema is refused by name rather than half-read.

## The web target

`css: {output: <dir>}` writes three things into `<dir>`, for web pages and
tools that show the app's tokens:

- **`tokens.css`.** One custom property per colour (`--color-label-primary`)
  and per gradient's stop list (`--gradient-surface-hero`), the light values on
  `:root` and the dark ones under `@media (prefers-color-scheme: dark)`; one
  class per type token (`.font-large-title`): family, weight, size and line
  height in `px`, `letter-spacing` in `em`, and `font-variation-settings` for
  the axes; `--font-family-<family>` per family, whose value is the family's
  stack; and an `@font-face` rule per font file, under the first name in its
  family's stack.
- **`tokens.json`.** Every token with its CSS name, its light and dark values
  as CSS colours, its metrics, its group and its prose, and each family's
  stack. A tool lists the tokens from this file, never from the token files
  or the stylesheet.
- **`fonts/`.** A copy of each file a family's `files` names.

A gradient's stop list is the whole value and the page picks the axis, as in
`linear-gradient(180deg, var(--gradient-surface-hero))`. Names follow one
rule, so a page and the app name a token alike: the token key in kebab case
after `--color-`, `--gradient-`, `font-` or `--font-family-`.

## `duet design-tokens migrate`

Rewrites a version-1 config as version 2: writes the resolver and the token
files of the layout above, and replaces the config with one that names the
resolver and keeps the targets (`css.families` becomes the `fontFamily`
tokens' stacks). The config's comments are not carried over.

- The engine's three families are declared in their order, so the generated
  Swift and Kotlin keep their cases.
- Colours are written to both colour files, a one-value colour with the same
  value in each. Components are written to four decimals with `hex` beside
  them; line height as a multiple of the size to six decimals; tracking as
  `px` at the token's size.
- A gradient goes to `gradient.tokens.json` with each stop naming the colour
  token it equals in both appearances, or a literal colour when it is the same
  in both. When a two-appearance gradient has a stop that no colour token
  matches, every gradient goes into the colour files instead, each with its
  appearance's own stops.
- It refuses a config that is already version 2, and a target file that
  exists.

`duet design-tokens` after it generates the same files as before, except the
line naming the source.

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
  check reports it rather than leaving it to be noticed. The web target owns
  every file in its `fonts/` directory.

A copied font file is compared byte for byte, like the generated text files.

A repo with no `parity/design-tokens.yaml` generates nothing and passes.

## The authoring loop

```sh
$EDITOR parity/design-tokens/color.light.tokens.json parity/design-tokens/color.dark.tokens.json
tools/duet design-tokens          # regenerate
git add -A && git commit          # generated sources are committed build products
```

A colour change is an edit in both colour files, one per appearance; a type
change is an edit in `type.tokens.json`. At version 1 the edit is in
`parity/design-tokens.yaml`.

The generated files carry a `GENERATED by` banner and are reviewed like any
other diff: a value change shows up as the value.
