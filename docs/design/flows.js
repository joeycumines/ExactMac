// Flows page: the sequences, because a consent system is mostly wrong in the
// transitions rather than in the window. Three things have to be visibly true:
// a single request prompts exactly once, a request inside an approved envelope
// does not prompt at all, and revocation takes effect on the very next call.

const FT = TOKENS.color;
const FR = TOKENS.radius;
const fk = (scheme, name) => FT[name][scheme];

// A numbered step. The number carries the order, because arrow glyphs are not
// dependable in the bundled fonts and a sequence must not depend on one.
function stepCard(o) {
  const scheme = o.scheme || "light";
  const w = o.w || 196;
  const c = makeComponent(null, {
    name: "FlowStep/" + o.actor, w: w, h: 20,
    fill: fk(scheme, o.tone === "quiet" ? "surface-sunken" : "surface-raised"),
    radius: FR["radius-md"], stroke: fk(scheme, "separator"),
  });
  const num = makeFrame(null, {
    name: "num", w: 18, h: 18, fill: fk(scheme, o.tone === "quiet" ? "text-tertiary" : "accent"),
    radius: 9,
  });
  const numText = makeText(null, {
    name: "n", chars: String(o.n), size: 10, style: "Semi Bold",
    color: fk(scheme, o.tone === "quiet" ? "surface" : "on-accent"), align: "CENTER", wrap: 18,
  });
  flow(num, [{ node: numText, w: 18, h: numText.height }], {
    direction: "HORIZONTAL", align: "CENTER", hugW: false, fixedW: 18,
  });
  num.resize(18, 18);

  const head = makeFrame(null, { name: "head", w: w - 38, h: 18, fill: fk(scheme, "surface-raised") });
  const actor = makeText(null, {
    name: "actor", chars: o.actor, size: 10, style: "Semi Bold", mono: true,
    color: fk(scheme, "text-tertiary"), wrap: w - 38,
  });
  const action = makeText(null, {
    name: "action", chars: o.action, size: 12, style: "Semi Bold",
    color: fk(scheme, o.tone === "quiet" ? "text-secondary" : "text-primary"), wrap: w - 38,
  });
  flow(head, [{ node: actor }, { node: action }], { direction: "VERTICAL", gap: 2, fixedW: w - 38 });
  const detail = o.detail ? makeText(null, {
    name: "detail", chars: o.detail, size: 10, wrap: w - 24,
    color: fk(scheme, "text-secondary"),
  }) : null;

  const items = [{ node: num, w: 18, h: 18 }, { node: head, w: head.width, h: head.height }];
  if (detail) items.push({ node: detail, w: detail.width, h: detail.height });
  flow(c, items, {
    direction: "VERTICAL", gap: 8, padLeft: 12, padRight: 12, padTop: 12, padBottom: 12,
    hugW: false, fixedW: w,
  });
  return { node: c, w: w, h: c.height };
}

// A thin connector with a dot at the receiving end, so order is legible even
// where the numbering is far apart.
function connector(scheme) {
  const g = makeFrame(null, { name: "arrow", w: 28, h: 2, fill: fk(scheme, "separator") });
  const bar = makeRect(null, { name: "bar", w: 22, h: 1, fill: fk(scheme, "separator") });
  const tip = makeRect(null, { name: "tip", w: 4, h: 4, fill: fk(scheme, "separator") });
  flow(g, [{ node: bar, w: 22, h: 1 }, { node: tip, w: 4, h: 4 }], {
    direction: "HORIZONTAL", gap: 2, align: "CENTER", mainAlign: "MAX", hugW: false, fixedW: 28,
  });
  g.resize(28, 4);
  return { node: g, w: 28, h: 4 };
}

// A lane is a captioned row of steps, optionally interleaved with connectors.
function lane(sheet, o) {
  const scheme = o.scheme || "light";
  const w = o.w || 1300;
  const items = [];
  o.steps.forEach((s, i) => {
    if (i > 0 && o.arrow !== false) {
      const a = connector(scheme);
      items.push({ node: a.node, w: a.w, h: a.h });
    }
    const card = stepCard({ scheme, ...s, w: o.cardW || 196 });
    items.push({ node: card.node, w: card.w, h: card.h });
  });
  const row = makeFrame(null, { name: "lane-" + o.name, w: w, h: 20, fill: fk(scheme, "surface") });
  flow(row, items, { direction: "HORIZONTAL", gap: 8, align: "MIN", hugW: false, fixedW: w });
  return { node: row, w: w, h: row.height };
}

