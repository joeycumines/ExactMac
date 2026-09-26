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
  const script = `const TOKENS = ${TOKENS};\n${lib}\n${widgets}\n${draw}`;
  const out = execFileSync(
    "openpencil",
    ["eval", FIG, "--stdin", "-w"],
    { input: script, encoding: "utf8", maxBuffer: 32 * 1024 * 1024 },
  );
  const m = out.match(/__RESULT__(\{.*\})/);
  const suffix = missing.length ? ` (pending: ${missing.join(", ")})` : "";
  console.log(`${name}: ${m ? m[1] : out.trim().split("\n").pop()}${suffix}`);
}

const wanted = process.argv.slice(2);
const targets = wanted.length ? wanted : Object.keys(PAGES);
for (const t of targets) render(t);
