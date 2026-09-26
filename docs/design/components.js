// Components page: the caller-identity family.
//
// B4's acceptance asks for components WITH INSTANCES demonstrating every variant.
// The sandbox exposes figma.createComponent and component.createInstance, so both
// are real nodes, but figma.combineAsVariants throws. A variant SET is therefore
// impossible here; each state is its own component named "Family/State", which is
// the same convention a variant set uses and keeps the states individually
// citable. Masters are laid out in a strip and the gallery below is built from
// real instances, so the instancing path is proven rather than asserted.
//
// Every container is positioned with lib.js flow(), because the sandbox stores
// layoutMode but never runs the layout engine; flow() sets both the explicit
// geometry and the auto-layout properties that reproduce it.
//
// The design problem these solve: the operator must see the calling process AND
// its intermediaries, and must be able to tell a signed caller from an unsigned
// one and an UNRESOLVED one from either. A UI that blurs those makes the
// graded-evidence model a lie, so "unresolved" gets its own wording and a
// non-status color, because unknown is not the same fact as bad.

const C = TOKENS.color;
const R = TOKENS.radius;

const ink = (scheme, name) => C[name][scheme];

// ---------------------------------------------------------------- SignatureBadge

// Ordered by how much the operator should worry. `unresolved` is last and
// deliberately neutral: it means the system could not find out, which is a
// different fact from "found out and it is bad".
const SIGNATURE_STATES = [
  { key: "signed",      label: "Signed",            tone: "success", w: 84 },
  { key: "unnotarized", label: "Unnotarized",       tone: "caution", w: 104 },
  { key: "adhoc",       label: "Ad-hoc signed",     tone: "caution", w: 116 },
  { key: "unsigned",    label: "Unsigned",          tone: "danger",  w: 90 },
  { key: "invalid",     label: "Invalid signature", tone: "danger",  w: 128 },
  { key: "unresolved",  label: "Unresolved",        tone: "neutral", w: 100 },
];

function signatureBadge(o) {
  const scheme = o.scheme || "light";
  const s = o.state;
  const tone = s.tone === "neutral" ? "text-secondary" : s.tone;
  const c = makeComponent(null, {
    name: "SignatureBadge/" + s.key,
    w: s.w, h: 20, fill: ink(scheme, "surface-raised"), radius: R["radius-pill"],
    stroke: ink(scheme, tone === "neutral" ? "control-border" : tone),
  });
  // A dot plus the word: color alone never carries the state, so the badge still
  // reads correctly in grayscale or for a colorblind operator.
  const dot = makeRect(c, { name: "dot", w: 6, h: 6, fill: ink(scheme, tone), radius: 3 });
  const label = makeText(c, {
    name: "label", chars: s.label, size: 11, style: "Semibold", color: ink(scheme, tone),
  });
  flow(c, [{ node: dot }, { node: label }], {
    direction: "HORIZONTAL", gap: 6, padLeft: 9, padRight: 9, padTop: 3, padBottom: 3,
    align: "CENTER", hugW: false, fixedW: s.w,
  });
  c.resize(s.w, 20);
  return { node: c, w: s.w, h: 20 };
}

// ------------------------------------------------------------------ IdentityRow

