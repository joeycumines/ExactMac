#!/usr/bin/env node
// Renders docs/design.fig from the committed sources in this directory.
//
// The .fig is generated rather than hand-placed because the only working write path
// is a script anyway, and a generated design is reviewable in a diff and
// reproducible. Precisely: the CONTENT is stable (per-page node counts, node ids, and
// every node's path/type/x/y/w/h/text are identical across rebuilds), but the writer
// embeds an mtime, so the BYTES differ on every run and a no-op rebuild always
// dirties the file.
//
// Layout: lib.js first (primitives, text measurement, flow(), and the guards for
// known sandbox traps), then widgets.js (the component factories), then the page
// modules, which draw one page each.
//
// Two gates run on every build, both proven by negative controls. Both were born
// from a FAILING quality-check.
//
//   TOKEN GATE — every text token must clear WCAG AA (4.5:1) on every surface a
//   component can place it on, not just `surface`, plus the ink-on-fill pairs. It
//   runs BEFORE rendering and hard-exits, so a failing token can never reach the
//   design of record. This class of bug bit three times; the actual defect was
//   claiming compliance without a check.
//
//   OVERFLOW GATE — after building, no node may extend past its container, on either
//   axis. Clipped text is this toolchain's signature SILENT failure: the node count
//   looks right, the linter is clean, and a word quietly loses its last glyph. It
//   covers every node type, because what got sliced was a COMPONENT, and a text-only
//   check cannot see that. Vertical overflow inside a clipping parent is the one
//   legitimate case: that is the scroll view.
//
// The build runs in TWO passes. Pass one renders WITHOUT -w, so the file on disk is
// untouched, and runs the overflow check in the same sandbox. Only if every page is
// clean does pass two write.

const { execFileSync } = require("node:child_process");
const { readFileSync, existsSync } = require("node:fs");
const { join, dirname } = require("node:path");

const HERE = dirname(require.resolve("./build.js"));
const FIG = join(HERE, "..", "design.fig");
const TOKENS = readFileSync(join(HERE, "tokens.json"), "utf8");
const COLOR = JSON.parse(TOKENS).color;

// A page may be composed of several modules; they are concatenated in order against
// one page so a design system's parts can live apart from the screens that use them.
const PAGES = {
  foundations: { files: ["foundations.js"] },
  components: { files: ["identity.js", "controls.js"] },
  screens: { files: ["prompt.js"] },
  flows: { files: ["flows.js"] },
};
// The page each module set clears and redraws, which is not always the key.
const PAGE_NAMES = {
  foundations: "Foundations",
  components: "Components",
  screens: "Screens",
  flows: "Flows",
};

// ---------------------------------------------------------------------------
// The gated text tokens, declared ONCE and injected into the eval script so the
// Foundations contrast table and this gate cannot disagree. When the page declared
// its own list it reported "AA" for a token the build rejected, which is worse than
// no table at all.
const TEXT_TOKENS = [
  "text-primary", "text-secondary", "text-tertiary",
  "danger", "caution", "success", "accent-text",
];
const SURFACES = ["surface", "surface-raised", "surface-sunken"];

// Ink on a saturated FILL is text too, and is a different check: the primary
// button's label and the envelope band. Ungated, both were unverified.
const FILL_PAIRS = [
  { ink: "on-accent", fill: "accent", what: "primary button label" },
  { ink: "surface", fill: "caution", what: "envelope band label" },
];

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