function buildFlows() {
  const page = figma.root.children.find((p) => p.name === "Flows");
  if (!page) throw new Error("Flows page not found");
  while (page.children.length > 0) page.children[0].remove();

  const sheet = makeFrame(page, { name: "flows", x: 0, y: 0, w: 1400, h: 400, fill: FT.surface.light });
  const M = 64;
  const W = 1300;
  let y = M;

  const h1 = (chars) => {
    const t = makeText(sheet, {
      name: "fl/h", chars, size: 15, style: "Semi Bold", color: fk("light", "text-primary"), x: M, y,
    });
    y += t.height + 6;
  };
  const cap = (chars) => {
    const t = makeText(sheet, {
      name: "fl/cap", chars, size: 11, color: fk("light", "text-tertiary"), x: M, y, wrap: W,
    });
    y += t.height + 14;
  };
  const body = (chars, size, tone) => {
    const t = makeText(sheet, {
      name: "fl/body", chars, size: size || 13, style: "Semi Bold",
      color: fk("light", tone || "text-primary"), x: M, y, wrap: W,
    });
    y += t.height + 6;
  };

  body("ExactMac consent", 22);
  y += 14;
  cap("Three sequences have to be visibly true: one request prompts exactly once; a request inside an approved envelope does not prompt at all; and a revocation takes effect on the next call. If any of these is only implied by the code, it is not a control.");
  y += 22;

  // ---- 1. a single request
  h1("1 · A single request prompts exactly once");
  cap("The server re-derives capability and scope from the request bytes and matches them against code-identity-bound grants. An unsigned caller is escalated, never silently rejected, because the boundary was crossed at socket access.");
  const l1 = lane(null, {
    name: "single", w: W, scheme: "light", cardW: 148,
    steps: [
      { n: 1, actor: "AGENT", action: "Calls the RPC", detail: "with a reason it is required to give" },
      { n: 2, actor: "SERVER", action: "Derives the capability", detail: "and scope from the request bytes" },
      { n: 3, actor: "SERVER", action: "Resolves the caller", detail: "graded evidence, never a gate" },
      { n: 4, actor: "CONSOLE", action: "Shows the prompt", detail: "caller tree, reason, target, payload" },
      { n: 5, actor: "OPERATOR", action: "Chooses and confirms", detail: "biometric only when blast radius earns it" },
      { n: 6, actor: "SERVER", action: "Writes the grant", detail: "bound to code identity, never a pid" },
      { n: 7, actor: "AGENT", action: "Gets the result", detail: "and the operator's note, verbatim" },
    ],
  });
  const row1 = makeFrame(sheet, { name: "fl/row1", x: M, y, w: W, h: l1.h, fill: FT.surface.light });
  flow(row1, [l1], { direction: "HORIZONTAL", hugW: false, fixedW: W });
  y += l1.h + 44;

  // ---- 2. the envelope, and the fast path it buys
  h1("2 · A pre-authorized envelope, and the silence inside it");
  cap("An agent asks for what it expects to need before it needs it. The envelope declares a capability set and a bounded duration, can never confer global scope, and expires as a unit. Calls inside it never open a window — that silence is the entire point, and it is why the envelope is the most expensive thing the operator can grant.");
  const l2 = lane(null, {
    name: "envelope", w: W, scheme: "light", cardW: 158,
    steps: [
      { n: 1, actor: "AGENT", action: "Asks up front", detail: "declares the capability set it expects" },
      { n: 2, actor: "CONSOLE", action: "Reviews the batch", detail: "each capability with its consequence" },
      { n: 3, actor: "OPERATOR", action: "Grants for hours", detail: "biometric required at this breadth" },
      { n: 4, actor: "SERVER", action: "Stores the envelope", detail: "never as global-persistent scope" },
    ],
  });
  const row2 = makeFrame(sheet, { name: "fl/row2", x: M, y, w: W, h: l2.h, fill: FT.surface.light });
  flow(row2, [l2], { direction: "HORIZONTAL", hugW: false, fixedW: W });
  y += l2.h + 30;

  // The two lanes that matter: inside and outside.
  const inside = lane(null, {
    name: "inside", w: 620, scheme: "light", cardW: 150, arrow: false,
    steps: [
      { n: 5, actor: "AGENT", action: "Calls inside the envelope", detail: "capability and scope both match" },
      { n: 6, actor: "SERVER", action: "Matches the envelope", detail: "no prompt, no biometric, no window" },
      { n: 7, actor: "AGENT", action: "Continues working", detail: "the point of pre-authorization" },
    ],
  });
  const outside = lane(null, {
    name: "outside", w: 620, scheme: "light", cardW: 150,
    steps: [
      { n: 5, actor: "AGENT", action: "Calls outside it", detail: "screen capture was never declared" },
      { n: 6, actor: "SERVER", action: "Finds no match", detail: "so it prompts as if there were none" },
      { n: 7, actor: "OPERATOR", action: "Decides again", detail: "the envelope is a ceiling, not a blank cheque" },
    ],
  });
  const lanes = makeFrame(sheet, { name: "fl/lanes", x: M, y, w: W, h: 20, fill: FT.surface.light });
  flow(lanes, [inside, outside], { direction: "HORIZONTAL", gap: 40, hugW: false, fixedW: W });
  y += lanes.height + 16;
  const laneNote = makeText(sheet, {
    name: "fl/lane-note",
    chars: "LEFT: inside the envelope, nothing appears.    RIGHT: one capability outside it, and the window opens again.",
    size: 11, color: fk("light", "text-tertiary"), x: M, y, wrap: W,
  });
  y += laneNote.height + 44;

  // ---- 3. revocation
  h1("3 · Revocation is immediate and total");
  cap("A grant the operator can revoke but not observe being revoked is not a control. Turning the service off must not silently restore grants either: a disabled service denies everything, and re-enabling it must not inherit what the operator had not intended to keep.");
  const l3 = lane(null, {
    name: "revoke", w: W, scheme: "light", cardW: 158,
    steps: [
      { n: 1, actor: "OPERATOR", action: "Revokes from the menu bar", detail: "one grant, or all of them" },
      { n: 2, actor: "SERVER", action: "Drops it immediately", detail: "and survives a restart" },
      { n: 3, actor: "AGENT", action: "Next call prompts again", detail: "with no memory of the old grant" },
      { n: 4, actor: "AUDIT", action: "Records the basis", detail: "which grant matched, or that none did" },
    ],
  });
  const row3 = makeFrame(sheet, { name: "fl/row3", x: M, y, w: W, h: l3.h, fill: FT.surface.light });
  flow(row3, [l3], { direction: "HORIZONTAL", hugW: false, fixedW: W });
  y += l3.h + 40;

  sheet.resize(1400, y);
  page.resize(1400 + 240, y + 240);
  return { page: "Flows", lanes: 5, steps: 25 };
}

console.log("__RESULT__" + JSON.stringify(buildFlows()));
