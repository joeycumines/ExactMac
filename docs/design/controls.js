// Control components: the vocabulary the approval prompt is built from.
// Appended to the same sheet as identity.js; that module owns the page root.

const CT = TOKENS.color;
const CR = TOKENS.radius;
const cw = (scheme, name) => CT[name][scheme];

// ---------------------------------------------------------------------- Button

// Variants carry meaning, not decoration. `deny` is a quiet secondary so it can
// never be the default focus, and it is never placed adjacent to `primary`.
// `caution` is for grants that outlive the request.
const BUTTON_VARIANTS = {
  primary:  { fill: "accent",  ink: "surface", h: 34, w: 150, style: "Semibold" },
  secondary:{ fill: "surface-raised", ink: "text-primary", h: 34, w: 150, style: "Regular", stroke: "control-border" },
  deny:     { fill: "surface", ink: "danger",  h: 34, w: 96,  style: "Semibold", stroke: "control-border" },
  quiet:    { fill: "surface", ink: "text-secondary", h: 28, w: 110, style: "Regular" },
  caution:  { fill: "surface-raised", ink: "caution", h: 34, w: 190, style: "Semibold", stroke: "caution" },
};

function button(o) {
  const scheme = o.scheme || "light";
  const v = BUTTON_VARIANTS[o.variant];
  const b = makeComponent(null, {
    name: "Button/" + o.variant,
    w: v.w, h: v.h,
    // A filled accent button carries WHITE text; every other variant carries ink
    // of its own semantic color, so the ink token is named per variant.
    fill: cw(scheme, v.fill),
    radius: CR["radius-md"],
    stroke: v.stroke ? cw(scheme, v.stroke) : undefined,
  });
  // The label spans the button's inner width and centres its own text, rather
  // than relying on the child being offset by the leftover slack. Centring the
  // CHILD measured 30.5pt in memory but was written back as 0, which left every
  // button label hard against its left edge. textAlignHorizontal survives the
  // round trip, so the visual centring no longer depends on a stored child offset.
  const inner = v.w - 16;
  const label = makeText(null, {
    name: "label", chars: o.label || o.variant, size: 13, style: v.style,
    color: cw(scheme, v.fill === "accent" ? "on-accent" : v.ink),
    align: "CENTER", wrap: inner,
  });
  flow(b, [{ node: label, w: inner, h: label.height }], {
    direction: "HORIZONTAL", padLeft: 8, padRight: 8, align: "CENTER",
    hugW: false, hugH: false, fixedW: v.w, fixedH: v.h,
  });
  b.resize(v.w, v.h);
  return { node: b, w: v.w, h: v.h };
}

// -------------------------------------------------------------------- RiskChip

// The single most important thing the operator reads first: how big a mistake
// approving this would be. Scaled by blast radius, not by capability name.
const RISK_LEVELS = {
  routine:  { label: "Routine",  tone: "text-secondary" },
  elevated: { label: "Elevated", tone: "caution" },
  high:     { label: "High",     tone: "danger" },
};

function riskChip(o) {
  const scheme = o.scheme || "light";
  const lv = RISK_LEVELS[o.level];
  const c = makeComponent(null, {
    name: "RiskChip/" + o.level, w: 92, h: 22,
    fill: cw(scheme, "surface-raised"), radius: CR["radius-pill"],
    stroke: cw(scheme, lv.tone === "text-secondary" ? "control-border" : lv.tone),
  });
  const dot = makeRect(null, { name: "dot", w: 6, h: 6, fill: cw(scheme, lv.tone), radius: 3 });
  const label = makeText(null, {
    name: "label", chars: lv.label, size: 11, style: "Semibold", color: cw(scheme, lv.tone),
  });
  flow(c, [{ node: dot }, { node: label }], {
    direction: "HORIZONTAL", gap: 6, padLeft: 9, padRight: 9, padTop: 4, padBottom: 4,
    align: "CENTER", hugW: false, fixedW: 92,
  });
  c.resize(92, 22);
  return { node: c, w: 92, h: 22 };
}

// ------------------------------------------------------------------- OptionRow