function identityRow(o) {
  const scheme = o.scheme || "light";
  const p = o.process;
  const row = makeComponent(null, {
    name: "IdentityRow/" + (p.role || "row"),
    w: o.w || 400, h: 52, fill: ink(scheme, "surface-raised"),
    radius: R["radius-md"], stroke: ink(scheme, "separator"),
  });

  // App glyph: initial on a sunken rounded square. The product uses the real
  // icon; the specimen proves the slot's size and contrast.
  const glyph = makeFrame(null, {
    name: "glyph", w: 26, h: 26, fill: ink(scheme, "surface-sunken"),
    radius: R["radius-sm"], stroke: ink(scheme, "separator"),
  });
  const initial = makeText(glyph, {
    name: "initial", chars: (p.name || "?").charAt(0).toUpperCase(),
    size: 12, style: "Semibold", color: ink(scheme, "text-primary"),
  });
  flow(glyph, [{ node: initial }], {
    direction: "HORIZONTAL", align: "CENTER", mainAlign: "CENTER",
    hugW: false, hugH: false, fixedW: 26, fixedH: 26,
  });
  glyph.resize(26, 26);

  const stack = makeFrame(null, {
    name: "stack", w: 210, h: 34, fill: ink(scheme, "surface-raised"),
  });
  const name = makeText(null, {
    name: "name", chars: p.name, size: 13,
    style: p.isRequester ? "Semibold" : "Regular",
    color: ink(scheme, "text-primary"),
  });
  const path = makeText(null, {
    name: "path", chars: p.path, size: 11, mono: true, wrap: 210,
    color: ink(scheme, "text-secondary"),
  });
  flow(stack, [{ node: name }, { node: path }], {
    direction: "VERTICAL", gap: 1, padLeft: 0, padRight: 0, padTop: 0, padBottom: 0,
    fixedW: 210,
  });

  const items = [{ node: glyph, w: 26, h: 26 }, { node: stack, w: 210, h: stack.height }];
  if (p.signature) {
    const b = signatureBadge({ state: p.signature, scheme });
    items.push(b);
  }
  flow(row, items, {
    direction: "HORIZONTAL", gap: 10, padLeft: 10, padRight: 10, padTop: 10, padBottom: 10,
    align: "CENTER", hugW: false, fixedW: o.w || 400,
  });
  row.resize(o.w || 400, 52);
  return { node: row, w: o.w || 400, h: 52 };
}

// ----------------------------------------------------------------- ProcessTree

// A host application, any intermediaries, and finally the requesting process.
// The requester is emphasised because it is the process whose identity lands in
// the grant, and an operator scanning the tree must land on it first.
function processRow(p, scheme, w) {
  const row = makeFrame(null, {
    name: "row-" + p.name, w: w, h: 30, fill: ink(scheme, "surface"),
  });
  const items = [];
  let padLeft = 8 + p.depth * 20;
  if (p.depth > 0) {
    // Drawn as a rule, not a box-drawing glyph: the design fonts carry no
    // └─ and a missing glyph rendered as a speck, which is worse than nothing.
    const guide = makeRect(row, {
      name: "guide", w: 1, h: 18, fill: ink(scheme, "separator"),
    });
    items.push({ node: guide, w: 1, h: 18 });
  }
  const marker = makeRect(row, {
    name: "marker", w: 3, h: 16,
    fill: p.isRequester ? ink(scheme, "accent") : ink(scheme, "separator"),
    radius: 1.5,
  });
  items.push({ node: marker, w: 3, h: 16 });
  const label = makeText(row, {
    name: "label",
    chars: p.name + "   pid " + p.pid + (p.detail ? "   " + p.detail : ""),
    size: 12, style: p.isRequester ? "Semibold" : "Regular",
    color: p.isRequester ? ink(scheme, "text-primary") : ink(scheme, "text-secondary"),
  });
  items.push({ node: label });
  if (p.isRequester) {
    const role = makeText(row, {
      name: "role", chars: "requesting", size: 11, style: "Semibold",
      color: ink(scheme, "accent"),
    });
    items.push({ node: role });
  }
  flow(row, items, {
    direction: "HORIZONTAL", gap: 8, padLeft: padLeft, padRight: 8, padTop: 6, padBottom: 6,
    align: "CENTER", hugW: false, fixedW: w,
  });
  row.resize(w, 30);
  return { node: row, w: w, h: 30 };
}

function processTree(o) {
  const scheme = o.scheme || "light";
  const w = o.w || 400;
  const tree = makeComponent(null, {
    name: "ProcessTree/" + (o.deep ? "deep" : "direct"),
    w: w, h: 40, fill: ink(scheme, "surface"),
  });
  const items = o.processes.map((p) => processRow(p, scheme, w));
  if (o.caption) {
    const cap = makeText(null, {
      name: "caption", chars: o.caption, size: 11, color: ink(scheme, "text-tertiary"),
    });
    items.push({ node: cap });
  }
  flow(tree, items, {
    direction: "VERTICAL", gap: 0, padLeft: 0, padRight: 0, padTop: 2, padBottom: 2,
    hugW: false, fixedW: w,
  });
  return { node: tree, w: w, h: tree.height };
}

// ---------------------------------------- UntrustedField and its SystemField twin

