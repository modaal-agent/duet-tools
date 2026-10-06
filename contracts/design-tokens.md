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
| length scales (vocabulary and values in one file) | `SemanticSpacing.swift`, `SemanticRadius.swift` | `SemanticSpacing.kt`, `SemanticRadius.kt` | `--spacing-<name>` and `--radius-<name>` in `tokens.css`; `spacing` and `radii` in `tokens.json` |

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

A repo with spacing or corner-radius tokens adds a token file for them to the
`styles` set's sources (`parity/design-tokens/dimension.tokens.json`, holding
the `spacing` and `radius` groups): a length has one value in both
appearances.

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
| `dimension` | under the top-level `spacing` or `radius` group: `{value, unit: "px"}`, 0 or more, the same in both appearances; no other type is allowed there (R4). A dimension in any other group is skipped with a notice naming the group, and scale tokens may alias it |
| any other type | outside `spacing` and `radius`: counted and skipped with a notice naming the group, because no target has a vocabulary for it |

- **Values per appearance.** Each token is resolved in both appearances. A
  colour or gradient whose two values are equal is generated as one value,
  whichever files hold them; the generated code depends on the resolved values
  only. Aliases (`{color.Labels.labelPrimary}`) resolve within each
  appearance, so a gradient stop that names a colour token follows it.
- **Type metrics.** A typography token's line height is read back as
  `round(size × lineHeight, 2)` points and its tracking as
  `round(letterSpacing / size, 6)` em: the format allows `px` and `rem` for a
  dimension, and the generated tables carry points and em. A line height
  under the face's own is written at the face's ("Line heights" below).
- **Names.** A token's key is its case name in every language and, in kebab
  case, its CSS name; it follows R1–R3 below. The group between the
  top-level group and the token (`color.Labels.labelPrimary`) is its
  heading, emitted as a section comment, and is not part of the name.
  `$description` is the case's doc comment.
- **Extensions.** `$extensions["dev.modaal.duet"]` carries what the format
  has no field for, and an unknown key in it is refused. Other namespaces
  (a design tool's own) are kept and ignored.

  | on | key | meaning |
  | --- | --- | --- |
  | `typography` | `textStyle` | the `UIFont.TextStyle` the cut scales against; required when a `swift:` target is declared |
  | `typography` | `axes` | `{opticalSize?, softness?, width?}`: the `opsz`, `SOFT` and `wdth` axes |
  | `typography`, `color`, `gradient`, `dimension` | `note` | the value's comment in the generated tables |
  | `fontFamily` | `files` | `[{path, weight}]`: the family's font files, `path` relative to the repository root, `weight` a number or a variable face's `[min, max]`; the web target copies and declares them |
  | any token | `source` | a non-empty string naming the design tool and the name the token has there (`"Figma: Labels/Primary"`); `tokens.json` copies it into the token's entry, and no code target reads it. A tool that edits the tokens from a design finds a token by it after the design changes |

- **Length scales.** The `spacing` tokens generate `SemanticSpacing` and the
  `radius` tokens `SemanticRadius`, each only when the config declares one:
  a Swift `public enum` of `public static let <key>: CGFloat` constants in
  points, and a Kotlin `object` of `const val <key>: Float` constants in dp
  (`SemanticSpacing.m.dp` in Compose). The value sits beside the name, because
  a length needs no engine type and no appearance. A key is a constant's name
  in both languages, so it follows R1–R3 (`xs`, `screen`, `s4`).
- **Families.** The families are the `fontFamily` tokens, in declaration
  order. The Swift target generates `FontFamilyToken` with one case per
  family. The Kotlin target names the engine's own `FontFamilyToken.Serif`,
  `.Sans` and `.Mono` when the families are exactly those three keys
  (`serif`, `sans`, `mono`); a config that declares any other family gets
  `enum class SemanticFontFamily : FontFamilyToken` with one entry per family
  (`display` → `Display`), and the palette names its entries. That enum needs
  a theming engine whose `FontFamilyToken` is an interface; the app's
  resolver switches over `SemanticFontFamily`. Adding or removing a family
  changes what the app's own resolvers must map (R7): a run that changes the
  generated families prints each one and the change it needs, and `--json`
  lists the same lines under `notices`.

## Line heights

Every target lays a text style out the way design tools and CSS do: each
line is the style's line height tall, with the face centred in it. The web
target writes `line-height`; the apps' hand-authored theming code draws the
same box:

- SwiftUI: leading of `lineHeight − faceHeight` between lines, and half of it
  as padding above the first line and below the last;
- UIKit: a paragraph style whose minimum and maximum line height are the line
  height, and a baseline offset of half the difference;
- Compose: the line height with `LineHeightStyle(Alignment.Center, Trim.None)`.

`faceHeight` is the face's own line height at the style's size: the font's
`hhea` ascender − descender + line gap over its units per em, which is
`UIFont.lineHeight` on Apple and the line Android lays out. No platform draws
a line shorter than its face: Compose grows such a line back to the face's
height. So the generator writes `max(lineHeight, faceHeight)`, rounded up to
0.01, as the style's line height in every target and in `tokens.json`, and the
run names each style it raised with both values (`--json`: `notices`). The
source keeps its value. The face it measures:

- **A family with `files`:** the file for the style's weight (the variable
  file whose range holds it, else the file of the nearest weight), read from
  its `head` and `hhea` tables. A WOFF, WOFF2 or collection file is not read.
