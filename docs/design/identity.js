// Components page layout: the caller-identity family. The factories live in
// widgets.js, which build.js prepends.

function buildIdentity() {
  const page = figma.root.children.find((p) => p.name === "Components");
  if (!page) throw new Error("Components page not found");
  // This module owns the page root; later modules draw into it rather than
  // clearing, so the page is composed instead of overwritten.
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
  const heading = (chars) => { y += text("cmp/h", chars, 15, ink(L, "text-primary"), M, y, "Semi Bold") + 10; };
  const note = (chars) => {
    const t = makeText(root, { name: "cmp/note", chars, size: 11, color: ink(L, "text-tertiary"), x: M, y, wrap: W - M * 2 });
    y += t.height + 18;
  };

  y += text("cmp/title", "Components", 22, ink(L, "text-primary"), M, y, "Semi Bold") + 12;
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
  y += idRow.height + 12;

  // Real instances of the three rows above, so every family in B4 has instances and
  // not only SignatureBadge.
  const idGal = makeFrame(root, { name: "cmp/identityrow-instances", x: M, y, w: 520, h: 56, fill: C.surface[L], clips: false });
  const idInst = idItems.map((it) => {
    const inst = it.node.createInstance();
    inst.name = "instance-" + it.node.name;
    return { node: inst, w: it.w, h: it.h };
  });
  flow(idGal, idInst, { direction: "VERTICAL", gap: 10, hugW: false, fixedW: 520 });
  y += idGal.height + 40;

  // ---- ProcessTree: deep and degenerate
  heading("ProcessTree");
  note("The requester carries the accent rule and semibold weight. The degenerate single-process case is drawn because it is the common one and must not look broken.");
  const treeCol = makeFrame(root, { name: "cmp/trees", x: M, y, w: W - M * 2, h: 180, fill: C.surface[L] });
  const treeItems = [
    processTree({ scheme: L, deep: true, processes: DEEP_TREE, w: 500 }),
    processTree({ scheme: L, deep: false, processes: DIRECT_TREE, w: 500, caption: "Direct request — no intermediary process." }),
  ];
  flow(treeCol, treeItems, { direction: "HORIZONTAL", gap: 32, hugW: false, fixedW: W - M * 2 });
  y += treeCol.height + 12;

  const treeGal = makeFrame(root, { name: "cmp/trees-instances", x: M, y, w: W - M * 2, h: 140, fill: C.surface[L], clips: false });
  const treeInst = treeItems.map((it) => {
    const inst = it.node.createInstance();
    inst.name = "instance-" + it.node.name;
    return { node: inst, w: it.w, h: it.h };
  });
  flow(treeGal, treeInst, { direction: "HORIZONTAL", gap: 32, hugW: false, fixedW: W - M * 2 });
  y += treeGal.height + 40;

  // ---- UntrustedField beside SystemField: the pair that proves the distinction
  heading("UntrustedField");
  note("Same value, two treatments. The caller's text is set on a sunken surface behind a caution rule under an explicit label; a system-derived fact of identical content is plain on the surface. If these ever look alike, in-dialog label spoofing works.");
  const pair = makeFrame(root, { name: "cmp/field-pair", x: M, y, w: W - M * 2, h: 80, fill: C.surface[L] });
  const pairItems = [
    untrustedField({ scheme: L, w: 400, caption: "FROM THE CALLER — NOT VERIFIED", value: "Refactor the tests in ~/dev/secret-project" }),
    systemField({ scheme: L, w: 400, caption: "TARGET — RESOLVED BY THE SYSTEM", value: "/Users/joeyc/dev/secret-project" }),
  ];
  flow(pair, pairItems, { direction: "HORIZONTAL", gap: 24, hugW: false, fixedW: W - M * 2 });
  y += pair.height + 12;

  const pairGal = makeFrame(root, { name: "cmp/field-pair-instances", x: M, y, w: W - M * 2, h: 60, fill: C.surface[L], clips: false });
  const pairInst = pairItems.map((it) => {
    const inst = it.node.createInstance();
    inst.name = "instance-" + it.node.name;
    return { node: inst, w: it.w, h: it.h };
  });
  flow(pairGal, pairInst, { direction: "HORIZONTAL", gap: 24, hugW: false, fixedW: W - M * 2 });
  y += pairGal.height + 40;

  root.resize(W, y);
  page.resize(W + 240, y + 240);
  return { page: "Components", families: 4, states: SIGNATURE_STATES.length, instances: instItems.length };
}

// Clears the page and draws the identity family. The page-level result is emitted
// by the LAST module for the page (controls.js), which draws into the root created
// here. Calling this is what keeps the page idempotent: without it nothing clears
// the page and every controls build appends to the previous run's root.
buildIdentity();