// The control against in-dialog label spoofing. Caller-supplied text is mono, on
// a sunken surface, behind a caution rule, under an explicit label. A
// system-derived fact of the same value looks nothing like it, which is the
// entire point: the two are drawn side by side below.
function untrustedField(o) {
  const scheme = o.scheme || "light";
  const w = o.w || 400;
  const f = makeComponent(null, {
    name: "UntrustedField/" + (o.variant || "default"),
    w: w, h: 56, fill: ink(scheme, "surface-sunken"),
    radius: R["radius-sm"], stroke: ink(scheme, "separator"),
  });
  const rule = makeRect(f, { name: "rule", w: 3, h: 40, fill: ink(scheme, "caution"), radius: 1.5 });
  const stack = makeFrame(null, { name: "stack", w: w - 40, h: 40, fill: ink(scheme, "surface-sunken") });
  const caption = makeText(null, {
    name: "caption", chars: o.caption || "FROM THE CALLER — NOT VERIFIED",
    size: 10, style: "Semibold", color: ink(scheme, "caution"),
  });
  const value = makeText(null, {
    name: "value", chars: o.value, size: 12, mono: true, wrap: w - 40,
    color: ink(scheme, "text-primary"),
  });
  flow(stack, [{ node: caption }, { node: value }], {
    direction: "VERTICAL", gap: 3, fixedW: w - 40,
  });
  flow(f, [{ node: rule, w: 3, h: 40 }, { node: stack, w: stack.width, h: stack.height }], {
    direction: "HORIZONTAL", gap: 10, padLeft: 0, padRight: 10, padTop: 8, padBottom: 8,
    align: "CENTER", hugW: false, fixedW: w,
  });
  return { node: f, w: w, h: f.height };
}

function systemField(o) {
  const scheme = o.scheme || "light";
  const w = o.w || 400;
  const f = makeComponent(null, {
    name: "SystemField/" + (o.variant || "default"),
    w: w, h: 44, fill: ink(scheme, "surface"),
  });
  const caption = makeText(null, {
    name: "caption", chars: o.caption, size: 10, style: "Semibold",
    color: ink(scheme, "text-tertiary"),
  });
  const value = makeText(null, {
    name: "value", chars: o.value, size: 12, mono: true, wrap: w - 13,
    color: ink(scheme, "text-primary"),
  });
  flow(f, [{ node: caption }, { node: value }], {
    direction: "VERTICAL", gap: 3, padLeft: 13, padRight: 10, padTop: 4, padBottom: 4,
    hugW: false, fixedW: w,
  });
  return { node: f, w: w, h: f.height };
}

// -------------------------------------------------------------------- the page

const DEEP_TREE = [
  { name: "Terminal", pid: 4211, depth: 0, detail: "host application" },
  { name: "zsh", pid: 4402, depth: 1, detail: "login shell" },
  { name: "node", pid: 4490, depth: 2, detail: "opencode" },
  { name: "exactmac-mcp", pid: 4517, depth: 3, detail: "MCP client", isRequester: true },
];

const DIRECT_TREE = [
  { name: "Codex", pid: 8823, depth: 0, detail: "agent host", isRequester: true },
];

