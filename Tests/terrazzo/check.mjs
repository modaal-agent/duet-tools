// Development-only cross-check: Terrazzo's parser, an independent
// implementation of the DTCG 2025.10 Resolver Module, resolves the version-2
// test fixture (Resources/tokens/dtcg) in both appearances, and every colour,
// gradient and type token must equal the golden manifest the generator is
// pinned to (Resources/tokens/expected/tokens.json).
//
//   cd Tests/terrazzo && npm install && npm run check
//
// Exits 1 on any mismatch. Not part of `swift test`: it needs Node.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parse, defineConfig, Logger } from "@terrazzo/parser";

const here = path.dirname(fileURLToPath(import.meta.url));
const resources = path.join(here, "../DuetCLITests/Resources/tokens");
const resolverFile = path.join(resources, "dtcg/design-tokens.resolver.json");
const manifest = JSON.parse(fs.readFileSync(path.join(resources, "expected/tokens.json"), "utf8"));

const config = defineConfig(
  { tokens: [pathToFileURL(resolverFile).href], lint: { rules: {} } },
  { cwd: pathToFileURL(path.dirname(resolverFile) + "/") },
);
const { resolver } = await parse(
  [{ filename: pathToFileURL(resolverFile), src: fs.readFileSync(resolverFile, "utf8") }],
  { config, logger: new Logger({ level: "error" }), skipLint: true },
);
const appearances = { light: resolver.apply({ appearance: "light" }), dark: resolver.apply({ appearance: "dark" }) };

const round = (value, places) => Math.round(value * 10 ** places) / 10 ** places;
/** The CSS form the manifest uses: #RRGGBB, or rgba() below full alpha. */
function css(value) {
  const bytes = value.components.map((c) => Math.round(c * 255));
  const alpha = value.alpha ?? 1;
  if (alpha >= 1) return "#" + bytes.map((b) => b.toString(16).padStart(2, "0").toUpperCase()).join("");
  return `rgba(${bytes.join(", ")}, ${alpha})`;
}
function find(tokens, type, name) {
  const hits = Object.entries(tokens).filter(([id, t]) => t.$type === type && id.split(".").at(-1) === name);
  if (hits.length !== 1) throw new Error(`${type} ${name}: ${hits.length} tokens`);
  return hits[0][1].$value;
}

const mismatches = [];
const expect = (what, actual, wanted) => {
  if (JSON.stringify(actual) !== JSON.stringify(wanted)) mismatches.push(`${what}: ${JSON.stringify(actual)} != ${JSON.stringify(wanted)}`);
};
let checked = 0;
for (const [appearance, tokens] of Object.entries(appearances)) {
  for (const color of manifest.colors) {
    expect(`${appearance} ${color.name}`, css(find(tokens, "color", color.name)), color[appearance]);
    checked++;
  }
  for (const gradient of manifest.gradients) {
    expect(`${appearance} ${gradient.name}`, find(tokens, "gradient", gradient.name).map((stop) => css(stop.color)), gradient[appearance]);
    checked++;
  }
  for (const font of manifest.fonts) {
    const value = find(tokens, "typography", font.name);
    const size = value.fontSize.value;
    expect(`${appearance} ${font.name}`, {
      weight: value.fontWeight,
      size,
      lineHeight: round(size * value.lineHeight, 2),
      tracking: round(value.letterSpacing.value / size, 6),
    }, { weight: font.weight, size: font.size, lineHeight: font.lineHeight, tracking: font.tracking });
    checked++;
  }
}
for (const line of mismatches) console.log("MISMATCH", line);
console.log(`terrazzo: ${checked} token values checked across both appearances, ${mismatches.length} mismatches`);
process.exit(mismatches.length ? 1 : 0);