// One response. It must always state its OWN breadth and duration on its face:
// an operator cannot compare options that hide their scope. `default` marks the
// focused option, and it is never the destructive one.
const OPTIONS = [
  { key: "deny",     title: "Deny",                  breadth: "—",                    duration: "no grant is created",              tone: "danger",  destructive: true },
  { key: "once",     title: "Allow once",            breadth: "this exact request",     duration: "expires when it completes",          tone: "accent",  def: true },
  { key: "target",   title: "Allow for TextEdit",     breadth: "one application",        duration: "until you revoke it",                tone: "neutral" },
  { key: "session",  title: "Allow for this session", breadth: "every app this agent touches", duration: "until ExactMac quits",           tone: "neutral" },
  { key: "envelope", title: "Pre-authorize a batch", breadth: "a declared capability set", duration: "you choose, up to 8 hours",        tone: "caution" },
  { key: "global",   title: "Always allow",          breadth: "every app, every time",  duration: "until you revoke it",                tone: "danger",  destructive: true },
];

function optionRow(o) {
  const scheme = o.scheme || "light";
  const opt = o.option;
  const isDef = !!opt.def;
  const w = o.w || 372;
  const row = makeComponent(null, {
    name: "OptionRow/" + opt.key, w: w, h: 52,
    fill: isDef ? cw(scheme, "surface-raised") : cw(scheme, "surface"),
    radius: CR["radius-md"],
    stroke: isDef ? cw(scheme, "accent") : cw(scheme, "separator"),
  });
  // A destructive option is marked in the ink, never by making it the default.
  const title = makeText(null, {
    name: "title", chars: opt.title, size: 13, style: "Semibold",
    color: cw(scheme, opt.destructive ? "danger" : "text-primary"),
  });
  const scope = makeText(null, {
    name: "scope",
    chars: opt.breadth + "  ·  " + opt.duration,
    size: 11, color: cw(scheme, "text-secondary"), wrap: w - 60,
  });
  const stackW = isDef ? w - 96 : w - 46;   // leave room for the default badge
  const stack = makeFrame(null, {
    name: "stack", w: stackW, h: 34,
    fill: isDef ? cw(scheme, "surface-raised") : cw(scheme, "surface"),
  });
  flow(stack, [{ node: title }, { node: scope }], {
    direction: "VERTICAL", gap: 2, fixedW: stackW,
  });
  const items = [{ node: stack, w: stack.width, h: stack.height }];
  if (isDef) {
    const badge = makeText(null, {
      name: "default", chars: "default", size: 10, style: "Semibold",
      color: cw(scheme, "accent-text"),
    });
    items.push({ node: badge });
  }
  flow(row, items, {
    direction: "HORIZONTAL", gap: 8, padLeft: 12, padRight: 12, padTop: 9, padBottom: 9,
    align: "CENTER", hugW: false, fixedW: w,
  });
  return { node: row, w: w, h: row.height };
}

// ----------------------------------------------------------------- NoteField

// Feedback to the model. A rejection without a reason teaches the agent nothing,
// so the field is present on deny as prominently as on allow.
function noteField(o) {
  const scheme = o.scheme || "light";
  const w = o.w || 372;
  const f = makeComponent(null, {
    name: "NoteField/" + (o.variant || "default"), w: w, h: 60,
    fill: cw(scheme, "surface"), radius: CR["radius-md"],
    stroke: cw(scheme, "control-border"),
  });
  const cap = makeText(null, {
    name: "caption", chars: o.caption || "NOTE TO THE AGENT — SENT BACK WITH YOUR DECISION",
    size: 10, style: "Semibold", color: cw(scheme, "text-secondary"), wrap: w - 24,
  });
  const val = makeText(null, {
    name: "value", chars: o.value || "Why are you deciding this way? The agent sees this.",
    size: 12, color: cw(scheme, "text-tertiary"), wrap: w - 24,
  });
  flow(f, [{ node: cap }, { node: val }], {
    direction: "VERTICAL", gap: 3, padLeft: 12, padRight: 12, padTop: 8, padBottom: 8,
    hugW: false, fixedW: w,
  });
  return { node: f, w: w, h: f.height };
}

// ------------------------------------------------------- BiometricState and Payload