function buildComponents() {
  const page = figma.root.children.find((p) => p.name === "Components");
  if (!page) throw new Error("Components page not found");
  while (page.children.length > 0) page.children[0].remove();

  const W = TOKENS.layout.specimenWidth;
  const M = 64;
  const L = "light";
  const root = makeFrame(page, { name: "components", x: 0, y: 0, w: W, h: 400, fill: C.surface[L] });
  let y = M;

  // The page sheet is an explicit grid, like Foundations: it is a document, not a
  // component. Everything it contains is laid out with flow().
  const text = (name, chars, size, color, x, yy, style) => {
    const t = makeText(root, { name, chars, size, style: style || "Regular", color, x, y: yy });
    return t.height;
  };
  const heading = (chars) => { y += text("cmp/h", chars, 15, ink(L, "text-primary"), M, y, "Semibold") + 10; };
  const note = (chars) => {
    const t = makeText(root, { name: "cmp/note", chars, size: 11, color: ink(L, "text-tertiary"), x: M, y, wrap: W - M * 2 });
    y += t.height + 18;
  };

  y += text("cmp/title", "Components", 22, ink(L, "text-primary"), M, y, "Semibold") + 12;
  y += text("cmp/subtitle",
    "Caller identity. Every state is its own component; the gallery is real instances.",
    13, ink(L, "text-secondary"), M, y) + 34;

  // ---- SignatureBadge: all six masters, then one real instance of each
  heading("SignatureBadge");
  note("Unsigned, invalid and unresolved must never look alike. Unresolved is neutral on purpose: not knowing is a different fact from knowing it is bad.");

  const sigStrip = makeFrame(root, { name: "cmp/sig-states", x: M, y, w: W - M * 2, h: 24, fill: C.surface[L] });
  const sigItems = SIGNATURE_STATES.map((s) => {
    return signatureBadge({ state: s, scheme: L });
  });
  flow(sigStrip, sigItems, { direction: "HORIZONTAL", gap: 12, padLeft: 0, padRight: 0, padTop: 0, padBottom: 0, hugW: false, fixedW: W - M * 2 });
  y += sigStrip.height + 14;

  const sigGallery = makeFrame(root, { name: "cmp/sig-instances", x: M, y, w: W - M * 2, h: 24, fill: C.surface[L] });
  const instItems = sigItems.map((it) => {
    const inst = it.node.createInstance();
    inst.name = "instance-" + it.node.name;
    return { node: inst, w: it.w, h: it.h };
  });
  flow(sigGallery, instItems, { direction: "HORIZONTAL", gap: 12, hugW: false, fixedW: W - M * 2 });
  y += sigGallery.height + 40;

  // ---- IdentityRow
  heading("IdentityRow");
  note("One row per process in the tree. The requester is semibold because that is the identity written into the grant.");
  const idRow = makeFrame(root, { name: "cmp/identityrow", x: M, y, w: 520, h: 56, fill: C.surface[L] });
  const idItems = [
    identityRow({ scheme: L, process: { name: "exactmac-mcp", path: "/opt/homebrew/bin/exactmac-mcp", role: "requester", isRequester: true, signature: SIGNATURE_STATES[0] } }),
    identityRow({ scheme: L, process: { name: "Claude", path: "/Applications/Claude.app/Contents/MacOS/Claude", role: "signed", signature: SIGNATURE_STATES[1] } }),
    identityRow({ scheme: L, process: { name: "helper", path: "/private/tmp/worker", role: "unsigned", signature: SIGNATURE_STATES[3] } }),
    identityRow({ scheme: L, process: { name: "unknown", path: "— could not resolve —", role: "unresolved", signature: SIGNATURE_STATES[5] } }),
  ];
  flow(idRow, idItems, { direction: "VERTICAL", gap: 10, hugW: false, fixedW: 520 });
  y += idRow.height + 40;

  // ---- ProcessTree: deep and degenerate
  heading("ProcessTree");
  note("The requester carries the accent rule and semibold weight. The degenerate single-process case is drawn because it is the common one and must not look broken.");
  const treeCol = makeFrame(root, { name: "cmp/trees", x: M, y, w: W - M * 2, h: 180, fill: C.surface[L] });
  const treeItems = [
    processTree({ scheme: L, deep: true, processes: DEEP_TREE, w: 500 }),
    processTree({ scheme: L, deep: false, processes: DIRECT_TREE, w: 500, caption: "Direct request — no intermediary process." }),
  ];
  flow(treeCol, treeItems, { direction: "HORIZONTAL", gap: 32, hugW: false, fixedW: W - M * 2 });
  y += treeCol.height + 40;

  // ---- UntrustedField beside SystemField: the pair that proves the distinction
  heading("UntrustedField");
  note("Same value, two treatments. The caller's text is mono on a sunken surface behind a caution rule under an explicit label; a system-derived fact of identical content is plain on the surface. If these ever look alike, in-dialog label spoofing works.");
  const pair = makeFrame(root, { name: "cmp/field-pair", x: M, y, w: W - M * 2, h: 80, fill: C.surface[L] });
  const pairItems = [
    untrustedField({ scheme: L, w: 400, caption: "FROM THE CALLER — NOT VERIFIED", value: "Refactor the tests in ~/dev/secret-project" }),
    systemField({ scheme: L, w: 400, caption: "TARGET — RESOLVED BY THE SYSTEM", value: "/Users/joeyc/dev/secret-project" }),
  ];
  flow(pair, pairItems, { direction: "HORIZONTAL", gap: 24, hugW: false, fixedW: W - M * 2 });
  y += pair.height + 40;

  root.resize(W, y);
  page.resize(W + 240, y + 240);
  return { page: "Components", families: 4, states: SIGNATURE_STATES.length, instances: instItems.length };
}

console.log("__RESULT__" + JSON.stringify(buildComponents()));