- **A family whose stack starts with a system name** (`-apple-system`,
  `system-ui`, `BlinkMacSystemFont`, `SF Pro …`, `ui-sans-serif`, `ui-serif`,
  `ui-monospace`, `ui-rounded`, `New York`, `SF Mono`, `sans-serif`, `serif`,
  `monospace`), and the version-1 families: 1.1934 em, the line height of
  Apple's system faces at every size and weight. Android's system faces for
  `sans-serif`, `serif` and `monospace` (Roboto, Noto Serif, Droid Sans Mono)
  are 1.1719 em, under it.
- **Any other first face:** none. Its styles are written as declared, and the
  run names the family.

## Rules a token follows

The token files are what an author or a tool edits; the rules below say what
generates code that compiles, and the generator refuses every token that
breaks one. A refusal names the token's file, its type and path, the rule and
a fix:

```
parity/design-tokens/color.light.tokens.json: color 'color.Labels.on-light': R1 — a key is ASCII letters and digits in lowerCamelCase, starting with a lowercase letter, because it names a case or a constant in Swift and Kotlin; rename it 'onLight'
```

Every refusal in the sources is reported in one run, grouped by file in
document order, and nothing is generated while one stands. A file that is
not a token document (not JSON, a token without `$type`, an unknown `$` key)
stops the run at its first error.

| Rule | A token… |
| --- | --- |
| **R1** | has a key of ASCII letters and digits in lowerCamelCase, starting with a lowercase letter (`labelPrimary`, `s16`, `xl2`). The refusal gives the key's lowerCamelCase form (`on-light` → `onLight`); a key that starts with a digit gets the scale's letter (`spacing.4` → `s4`, `radius.2xl` → `r2xl`) or its group's word (`color.Accent.300` → `accent300`) in front. |
| **R2** | has a key that is not a reserved name (below). The refusal suggests the key behind its group's word (`radius.default` → `radiusDefault`). |
| **R3** | has a key no other token of its vocabulary has: the colours, the text styles, the gradients, the families, `spacing` and `radius` each name one enum or object, and groups are not part of the name. The refusal names both tokens. A key may repeat across vocabularies. |
| **R4** | under the top-level `spacing` or `radius` group is a `dimension` in `px`, 0 or more, with one value in both appearances. A token of another type there is refused with the dimension to write. |
| **R5** | that is a colour, or a gradient stop, is sRGB as the value table says, and has a value in both appearances; a gradient's stops sit at even positions and are opaque. |
| **R6** | that is a text style references a family token and has a weight, a size in `px`, a line height as a multiple and a letter spacing in `px`, and a `textStyle` when a `swift:` target is declared. |
| **R7** | that is a family has a stack, and `files` only with the face's own name first. A family beyond `serif`, `sans` and `mono` is mapped by the app's font resolvers before the app builds, and draws the system face until its `files` are registered. |
| **R8** | carries in `$extensions["dev.modaal.duet"]` only the keys the extension table lists for its type, and `source` as a non-empty string. |

**Reserved names (R2).** The keys that do not compile as a generated name:
the Swift and Kotlin keywords that cannot name an enum case, a static
constant or a `const val`, and the members of Kotlin's `Enum` an entry cannot
shadow. The list was measured by compiling each candidate in the generated
shapes (an enum case, a static constant, a `switch` or `when` arm, a member
reference) with Swift for iOS and with Kotlin/JVM; contextual keywords that
compiled there (`none`, `get`, `set`, `open`, `value`, `data`) are allowed.

```
as associatedtype break case catch class constructor continue default defer
deinit do else entries enum extension fallthrough false fileprivate for fun
func guard if import in init inout interface internal is let name nil null
object operator ordinal package precedencegroup private protocol public repeat
rethrows return self static struct subscript super switch this throw throws
true try typealias typeof val var when where while
```

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
  stack; one custom property per spacing step (`--spacing-screen: 16px`) and
  per corner radius (`--radius-card: 12px`) on `:root`; and an `@font-face`
  rule per font file, under the first name in its family's stack.
- **`tokens.json`.** Every token with its CSS name, its light and dark values
  as CSS colours, its metrics, its group and its prose, and each family's
  stack; `spacing` and `radii` list the length scales with their `px` values,
  and are absent when the config declares none. A tool lists the tokens from
  this file, never from the token files or the stylesheet.
- **`fonts/`.** A copy of each file a family's `files` names.

A gradient's stop list is the whole value and the page picks the axis, as in
`linear-gradient(180deg, var(--gradient-surface-hero))`. Names follow one
rule, so a page and the app name a token alike: the token key in kebab case
after `--color-`, `--gradient-`, `font-`, `--font-family-`, `--spacing-` or
`--radius-`.

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