// Names the ONE decision being authorized, so a success cannot be read as
// blanket consent for whatever the prompt happened to be showing.
function biometricState(o) {
  const scheme = o.scheme || "light";
  const w = o.w || 372;
  const ready = o.state !== "absent" && o.state !== "failed";
  const tone = ready ? "success" : "danger";
  const f = makeComponent(null, {
    name: "BiometricState/" + (o.state || "ready"), w: w, h: 34,
    fill: cw(scheme, "surface-sunken"), radius: CR["radius-sm"],
  });
  const dot = makeRect(null, { name: "dot", w: 8, h: 8, fill: cw(scheme, tone), radius: 4 });
  const label = makeText(null, {
    name: "label", chars: o.label || "Touch ID will confirm: allow TextEdit clipboard read once",
    size: 11, color: cw(scheme, "text-secondary"), wrap: w - 36,
  });
  flow(f, [{ node: dot, w: 8, h: 8 }, { node: label }], {
    direction: "HORIZONTAL", gap: 8, padLeft: 12, padRight: 12, padTop: 8, padBottom: 8,
    align: "CENTER", hugW: false, fixedW: w,
  });
  return { node: f, w: w, h: f.height };
}

// The payload is never truncated or elided. The specimen shows a long command
// wrapping across lines inside a sunken block, with a copy affordance that warns
// the value lands on the shared pasteboard.
function payloadBlock(o) {
  const scheme = o.scheme || "light";
  const w = o.w || 372;
  const f = makeComponent(null, {
    name: "PayloadBlock/" + (o.variant || "default"), w: w, h: 20,
    fill: cw(scheme, "surface-sunken"), radius: CR["radius-sm"],
    stroke: cw(scheme, "separator"),
  });
  const cap = makeText(null, {
    name: "caption", chars: "EXACT REQUEST — NOTHING IS TRUNCATED", size: 10,
    style: "Semibold", color: cw(scheme, "text-secondary"),
  });
  const body = makeText(null, {
    name: "body", chars: o.body, size: 11, mono: true, wrap: w - 24,
    color: cw(scheme, "text-primary"),
  });
  const copy = makeText(null, {
    name: "copy", chars: "Copy", size: 11, style: "Semibold", color: cw(scheme, "accent-text"),
  });
  const head = makeFrame(null, { name: "head", w: w - 24, h: 16, fill: cw(scheme, "surface-sunken") });
  flow(head, [{ node: cap }, { node: copy }], {
    direction: "HORIZONTAL", gap: 8, mainAlign: "SPACE_BETWEEN", fixedW: w - 24,
  });
  const items = [{ node: head, w: head.width, h: head.height }, { node: body }];
  flow(f, items, {
    direction: "VERTICAL", gap: 6, padLeft: 12, padRight: 12, padTop: 8, padBottom: 8,
    hugW: false, fixedW: w,
  });
  return { node: f, w: w, h: f.height };
}

// ------------------------------------------------------------------- the page