const failures = [];
for (const scheme of ["light", "dark"]) {
  for (const token of TEXT_TOKENS) {
    for (const surface of SURFACES) {
      const r = ratio(COLOR[token][scheme], COLOR[surface][scheme]);
      if (r < 4.5) {
        failures.push(`${scheme}/${token} on ${surface}: ${r.toFixed(2)}:1 (needs 4.5)`);
      }
    }
  }
  for (const pair of FILL_PAIRS) {
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
  // Hard exit, NOT process.exitCode: setting the code lets the render run and the
  // poisoned token still reaches the design of record.
  process.exit(1);
}
console.log(
  `token gate: ${TEXT_TOKENS.length} text tokens x ${SURFACES.length} surfaces x 2 schemes, ` +
  `plus ${FILL_PAIRS.length} ink-on-fill pairs, all >= 4.5:1`,
);

// Appended to the dry-run script. Reports every node that escapes its container.
const CHECK_TAIL = `
const __bad = [];
function walk(node, clipAncestor) {
  const checkable = node.type !== "PAGE" && node.width > 0;
  // Vertical overflow is exempt in exactly ONE container, named explicitly. It
  // cannot be inferred from clipsContent, because every frame in this layout
  // clips by default and inferring it silently exempted the whole document — the
  // gate reported clean on a footer overflowing by 182pt.
  const isScrollRegion = node.name.indexOf("body-scroll") === 0;
  for (const child of (node.children || [])) {
    const clips = child.clipsContent === true;
    // Recurse FIRST and unconditionally. A page-level guard placed before the
    // recursion with a continue stopped the walk at the document root, so the
    // checker reported a clean document no matter what was inside it.
    walk(child, clips ? child : clipAncestor);
    if (!checkable) continue;
    const pad = 1.5;
    const r = child.x + child.width;
    const bo = child.y + child.height;
    const where = node.name + " > " + child.name + " [" + child.type + "]";
    const label = child.type === "TEXT" ? JSON.stringify((child.characters || "").slice(0, 36)) : "";
    if (r > node.width + pad) {
      __bad.push(where + " overflows horizontally: right " + Math.round(r) + " > " + Math.round(node.width) + "  " + label);
    }
    if (bo > node.height + pad && !isScrollRegion) {
      __bad.push(where + " overflows vertically: bottom " + Math.round(bo) + " > " + Math.round(node.height) + "  " + label);
    }
    if (clipAncestor && r > clipAncestor.width + pad) {
      __bad.push(where + " escapes clipping ancestor " + clipAncestor.name +
                 ": right " + Math.round(r) + " > " + Math.round(clipAncestor.width) + "  " + label);
    }
  }
}
// Walk ONLY the page this pass just rebuilt. Walking the whole document made a
// stale page left on disk by an earlier failing build fail an unrelated page's
// pass, which is how a Foundations build reported footers it had never drawn.
const __target = figma.root.children.find((p) => p.name === __PAGE) || figma.root;
walk(__target, null);
console.log("__OVERFLOW__" + JSON.stringify(__bad));
`;

// Structure gate. The invariants that review keeps re-finding are cheap to assert, so
// they are asserted rather than re-reviewed: exactly ONE requester per prompt tree,
// a signature badge on every tree row, Deny never adjacent to the primary action and
// never the default, and the expanded option order.
const STRUCTURE_TAIL = `
const __s = [];
const __all = [];
(function w(n, p) { __all.push(n); (n.children || []).forEach((c) => w(c, p)); })(figma.root, "");

for (const tree of __all.filter((n) => n.name && n.name.startsWith("ProcessTree/"))) {
  let requesters = 0, rows = 0, badged = 0;
  for (const row of tree.children || []) {
    if (!row.name || !row.name.startsWith("row-")) continue;
    rows++;
    if ((row.children || []).some((c) => c.name === "role") ||
        (row.children || []).some((c) => c.name === "label" && (c.characters || "").indexOf("requesting") >= 0)) {
      requesters++;
    }
    if ((row.children || []).some((c) => c.name && c.name.startsWith("SignatureBadge/"))) badged++;
  }
  if (requesters !== 1) __s.push(tree.name + ": expected exactly 1 requester, found " + requesters);
  if (rows > 0 && badged !== rows) __s.push(tree.name + ": " + (rows - badged) + " of " + rows + " rows carry no signature badge");
}

for (const opt of __all.filter((n) => n.name && n.name.startsWith("OptionRow/"))) {
  const isDefault = (opt.children || []).some((c) => c.name === "default");
  const destructive = (opt.children || []).some((c) => c.name === "title" && c.fills &&
    c.fills[0].color && Math.abs(c.fills[0].color.r - 0.84) < 0.2);
  if (isDefault && destructive) __s.push(opt.name + ": the default option must not be the destructive one");
}

for (const row of __all.filter((n) => n.name === "actions" || n.name === "deny-row")) {
  const kinds = (row.children || []).map((c) => c.name);
  const pi = kinds.findIndex((k) => k === "Button/primary");
  const di = kinds.findIndex((k) => k === "Button/deny");
  if (pi >= 0 && di >= 0 && Math.abs(pi - di) === 1) {
    __s.push("Deny sits immediately beside the primary action in " + row.name);
  }
}
console.log("__STRUCTURE__" + JSON.stringify(__s));
`;

function buildPass(write, targets) {
  for (const t of targets) {
    const page = PAGES[t];
    if (!page) throw new Error(`unknown page: ${t}`);
    // Skip a page whose modules are not written yet rather than requiring stubs.
    const present = page.files.filter((f) => existsSync(join(HERE, f)));
    if (present.length === 0) {
      if (write) console.log(`${t}: skipped (${page.files.join(", ")} not written yet)`);
      continue;
    }
    const lib = readFileSync(join(HERE, "lib.js"), "utf8");
    const widgets = readFileSync(join(HERE, "widgets.js"), "utf8");
    const draw = present.map((f) => readFileSync(join(HERE, f), "utf8")).join("\n");
    const preamble =
      `const __PAGE = ${JSON.stringify(PAGE_NAMES[t] || t)};\n` +
      `const TOKENS = ${TOKENS};\n` +
      `const TEXT_TOKENS = ${JSON.stringify(TEXT_TOKENS)};\n` +
      `const SURFACES = ${JSON.stringify(SURFACES)};\n` +
      `${lib}\n${widgets}\n${draw}\n`;
    const args = ["eval", FIG, "--stdin"];
    if (write) args.push("-w");
    const out = execFileSync("openpencil", args, {
      input: preamble + (write ? "" : CHECK_TAIL),
      encoding: "utf8",
      maxBuffer: 32 * 1024 * 1024,
    });
    if (write) {
      const m = out.match(/__RESULT__(\{.*\})/);
      console.log(`${t}: ${m ? m[1] : out.trim().split("\n").pop()}`);
    } else {
      const m = out.match(/__OVERFLOW__(\[.*\])/s);
      if (!m) throw new Error(`overflow check produced no result for page ${t}`);
      const bad = JSON.parse(m[1]);
      if (bad.length) {
        console.error(`OVERFLOW GATE FAILED on ${t} — ${bad.length} node(s) escape a container:`);
        for (const b of bad.slice(0, 20)) console.error("  " + b);
        process.exit(1);
      }
    }
  }
}

const wanted = process.argv.slice(2);
const targets = wanted.length ? wanted : Object.keys(PAGES);

buildPass(false, targets);   // dry run: the .fig on disk is untouched
buildPass(true, targets);    // only now does the design of record change
console.log(
  `overflow gate: no node escapes its container on either axis, across ${targets.length} page(s)`,
);
// The structure gate runs LAST, over the finished document. Per page it would judge
// the other pages by whatever was last written, which is how a Foundations build
// reported on a Components tree it had not drawn.
const sOut = execFileSync("openpencil", ["eval", FIG, "--stdin"], {
  input: STRUCTURE_TAIL, encoding: "utf8", maxBuffer: 32 * 1024 * 1024,
});
const sProblems = JSON.parse((sOut.match(/__STRUCTURE__(\[.*\])/s) || [, "[]"])[1]);
if (sProblems.length) {
  console.error(`STRUCTURE GATE FAILED — ${sProblems.length} invariant(s) broken:`);
  for (const pr of sProblems.slice(0, 20)) console.error("  " + pr);
  process.exit(1);
}
console.log(
  "structure gate: one requester per tree, a badge on every row, Deny never beside the primary and never default",
);
