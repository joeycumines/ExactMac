#!/usr/bin/env node
// Driver that renders docs/design/*.js into docs/design.fig.
//
// The drawing code runs inside the openpencil eval sandbox, which has no Node
// APIs, so this script reads the committed token source and the pure drawing
// module, concatenates them, and pipes the result to `openpencil eval -w`. The
// .fig is therefore generated from files in git rather than hand-placed, which
// makes it reviewable in a diff and reproducible after a token change.
//
//   node docs/design/build.js            # rebuild every page
//   node docs/design/build.js foundations
//
// Writing goes only to docs/design.fig, and only through the server.

const { execFileSync } = require("node:child_process");
const { readFileSync, existsSync } = require("node:fs");
const { join, dirname } = require("node:path");

const HERE = __dirname;                                   // docs/design/
const FIG = join(HERE, "..", "design.fig");               // docs/design.fig
const TOKENS = readFileSync(join(HERE, "tokens.json"), "utf8");
const COLOR = JSON.parse(TOKENS).color;

// A page may be composed of several modules; they are concatenated in order
// against one page so a design system's parts can live apart from the screens
// that use them.
const PAGES = {
  foundations: { files: ["foundations.js"], label: "Foundations" },
  components: { files: ["identity.js", "controls.js"], label: "Components" },
  screens: { files: ["prompt.js"], label: "Screens" },
  flows: { files: ["flows.js"], label: "Flows" },
};

function render(name) {
  const page = PAGES[name];
  if (!page) throw new Error(`unknown page: ${name}`);
  // Skip a page whose modules are not written yet rather than requiring stubs;
  // `node docs/design/build.js` therefore always builds what exists.
  const present = page.files.filter((f) => existsSync(join(HERE, f)));
  const missing = page.files.filter((f) => !existsSync(join(HERE, f)));
  if (present.length === 0) {
    console.log(`${name}: skipped (${page.files.join(", ")} not written yet)`);
    return;
  }
  // lib.js first: it holds the primitives and the sandbox guards, and depends on
  // TOKENS, which is injected ahead of both.
  const lib = readFileSync(join(HERE, "lib.js"), "utf8");
  const widgets = readFileSync(join(HERE, "widgets.js"), "utf8");
  const draw = present.map((f) => readFileSync(join(HERE, f), "utf8")).join("\n");
  const script = `const TOKENS = ${TOKENS};\nconst TEXT_TOKENS = ${JSON.stringify(TEXT_TOKENS)};\nconst SURFACES = ${JSON.stringify(SURFACES)};\n${lib}\n${widgets}\n${draw}`;
  const out = execFileSync(
    "openpencil",
    ["eval", FIG, "--stdin", "-w"],
    { input: script, encoding: "utf8", maxBuffer: 32 * 1024 * 1024 },
  );
  const m = out.match(/__RESULT__(\{.*\})/);
  const suffix = missing.length ? ` (pending: ${missing.join(", ")})` : "";
  console.log(`${name}: ${m ? m[1] : out.trim().split("\n").pop()}${suffix}`);
}

// ---------------------------------------------------------------------------
// Token gate. A text token must clear WCAG AA (4.5:1) on EVERY surface a component
// can place it on, not just `surface`. Two bugs of the same shape came from
// checking only one: Apple's stock tertiary measures 3.62:1 on white, and the
// replacement then measured 4.27:1 on surface-sunken. openpencil lint only
// catches a combination that happens to appear on a page, so a token can be wrong
// and the lint stay green until something uses it. This runs on every build.
const lum = (hex) => {
  const x = hex.replace("#", "");
  const ch = (i) => {
    const c = parseInt(x.slice(i, i + 2), 16) / 255;
    return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * ch(0) + 0.7152 * ch(2) + 0.0722 * ch(4);
};
const ratio = (a, b) => {
  const l1 = lum(a), l2 = lum(b);
  return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
};

// The gated text tokens, declared ONCE and injected into the eval script so the
// Foundations contrast table and this gate cannot disagree. When the page declared
// its own list it reported "AA" for a token the build rejected, which is worse than
// no table at all.
const TEXT_TOKENS = [
  "text-primary", "text-secondary", "text-tertiary",
  "danger", "caution", "success", "accent-text",
];
const SURFACES = ["surface", "surface-raised", "surface-sunken"];

// Ink sitting on a saturated FILL is text too, and is a different check: it is the
// primary button's label and the envelope band. Ungated, both were unverified.
const FILL_PAIRS = [
  { ink: "on-accent", fill: "accent",   what: "primary button label" },
  { ink: "surface",   fill: "caution",  what: "envelope band label" },
];
const failures = [];
for (const scheme of ["light", "dark"]) {
  for (const token of TEXT_TOKENS) {
    for (const surface of SURFACES) {
      const r = ratio(COLOR[token][scheme], COLOR[surface][scheme]);
      if (r < 4.5) {
        failures.push(
          `${scheme}/${token} on ${surface}: ${r.toFixed(2)}:1 (needs 4.5)`,
        );
      }
    }
  }
}
for (const pair of FILL_PAIRS) {
  for (const scheme of ["light", "dark"]) {
    const r = ratio(COLOR[pair.ink][scheme], COLOR[pair.fill][scheme]);
    if (r < 4.5) {
      failures.push(
        `${scheme}/${pair.ink} on ${pair.fill} (${pair.what}): ${r.toFixed(2)}:1 (needs 4.5)`,
      );
    }
  }
}

if (failures.length) {
  console.error("TOKEN GATE FAILED — text below WCAG AA:");
  for (const f of failures) console.error("  " + f);
  // Hard exit, NOT process.exitCode: setting the code lets the render loop run and
  // the poisoned token still reaches the design of record. The gate is only real if
  // the artifact cannot be written when it fails.
  process.exit(1);
} else {
  console.log(
    `token gate: ${TEXT_TOKENS.length} text tokens x ${SURFACES.length} surfaces x 2 schemes all >= 4.5:1`,
  );
}

const wanted = process.argv.slice(2);
const targets = wanted.length ? wanted : Object.keys(PAGES);
for (const t of targets) render(t);