function buildControls() {
  const page = figma.root.children.find((p) => p.name === "Components");
  if (!page) throw new Error("Components page not found");
  const root = page.children[0];
  if (!root) throw new Error("identity.js must render the page root first");
  const L = "light";
  const W = TOKENS.layout.specimenWidth;
  const M = 64;

  // Continue below whatever identity.js drew.
  let y = Math.max(root.height, 0) + 48;

  const heading = (chars) => {
    makeText(root, {
      name: "ctl/h", chars, size: 15, style: "Semibold",
      color: cw(L, "text-primary"), x: M, y,
    });
    y += 26;
  };
  const note = (chars) => {
    const t = makeText(root, { name: "ctl/note", chars, size: 11, color: cw(L, "text-tertiary"), x: M, y, wrap: W - M * 2 });
    y += t.height + 18;
  };
  const strip = (name, items) => {
    const s = makeFrame(root, { name: "ctl/" + name, x: M, y, w: W - M * 2, h: 20, fill: cw(L, "surface") });
    flow(s, items, { direction: "HORIZONTAL", gap: 12, hugW: false, fixedW: W - M * 2 });
    y += s.height + 40;
  };

  makeText(root, {
    name: "ctl/title", chars: "Controls", size: 22, style: "Semibold",
    color: cw(L, "text-primary"), x: M, y,
  });
  y += 52;

  heading("RiskChip");
  note("Blast radius, not capability name. Read first, because it is the only thing that tells the operator how bad a mistake here would be.");
  strip("risk", ["routine", "elevated", "high"].map((l) => riskChip({ level: l, scheme: L })));

  heading("Button");
  note("Deny is a quiet secondary and is never the default focus nor adjacent to the primary action. Caution marks a grant that outlives the request; Always allow is styled as destructive because it is.");
  strip("buttons", [
    button({ variant: "primary", scheme: L, label: "Allow once" }),
    button({ variant: "secondary", scheme: L, label: "Ask every time" }),
    button({ variant: "caution", scheme: L, label: "Pre-authorize 8 hours" }),
    button({ variant: "deny", scheme: L, label: "Deny" }),
    button({ variant: "quiet", scheme: L, label: "Why?" }),
  ]);

  heading("OptionRow");
  note("Every option states its own breadth AND duration on its face; an operator cannot compare options whose scope is hidden. The default is Allow once, and the two destructive options are marked in ink rather than by being made obvious.");
  const optWrap = makeFrame(root, { name: "ctl/options", x: M, y, w: 760, h: 20, fill: cw(L, "surface") });
  flow(optWrap, OPTIONS.map((o2) => optionRow({ option: o2, scheme: L, w: 372 })), {
    direction: "VERTICAL", gap: 8, hugW: false, fixedW: 760,
  });
  y += optWrap.height + 40;

  heading("NoteField");
  note("Present on deny as prominently as on allow. A rejection without a reason teaches the agent nothing, so the reason is part of the decision, not an afterthought.");
  const noteWrap = makeFrame(root, { name: "ctl/notes", x: M, y, w: 760, h: 20, fill: cw(L, "surface") });
  flow(noteWrap, [
    noteField({ scheme: L, w: 372 }),
    noteField({ scheme: L, w: 372, variant: "denied", caption: "NOTE TO THE AGENT — SENT BACK WITH YOUR DENIAL", value: "Use the scoped option next time; this touches my keychain project." }),
  ], { direction: "VERTICAL", gap: 10, hugW: false, fixedW: 760 });
  y += noteWrap.height + 40;

  heading("BiometricState");
  note("Names the ONE decision being authorized, so a success can never be read as blanket consent for whatever the prompt happened to be showing.");
  const bioWrap = makeFrame(root, { name: "ctl/bio", x: M, y, w: 760, h: 20, fill: cw(L, "surface") });
  flow(bioWrap, [
    biometricState({ scheme: L, w: 372, state: "ready" }),
    biometricState({ scheme: L, w: 372, state: "absent", label: "Touch ID unavailable — this decision will require your password instead" }),
  ], { direction: "VERTICAL", gap: 8, hugW: false, fixedW: 760 });
  y += bioWrap.height + 40;

  heading("PayloadBlock");
  note("The complete request, wrapping rather than eliding. Copy is offered but the value lands on the shared pasteboard, so it is labelled rather than silent.");
  const payWrap = makeFrame(root, { name: "ctl/payload", x: M, y, w: 760, h: 20, fill: cw(L, "surface") });
  flow(payWrap, [
    payloadBlock({ scheme: L, w: 372, body: "osascript -e 'tell application \"TextEdit\" to get the clipboard as «class ktxt»' -e 'return' 2>&1 | head -c 4096" }),
    payloadBlock({ scheme: L, w: 372, variant: "long", body: "AXUIElementCopyAttributeValue(AXFocusedApplication, kAXFocusedWindowAttribute), walking children up to depth 12 and returning role, title, value and enabled for every node whose role is in {AXTextField, AXTextArea, AXStaticText}" }),
  ], { direction: "VERTICAL", gap: 10, hugW: false, fixedW: 760 });
  y += payWrap.height + 40;

  root.resize(W, y);
  page.resize(W + 240, y + 240);
  return { page: "Components", controlComponents: 6, options: OPTIONS.length };
}

console.log("__RESULT__" + JSON.stringify(buildControls()));
