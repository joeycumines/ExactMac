// Shared component factories: the vocabulary every page draws from.
//
// These live apart from the page modules because more than one page needs them:
// the Screens page builds the approval prompt out of the same RiskChip,
// ProcessTree, OptionRow and PayloadBlock that the Components page documents.
// build.js prepends this file to every page alongside lib.js, so a factory is
// declared once and is a real component wherever it is instantiated.

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
  // o.w is honoured; it used to be ignored, so a caller asking for a narrower badge
  // silently got the state's default and had no way to fit a dense row.
  const bw = o.w || s.w;
  const tone = s.tone === "neutral" ? "text-secondary" : s.tone;
  const c = makeComponent(null, {
    name: "SignatureBadge/" + s.key,
    w: bw, h: 20, fill: ink(scheme, "surface-raised"), radius: R["radius-pill"],
    stroke: ink(scheme, tone === "neutral" ? "control-border" : tone),
  });
  // A dot plus the word: color alone never carries the state, so the badge still
  // reads correctly in grayscale or for a colorblind operator.
  const dot = makeRect(c, { name: "dot", w: 6, h: 6, fill: ink(scheme, tone), radius: 3 });
  const label = makeText(c, {
    name: "label", chars: s.label, size: 11, style: "Semi Bold", color: ink(scheme, tone),
  });
  flow(c, [{ node: dot }, { node: label }], {
    direction: "HORIZONTAL", gap: 6, padLeft: 9, padRight: 9, padTop: 3, padBottom: 3,
    align: "CENTER", hugW: false, fixedW: bw,
  });
  // Height follows the content: the 11pt Semi Bold label is ~16pt, so a 20pt pill
  // clipped it by 2pt. The overflow gate found it.
  return { node: c, w: bw, h: c.height };
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
    size: 12, style: "Semi Bold", color: ink(scheme, "text-primary"),
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
    style: p.isRequester ? "Semi Bold" : "Regular",
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
  // Height is NOT pinned: a path that wraps to two lines needs ~62pt, and pinning
  // the row to 52 clipped it. The overflow gate found this, not the eye.
  flow(row, items, {
    direction: "HORIZONTAL", gap: 10, padLeft: 10, padRight: 10, padTop: 10, padBottom: 10,
    align: "CENTER", hugW: false, fixedW: o.w || 400,
  });
  return { node: row, w: o.w || 400, h: row.height };
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
  const compactRole = p.compact && p.isRequester ? "   ·   requesting" : "";
  const label = makeText(row, {
    name: "label",
    chars: (p.compact
      ? p.name + (p.detail ? "   " + p.detail : "") + compactRole
      : p.name + "   pid " + p.pid + (p.detail ? "   " + p.detail : "")),
    size: 12, style: p.isRequester ? "Semi Bold" : "Regular",
    color: p.isRequester ? ink(scheme, "text-primary") : ink(scheme, "text-secondary"),
  });
  items.push({ node: label });
  // Signature state travels with the row. Without it the prompt showed a process
  // tree carrying no evidence of who was calling, which is a process list rather
  // than the graded-evidence model the rest of the design depends on.
  if (p.signature) {
    const badge = signatureBadge({ state: p.signature, scheme, w: p.sigW || 96 });
    items.push({ node: badge.node, w: badge.w, h: badge.h });
  }
  if (p.isRequester && !p.compact) {
    const role = makeText(null, {
      name: "role", chars: "requesting", size: 11, style: "Semi Bold",
      color: ink(scheme, "accent"),
    });
    items.push({ node: role });
  }
  flow(row, items, {
    direction: "HORIZONTAL", gap: 6, padLeft: padLeft, padRight: 8, padTop: 6, padBottom: 6,
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
  // `compact` is forwarded onto each row: in the 388pt prompt disclosure a row
  // cannot hold indent + name + pid + signature badge + a separate role label, so
  // the compact form drops the pid and folds the role word into the label. The pid
  // remains on the Components specimen, which is where B4 asks for it.
  const items = o.processes.map((p) =>
    processRow(Object.assign({}, p, { compact: !!o.compact }), scheme, w));
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
    size: 10, style: "Semi Bold", color: ink(scheme, "caution"),
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
    name: "caption", chars: o.caption, size: 10, style: "Semi Bold",
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

// Every row carries signature state, including an unresolved one, so the component
// an implementer cites demonstrates the evidence rather than only naming it.
const DEEP_TREE = [
  { name: "Terminal", pid: 4211, depth: 0, detail: "host application", signature: SIGNATURE_STATES[0] },
  { name: "zsh", pid: 4402, depth: 1, detail: "login shell", signature: SIGNATURE_STATES[5] },
  { name: "node", pid: 4490, depth: 2, detail: "opencode", signature: SIGNATURE_STATES[3] },
  { name: "exactmac-mcp", pid: 4517, depth: 3, detail: "MCP client", isRequester: true, signature: SIGNATURE_STATES[1] },
];

const DIRECT_TREE = [
  { name: "Codex", pid: 8823, depth: 0, detail: "agent host", isRequester: true, signature: SIGNATURE_STATES[0] },
];

const CT = TOKENS.color;
const CR = TOKENS.radius;
const cw = (scheme, name) => CT[name][scheme];

// ---------------------------------------------------------------------- Button

// Variants carry meaning, not decoration. `deny` is a quiet secondary so it can
// never be the default focus, and it is never placed adjacent to `primary`.
// `caution` is for grants that outlive the request.
const BUTTON_VARIANTS = {
  primary:  { fill: "accent",  ink: "surface", h: 34, w: 150, style: "Semi Bold" },
  secondary:{ fill: "surface-raised", ink: "text-primary", h: 34, w: 150, style: "Regular", stroke: "control-border" },
  deny:     { fill: "surface", ink: "danger",  h: 34, w: 96,  style: "Semi Bold", stroke: "control-border" },
  quiet:    { fill: "surface", ink: "text-secondary", h: 28, w: 110, style: "Regular" },
  caution:  { fill: "surface-raised", ink: "caution", h: 34, w: 190, style: "Semi Bold", stroke: "caution" },
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
    name: "label", chars: lv.label, size: 11, style: "Semi Bold", color: cw(scheme, lv.tone),
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
//
// ORDER IS ENFORCED BY THE CALLER, not here: B5 requires the destructive choice to
// be neither the default nor adjacent to the primary action, and an earlier layout
// put Deny immediately above the focused option while claiming otherwise. The
// prompt's ordering is ["once","target","session","envelope","deny","global"]: the
// default leads, the extremes bracket the list, and Deny is never next to the
// option that holds focus.
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
    name: "title", chars: opt.title, size: 13, style: "Semi Bold",
    color: cw(scheme, opt.destructive ? "danger" : "text-primary"),
  });
  // The stack width is declared FIRST because the scope text wraps to it. It used
  // to wrap to w-60 while the stack was w-96 on the default row, so the scope box
  // overhung its own parent by 36pt — latent until the overflow gate caught it.
  const stackW = isDef ? w - 96 : w - 46;   // leave room for the default badge
  const scope = makeText(null, {
    name: "scope",
    chars: opt.breadth + "  ·  " + opt.duration,
    size: 11, color: cw(scheme, "text-secondary"), wrap: stackW,
  });
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
      name: "default", chars: "default", size: 10, style: "Semi Bold",
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
    size: 10, style: "Semi Bold", color: cw(scheme, "text-secondary"), wrap: w - 24,
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
  const body = makeText(null, {
    name: "body", chars: o.body, size: 11, mono: true, wrap: w - 24,
    color: cw(scheme, "text-primary"),
  });
  // The caption and a full-sentence warning cannot share one line at 372pt: the
  // caption measures ~221pt and "Copy ... shared clipboard" ~166pt against 348pt
  // of room. Sharing the line made the caption wrap inside a 16pt head and lose its
  // second line, so the head STACKS: caption on its own full-width line, then the
  // affordance with its pasteboard warning right-aligned beneath it. The warning
  // stays on the affordance, which is what B5 asks for.
  const cap = makeText(null, {
    name: "caption", chars: "EXACT REQUEST — NOTHING IS TRUNCATED", size: 10,
    style: "Semi Bold", color: cw(scheme, "text-secondary"), wrap: w - 24,
  });
  const copy = makeText(null, {
    name: "copy", chars: "Copy", size: 11, style: "Semi Bold",
    color: cw(scheme, "accent-text"), align: "RIGHT", wrap: w - 24,
  });
  const warn = makeText(null, {
    name: "warn", chars: "lands on the shared clipboard", size: 9,
    color: cw(scheme, "text-tertiary"), align: "RIGHT", wrap: w - 24,
  });
  const copyRow = makeFrame(null, {
    name: "copy-row", w: w - 24, h: 16, fill: cw(scheme, "surface-sunken"),
  });
  flow(copyRow, [
    { node: copy, w: w - 24, h: copy.height },
    { node: warn, w: w - 24, h: warn.height },
  ], { direction: "VERTICAL", gap: 1, hugW: false, fixedW: w - 24 });

  const head = makeFrame(null, { name: "head", w: w - 24, h: 16, fill: cw(scheme, "surface-sunken") });
  flow(head, [
    { node: cap, w: w - 24, h: cap.height },
    { node: copyRow, w: w - 24, h: copyRow.height },
  ], { direction: "VERTICAL", gap: 4, hugW: false, fixedW: w - 24 });

  const items = [{ node: head, w: head.width, h: head.height }, { node: body }];
  flow(f, items, {
    direction: "VERTICAL", gap: 6, padLeft: 12, padRight: 12, padTop: 8, padBottom: 8,
    hugW: false, fixedW: w,
  });
  return { node: f, w: w, h: f.height };
}

// ------------------------------------------------------------------- the page
