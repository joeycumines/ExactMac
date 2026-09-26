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
  // NO CHROME. This began as an outlined pill and it read as a heavy lozenge floating
  // at the end of every process row: two borders, two fills and two radii competing
  // with the row's own text for attention, on the one surface where the operator is
  // trying to read a process TREE. The signature state is an annotation on a list row,
  // not a chip, so it is a dot and a word. It stays a component because the
  // implementation cites it by name, and a component is not required to be a box.
  const c = makeComponent(null, {
    name: "SignatureBadge/" + s.key,
    w: bw, h: 20, fill: [], radius: 0,
  });
  // A dot plus the word: color alone never carries the state, so the badge still
  // reads correctly in grayscale or for a colorblind operator.
  const dot = makeRect(c, { name: "dot", w: 6, h: 6, fill: ink(scheme, tone), radius: 3 });
  // The word is wrapped into the pill rather than sized to fit: 30pt of the badge is
  // chrome (dot, gap, padding), and at the larger no-wrap margin "Unnotarized"
  // measured 105pt inside a 96pt pill and was cut.
  // The label is PRIMARY ink in every state. Six badges ringing a prompt in six
  // semantic colours read as a highlighter set; the words already say which state
  // this is, so the dot carries the colour and the text stays quiet.
  const label = makeText(c, {
    name: "label", chars: s.label, size: 11,
    color: ink(scheme, "text-secondary"), wrap: Math.max(24, bw - 30),
  });
  flow(c, [{ node: dot }, { node: label }], {
    direction: "HORIZONTAL", gap: 6, padLeft: 0, padRight: 0, padTop: 3, padBottom: 3,
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
  // The label is WRAPPED into a budget computed from the actual sibling widths, not
  // sized to fit: with the larger no-wrap margin a long label measured 296pt inside
  // a 500pt row and pushed the role off the end. Over-allocating a no-wrap box is
  // free; under-allocating clips, and the gate caught it.
  const badgeW = p.signature
    ? (p.sigW || (SIGNATURE_STATES.find((x) => x.key === p.signature.key) || { w: 100 }).w)
    : 0;
  const roleW = p.isRequester && !p.compact ? 92 : 0;
  const chrome = padLeft + 8 + (p.depth > 0 ? 1 + 6 : 0) + 3 + 6 +
    (badgeW ? badgeW + 6 : 0) + (roleW ? roleW + 6 : 0);
  const label = makeText(row, {
    name: "label",
    chars: (p.compact
      ? p.name + (p.detail ? "   " + p.detail : "") + compactRole
      : p.name + "   pid " + p.pid + (p.detail ? "   " + p.detail : "")),
    size: 12, style: p.isRequester ? "Semi Bold" : "Regular",
    color: p.isRequester ? ink(scheme, "text-primary") : ink(scheme, "text-secondary"),
    wrap: Math.max(90, w - chrome),
  });
  items.push({ node: label });
  // Signature state travels with the row. Without it the prompt showed a process
  // tree carrying no evidence of who was calling, which is a process list rather
  // than the graded-evidence model the rest of the design depends on.
  if (p.signature) {
    const badge = signatureBadge({ state: p.signature, scheme, w: p.sigW });
    items.push({ node: badge.node, w: badge.w, h: badge.h });
  }
  if (p.isRequester && !p.compact) {
    const role = makeText(null, {
      name: "role", chars: "requesting", size: 11, style: "Semi Bold",
      color: ink(scheme, "accent"), wrap: 92,
    });
    items.push({ node: role });
  }
  flow(row, items, {
    direction: "HORIZONTAL", gap: 6, padLeft: padLeft, padRight: 8, padTop: 6, padBottom: 6,
    align: "CENTER", hugW: false, fixedW: w,
  });
  // Height follows the content: a label that wraps to two lines needs ~41pt, and
  // pinning the row to 30 clipped the badge and the second line of the label.
  return { node: row, w: w, h: row.height };
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
  // The amber RULE is the mark, and it is one hairline rather than a coloured band.
  // The caption is primary ink: "NOT VERIFIED" in amber shouted the warning twice.
  const caption = makeText(null, {
    name: "caption", chars: o.caption || "FROM THE CALLER — NOT VERIFIED",
    size: 10, style: "Semi Bold", color: ink(scheme, "text-primary"),
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
  caution:  { fill: "surface-raised", ink: "text-primary", h: 34, w: 190, style: "Semi Bold", stroke: "control-border" },
};

function button(o) {
  const scheme = o.scheme || "light";
  const v = BUTTON_VARIANTS[o.variant];
  const chars = o.label || o.variant;
  // A variant's width is a DEFAULT, not a constraint. It used to be the width, so a
  // label wider than its button wrapped inside a fixed-height button and overflowed it
  // — which is how "Reset ExactMac" came to sit 4pt proud of a 34pt Deny. The button
  // now grows to its label instead, and every existing caller's label already fits, so
  // no committed width changes.
  const w = Math.max(v.w, Math.ceil(measure(chars, 13, v.style, false)) + 8 + 16);
  const b = makeComponent(null, {
    name: "Button/" + o.variant,
    w: w, h: v.h,
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
  const inner = w - 16;
  const label = makeText(null, {
    name: "label", chars: chars, size: 13, style: v.style,
    color: cw(scheme, v.fill === "accent" ? "on-accent" : v.ink),
    align: "CENTER", wrap: inner,
  });
  flow(b, [{ node: label, w: inner, h: label.height }], {
    direction: "HORIZONTAL", padLeft: 8, padRight: 8, align: "CENTER",
    hugW: false, hugH: false, fixedW: w, fixedH: v.h,
  });
  b.resize(w, v.h);
  return { node: b, w: w, h: v.h };
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
    stroke: cw(scheme, "control-border"),
  });
  const dot = makeRect(null, { name: "dot", w: 6, h: 6, fill: cw(scheme, lv.tone), radius: 3 });
  const label = makeText(null, {
    name: "label", chars: lv.label, size: 11, style: "Semi Bold", color: cw(scheme, "text-primary"),
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

// --------------------------------------------------- the console's own vocabulary
//
// Everything below exists for the console surfaces in console.js: the menu-bar
// item, its popover, the grants manager, the activity timeline, settings, and the
// states where the system fails closed. Each family is a real component here, so the
// surfaces compose rather than draw ad-hoc shapes.

// SERVICE STATES. The menu-bar item's job is legibility: a denied request must read
// as protection rather than as a fault, and a server that has stopped enforcing must
// be VISIBLE rather than silent. Colour never carries the state alone — every pill
// has a word in it — because the item is 22pt tall and greyscale is real.
//
// `unreachable` is caution, not danger. Something is wrong, but the system is doing
// the safe thing, and red is reserved for a denied or high-risk request.
const SERVICE_STATES = [
  { key: "running",     label: "Running",    tone: "success" },
  { key: "degraded",    label: "Degraded",   tone: "caution" },
  { key: "reduced",     label: "Reduced",    tone: "caution" },
  { key: "stopped",     label: "Stopped",    tone: "text-secondary" },
  { key: "unreachable", label: "No console", tone: "caution" },
];

function serviceStatus(o) {
  const scheme = o.scheme || "light";
  const s = SERVICE_STATES.find((x) => x.key === o.state) || SERVICE_STATES[0];
  // Snug: the pill is sized to its word rather than given a fixed width, because a
  // fixed width either clips "Degraded" or leaves "Running" floating in space.
  const w = o.w || Math.ceil(measure(s.label, 11, "Semi Bold", true)) + 32;
  const c = makeComponent(null, {
    name: "ServiceStatus/" + s.key, w: w, h: 20,
    fill: cw(scheme, "surface-raised"), radius: CR["radius-pill"],
    stroke: cw(scheme, "control-border"),
  });
  const dot = makeRect(null, { name: "dot", w: 6, h: 6, fill: cw(scheme, s.tone), radius: 3 });
  const label = makeText(null, {
    name: "label", chars: s.label, size: 11, style: "Semi Bold",
    color: cw(scheme, "text-primary"), wrap: w - 30,
  });
  flow(c, [{ node: dot }, { node: label }], {
    direction: "HORIZONTAL", gap: 6, padLeft: 10, padRight: 10, padTop: 3, padBottom: 3,
    align: "CENTER", hugW: false, fixedW: w,
  });
  return { node: c, w: w, h: c.height };
}

// The item itself is icon-only and 22pt, so the only thing that has to survive at
// that size is the state. The app substitutes an SF Symbol at build time; the
// specimen proves the slot and the state dot, and the popover names the state in
// words for the cases a dot cannot distinguish.
function menuBarItem(o) {
  const scheme = o.scheme || "light";
  const s = SERVICE_STATES.find((x) => x.key === o.state) || SERVICE_STATES[0];
  const item = makeComponent(null, {
    name: "MenuBarItem/" + s.key, w: 22, h: 22, fill: cw(scheme, "surface"), clips: false,
  });
  const ring = makeRect(null, {
    name: "ring", w: 14, h: 14, fill: cw(scheme, "surface"), stroke: cw(scheme, "control-border"), radius: 7,
  });
  const dot = makeRect(null, { name: "dot", w: 6, h: 6, fill: cw(scheme, s.tone), radius: 3 });
  flow(ring, [{ node: dot }], {
    direction: "HORIZONTAL", align: "CENTER", mainAlign: "CENTER",
    hugW: false, hugH: false, fixedW: 14, fixedH: 14,
  });
  ring.resize(14, 14);
  flow(item, [{ node: ring, w: 14, h: 14 }], {
    direction: "HORIZONTAL", align: "CENTER", mainAlign: "CENTER",
    hugW: false, hugH: false, fixedW: 22, fixedH: 22,
  });
  item.resize(22, 22);
  return { node: item, w: 22, h: 22 };
}

// A row in the popover's list. Detail is optional and right-aligned, so the widths
// are computed rather than guessed: a guessed right column pushed the title's wrap
// box past its own row.
function menuItem(o) {
  const scheme = o.scheme || "light";
  const w = o.w || 320;
  const destructive = o.variant === "destructive";
  const disabled = o.variant === "disabled";
  const row = makeComponent(null, {
    name: "MenuItem/" + (o.variant || "default"), w: w, h: 28,
    fill: cw(scheme, "surface"), radius: CR["radius-sm"],
  });
  const detailW = o.detail ? Math.ceil(measure(o.detail, 11, "Regular", false)) : 0;
  const title = makeText(null, {
    name: "title", chars: o.title, size: 13,
    style: destructive ? "Semi Bold" : "Regular",
    color: cw(scheme, destructive ? "danger" : disabled ? "text-tertiary" : "text-primary"),
    wrap: w - 20 - (detailW ? detailW + 10 : 0),
  });
  const items = [{ node: title }];
  if (o.detail) {
    items.push({
      node: makeText(null, {
        name: "detail", chars: o.detail, size: 11, color: cw(scheme, "text-tertiary"),
        align: "RIGHT", wrap: detailW,
      }),
      w: detailW,
    });
  }
  flow(row, items, {
    direction: "HORIZONTAL", gap: 10, padLeft: 10, padRight: 10, padTop: 5, padBottom: 5,
    align: "CENTER", hugW: false, fixedW: w,
  });
  return { node: row, w: w, h: row.height };
}

// B1's persistent control. The state survives restarts because it is written through
// launchd's own enable/disable, and the row says so, because an operator who thinks
// a toggle is a preference will not trust it.
function serviceToggle(o) {
  const scheme = o.scheme || "light";
  const w = o.w || 328;
  const on = o.state !== "off";
  const row = makeComponent(null, {
    name: "ServiceToggle/" + (on ? "on" : "off"), w: w, h: 56,
    fill: cw(scheme, "surface"), radius: CR["radius-md"], stroke: cw(scheme, "separator"),
  });
  const trackW = 38, trackH = 22;
  const stackW = w - 24 - trackW - 12;
  const title = makeText(null, {
    name: "title", chars: "ExactMac service", size: 13, style: "Semi Bold",
    color: cw(scheme, "text-primary"), wrap: stackW,
  });
  const desc = makeText(null, {
    name: "desc", size: 11, color: cw(scheme, "text-secondary"), wrap: stackW,
    // `note` overrides the default sentence, because the default is a claim about the
    // transport and the service's reachability, and a state that contradicts it — a
    // TCP listener, or an enabled service that is not answering — must not assert it.
    chars: o.note || (on
      ? "Running on a launchd socket. This survives a restart."
      : "Stopped and disabled. It will not come back on its own."),
  });
  const stack = makeFrame(null, { name: "stack", w: stackW, h: 34, fill: cw(scheme, "surface") });
  flow(stack, [{ node: title }, { node: desc }], { direction: "VERTICAL", gap: 2, fixedW: stackW });

  const track = makeComponent(null, {
    name: "track", w: trackW, h: trackH, fill: cw(scheme, on ? "accent" : "surface-sunken"),
    radius: CR["radius-pill"], stroke: on ? undefined : cw(scheme, "control-border"),
  });
  const knob = makeRect(null, {
    name: "knob", w: 18, h: 18, fill: cw(scheme, on ? "on-accent" : "control-border"), radius: 9,
  });
  flow(track, [{ node: knob }], {
    direction: "HORIZONTAL", padLeft: 2, padRight: 2, align: "CENTER",
    mainAlign: on ? "MAX" : "MIN", hugW: false, hugH: false, fixedW: trackW, fixedH: trackH,
  });
  track.resize(trackW, trackH);

  flow(row, [{ node: stack, w: stackW, h: stack.height }, { node: track, w: trackW, h: trackH }], {
    direction: "HORIZONTAL", gap: 12, padLeft: 12, padRight: 12, padTop: 12, padBottom: 12,
    align: "CENTER", hugW: false, fixedW: w,
  });
  return { node: row, w: w, h: row.height };
}

// THE FAIL-CLOSED BAND. Every state in which the system denies has to say so in
// words, because the operator's default reading of a stopped service is "something
// is broken", and the operator needs to read it instead as "nothing is being
// automated, and here is why". Amber rather than red — red is reserved for a denied
// or high-risk request — and every body names the safe direction, because that is
// what makes the state reassuring rather than alarming.
const FAIL_CLOSED = {
  "console-unreachable": {
    title: "Denied until the console is available",
    body: "ExactMac could not reach the consent service, so every request that needs consent was denied. Nothing ran and no grant was created. This is the safe direction.",
  },
  "server-unreachable": {
    title: "The service is not answering",
    body: "The console cannot reach ExactMac, so no request can be made or answered. Nothing on this Mac is being automated while it is down.",
  },
  "tcp-reduced": {
    title: "Running without approvals",
    body: "This server is listening on TCP, where there is no owning user to authenticate. Process verification and approvals are unavailable, so every consent-requiring capability is denied.",
  },
  stopped: {
    title: "The service is off",
    body: "You turned ExactMac off. Nothing is served and nothing is exposed until you turn it back on.",
  },
  "grants-unreadable": {
    title: "Grants could not be read",
    body: "The grant store did not open, so ExactMac cannot tell what is permitted and denies everything that needs consent. A store it cannot read fails closed rather than open.",
  },
};

function failClosedBand(o) {
  const scheme = o.scheme || "light";
  const w = o.w || 328;
  const spec = FAIL_CLOSED[o.reason] || FAIL_CLOSED.stopped;
  const band = makeComponent(null, {
    name: "FailClosedBand/" + o.reason, w: w, h: 56,
    fill: cw(scheme, "surface-sunken"), radius: CR["radius-sm"],
  });
  // NEUTRAL rule. An amber bar down the side of the state that means "you are
  // protected" told the operator the opposite, and this surface's acceptance asks it
  // to be reassuring. The words carry it; the rule only separates.
  const rule = makeRect(band, { name: "rule", w: 3, h: 40, fill: cw(scheme, "control-border"), radius: 1.5 });
  const stackW = w - 13 - 10 - 10;
  const title = makeText(null, {
    name: "title", chars: o.title || spec.title, size: 12, style: "Semi Bold",
    color: cw(scheme, "text-primary"), wrap: stackW,
  });
  const body = makeText(null, {
    name: "body", chars: o.body || spec.body, size: 11,
    color: cw(scheme, "text-secondary"), wrap: stackW,
  });
  const stack = makeFrame(null, { name: "stack", w: stackW, h: 40, fill: cw(scheme, "surface-sunken") });
  flow(stack, [{ node: title }, { node: body }], { direction: "VERTICAL", gap: 3, fixedW: stackW });
  flow(band, [
    { node: rule, w: 3, h: 40 },
    { node: stack, w: stackW, h: stack.height },
  ], {
    direction: "HORIZONTAL", gap: 10, padLeft: 0, padRight: 10, padTop: 8, padBottom: 8,
    align: "CENTER", hugW: false, fixedW: w,
  });
  return { node: band, w: w, h: band.height };
}

// A pending request is not a fault, so it gets an accent rule rather than amber. The
// count is in the title, because "a request is waiting" without a number is the same
// uselessness as a badge without a count.
function pendingNotice(o) {
  const scheme = o.scheme || "light";
  const w = o.w || 328;
  const n = o.count || 1;
  const box = makeComponent(null, {
    name: "PendingNotice/" + (n === 1 ? "one" : "several"), w: w, h: 56,
    fill: cw(scheme, "surface"), radius: CR["radius-md"], stroke: cw(scheme, "accent"),
  });
  const title = makeText(null, {
    name: "title", chars: n === 1 ? "1 request waiting for you" : n + " requests waiting for you",
    size: 13, style: "Semi Bold", color: cw(scheme, "accent-text"), wrap: w - 24,
  });
  const body = makeText(null, {
    name: "body", chars: o.body || "exactmac-mcp wants to read the clipboard in TextEdit",
    size: 11, color: cw(scheme, "text-secondary"), wrap: w - 24,
  });
  flow(box, [{ node: title }, { node: body }], {
    direction: "VERTICAL", gap: 3, padLeft: 12, padRight: 12, padTop: 10, padBottom: 10,
    hugW: false, fixedW: w,
  });
  return { node: box, w: w, h: box.height };
}

// A grant's remaining life, stated on the row. A live countdown is ordinary text, a
// grant about to lapse is amber, and an expired one is quiet rather than red: it is
// inert, not dangerous, and the row says so.
const COUNTDOWN_TONES = { live: "text-secondary", soon: "caution", expired: "text-tertiary" };

function countdownChip(o) {
  const scheme = o.scheme || "light";
  const tone = COUNTDOWN_TONES[o.state || "live"];
  const label = o.label || "3m 12s";
  const w = Math.ceil(measure(label, 11, "Semi Bold", true)) + 20;
  const c = makeComponent(null, {
    name: "CountdownChip/" + (o.state || "live"), w: w, h: 18,
    fill: cw(scheme, "surface"), radius: CR["radius-pill"], stroke: cw(scheme, "control-border"),
  });
  // Only a grant about to lapse earns a colour, and it earns one dot rather than a
  // coloured pill: a countdown is a clock, not a warning.
  const text = makeText(null, {
    name: "label", chars: label, size: 11, style: "Semi Bold",
    color: cw(scheme, "text-primary"), wrap: w - 25,
  });
  flow(c, [
    { node: makeRect(null, { name: "dot", w: 5, h: 5, fill: cw(scheme, tone), radius: 2.5 }), w: 5, h: 5 },
    { node: text },
  ], {
    direction: "HORIZONTAL", gap: 6, padLeft: 8, padRight: 8, align: "CENTER",
    hugW: false, fixedW: w,
  });
  return { node: c, w: w, h: c.height };
}

// A grant the operator can see is a grant they can revoke, so the row states
// CONSEQUENCE, full scope, who holds it, where it came from, and how long is left.
function grantRow(o) {
  const scheme = o.scheme || "light";
  const w = o.w || 548;
  const rightW = 124;
  const stackW = w - 24 - 12 - rightW;
  const expired = o.variant === "expired";
  const row = makeComponent(null, {
    name: "GrantRow/" + (o.variant || "normal"), w: w, h: 96,
    fill: cw(scheme, "surface-raised"), radius: CR["radius-md"],
    stroke: cw(scheme, expired ? "separator" : "separator"),
  });
  const title = makeText(null, {
    name: "title", chars: o.consequence, size: 13, style: "Semi Bold",
    color: cw(scheme, "text-primary"), wrap: stackW,
  });
  const scope = makeText(null, {
    name: "scope", size: 11, color: cw(scheme, "text-secondary"), wrap: stackW,
    chars: o.capability + "  ·  " + o.breadth + "  ·  " + o.duration,
  });
  const sig = signatureBadge({ state: o.signature, scheme });
  const holder = makeText(null, {
    name: "holder", chars: o.holder, size: 11, color: cw(scheme, "text-primary"),
    wrap: Math.max(60, stackW - sig.w - 8),
  });
  const holderRow = makeFrame(null, { name: "holder-row", w: stackW, h: 20, fill: cw(scheme, "surface-raised") });
  flow(holderRow, [
    { node: holder, w: Math.max(60, stackW - sig.w - 8), h: holder.height },
    { node: sig.node, w: sig.w, h: sig.h },
  ], { direction: "HORIZONTAL", gap: 8, align: "CENTER", hugW: false, fixedW: stackW });
  const origin = makeText(null, {
    name: "origin", size: 10, color: cw(scheme, "text-tertiary"), wrap: stackW,
    chars: "Origin: " + o.origin + "  ·  " + o.grantedAgo,
  });
  const stack = makeFrame(null, { name: "stack", w: stackW, h: 60, fill: cw(scheme, "surface-raised") });
  flow(stack, [
    { node: title, w: stackW, h: title.height },
    { node: scope, w: stackW, h: scope.height },
    { node: holderRow, w: stackW, h: holderRow.height },
    { node: origin, w: stackW, h: origin.height },
  ], { direction: "VERTICAL", gap: 3, fixedW: stackW });

  const chip = countdownChip({
    scheme, state: expired ? "expired" : (o.expiring ? "soon" : "live"),
    label: expired ? "expired" : (o.countdown || "3m 12s"),
  });
  const revoke = button({ variant: "quiet", scheme, label: "Revoke" });
  const right = makeFrame(null, { name: "right", w: rightW, h: 50, fill: cw(scheme, "surface-raised") });
  flow(right, [
    { node: chip.node, w: chip.w, h: chip.h },
    { node: revoke.node, w: revoke.w, h: revoke.h },
  ], { direction: "VERTICAL", gap: 8, align: "MAX", fixedW: rightW });

  flow(row, [
    { node: stack, w: stackW, h: stack.height },
    { node: right, w: rightW, h: right.height },
  ], {
    direction: "HORIZONTAL", gap: 12, padLeft: 12, padRight: 12, padTop: 12, padBottom: 12,
    align: "MIN", hugW: false, fixedW: w,
  });
  return { node: row, w: w, h: row.height };
}

// One decision, as the audit recorded it. The decision word is in the ink as well as
// the dot, and the agent's reason is drawn with the UNTRUSTED treatment, because it
// is caller-supplied text and this surface shows it beside system-derived fact.
function activityRow(o) {
  const scheme = o.scheme || "light";
  const w = o.w || 548;
  const inner = w - 24;
  const allowed = o.decision === "allowed";
  const tone = allowed ? "success" : "danger";
  const row = makeComponent(null, {
    name: "ActivityRow/" + o.decision, w: w, h: 120,
    fill: cw(scheme, "surface"), radius: CR["radius-sm"], stroke: cw(scheme, "separator"),
  });
  const word = allowed ? "Allowed" : "Denied";
  const timeW = Math.ceil(measure(o.time, 11, "Regular", true));
  const head = makeFrame(null, { name: "head", w: inner, h: 18, fill: cw(scheme, "surface") });
  const headLeft = makeFrame(null, { name: "head-left", w: inner - timeW - 12, h: 18, fill: cw(scheme, "surface") });
  const dot = makeRect(null, { name: "dot", w: 8, h: 8, fill: cw(scheme, tone), radius: 4 });
  const wordText = makeText(null, {
    name: "word", chars: word, size: 11, style: "Semi Bold", color: cw(scheme, tone),
  });
  flow(headLeft, [{ node: dot, w: 8, h: 8 }, { node: wordText }], {
    direction: "HORIZONTAL", gap: 6, align: "CENTER", fixedW: inner - timeW - 12,
  });
  const timeText = makeText(null, {
    name: "time", chars: o.time, size: 11, color: cw(scheme, "text-tertiary"),
    align: "RIGHT", wrap: timeW,
  });
  flow(head, [
    { node: headLeft, w: inner - timeW - 12, h: 18 },
    { node: timeText, w: timeW, h: timeText.height },
  ], { direction: "HORIZONTAL", gap: 12, align: "CENTER", hugW: false, fixedW: inner });

  const consequence = makeText(null, {
    name: "consequence", chars: o.consequence, size: 13, style: "Semi Bold",
    color: cw(scheme, "text-primary"), wrap: inner,
  });
  const capability = makeText(null, {
    name: "capability", chars: o.capability, size: 11, color: cw(scheme, "text-secondary"),
    wrap: inner,
  });
  const basis = makeText(null, {
    name: "basis", chars: o.basis, size: 11, style: "Semi Bold",
    color: cw(scheme, "text-primary"), wrap: inner,
  });
  const sig = signatureBadge({ state: o.signature, scheme });
  const identity = makeText(null, {
    name: "identity", chars: o.identity, size: 11, color: cw(scheme, "text-secondary"),
    wrap: Math.max(60, inner - sig.w - 8),
  });
  const identityRow = makeFrame(null, { name: "identity-row", w: inner, h: 20, fill: cw(scheme, "surface") });
  flow(identityRow, [
    { node: identity, w: Math.max(60, inner - sig.w - 8), h: identity.height },
    { node: sig.node, w: sig.w, h: sig.h },
  ], { direction: "HORIZONTAL", gap: 8, align: "CENTER", hugW: false, fixedW: inner });

  const items = [
    { node: head, w: inner, h: head.height },
    { node: consequence, w: inner, h: consequence.height },
    { node: capability, w: inner, h: capability.height },
    { node: basis, w: inner, h: basis.height },
    { node: identityRow, w: inner, h: identityRow.height },
  ];
  if (o.reason) {
    const r = untrustedField({
      scheme, w: inner, variant: "activity",
      caption: "REASON GIVEN BY THE AGENT — NOT VERIFIED", value: o.reason,
    });
    items.push({ node: r.node, w: inner, h: r.h });
  }
  if (o.note) {
    const n = systemField({
      scheme, w: inner, variant: "activity",
      caption: "YOUR NOTE WENT BACK TO THE AGENT", value: o.note,
    });
    items.push({ node: n.node, w: inner, h: n.h });
  }
  flow(row, items, {
    direction: "VERTICAL", gap: 4, padLeft: 12, padRight: 12, padTop: 10, padBottom: 10,
    hugW: false, fixedW: w,
  });
  return { node: row, w: w, h: row.height };
}

// The log is readable by any same-uid process, so the timeline states the chain's
// integrity rather than presenting whatever bytes it is handed as trustworthy.
const INTEGRITY_STATES = {
  verified:   { label: "Chain verified",   tone: "success" },
  broken:     { label: "Chain broken",     tone: "danger" },
  unchecked:  { label: "Not verified",     tone: "text-secondary" },
};

function integrityBadge(o) {
  const scheme = o.scheme || "light";
  const s = INTEGRITY_STATES[o.state || "verified"];
  const label = o.label || s.label;
  const w = Math.ceil(measure(label, 11, "Semi Bold", true)) + 32;
  const c = makeComponent(null, {
    name: "IntegrityBadge/" + (o.state || "verified"), w: w, h: 20,
    fill: cw(scheme, "surface-raised"), radius: CR["radius-pill"],
    stroke: cw(scheme, "control-border"),
  });
  const dot = makeRect(null, { name: "dot", w: 6, h: 6, fill: cw(scheme, s.tone), radius: 3 });
  // A doctored log is the one place in the console where red is the honest colour,
  // so the word is red there and nowhere else.
  const text = makeText(null, {
    name: "label", chars: label, size: 11, style: "Semi Bold",
    color: cw(scheme, o.state === "broken" ? "danger" : "text-primary"), wrap: w - 30,
  });
  flow(c, [{ node: dot }, { node: text }], {
    direction: "HORIZONTAL", gap: 6, padLeft: 10, padRight: 10, padTop: 3, padBottom: 3,
    align: "CENTER", hugW: false, fixedW: w,
  });
  return { node: c, w: w, h: c.height };
}

// Posture. Three, and no permissive one: a posture that widens what may happen
// without asking is the vulnerability this product exists to remove, and `locked` is
// the fail-closed direction rather than an `open` one.
const POSTURES = [
  {
    key: "strict", title: "Ask every time",
    desc: "Grants and envelopes are ignored. Every request that needs consent prompts, and nothing is remembered.",
  },
  {
    key: "balanced", title: "Balanced",
    desc: "The default. Friction scales with what a grant would actually permit, so a narrow one asks nothing and a broad one asks for a biometric.",
  },
  {
    key: "locked", title: "Locked down",
    desc: "Every consent-requiring capability is denied without prompting. Nothing can be granted, so nothing can be replayed.",
  },
];

function segmentedControl(o) {
  const scheme = o.scheme || "light";
  // SIZED TO ITS CONTENT, and split into UNEQUAL segments. It used to take the full
  // 664pt content width and divide it three ways, which stretched three short labels
  // across the whole panel: the selected chip floated in the middle of a long grey bar
  // and read as a text field with a box in it rather than as a control.
  //
  // No blue either. The selected segment is a raised chip with PRIMARY ink and a
  // neutral border. Three signals at once — blue outline, blue text, white fill — was
  // the reason it looked wonky, and the same rule that quieted the signature badges
  // applies here: colour in the ink only where it carries meaning, chrome neutral.
  const segs = POSTURES.map((p) => Math.max(
    88, Math.ceil(measure(p.title, 11, "Semi Bold", true)) + 30,
  ));
  const w = o.w || segs.reduce((a, b) => a + b, 0) + 6;
  const box = makeComponent(null, {
    name: "SegmentedControl/" + o.selected, w: w, h: 32,
    fill: cw(scheme, "surface-sunken"), radius: CR["radius-md"],
  });
  const opts = POSTURES.map((p, i) => {
    const optW = segs[i];
    const sel = p.key === o.selected;
    const c = makeComponent(null, {
      name: "SegmentedOption/" + p.key, w: optW, h: 26,
      fill: cw(scheme, sel ? "surface" : "surface-sunken"), radius: CR["radius-sm"],
      stroke: sel ? cw(scheme, "control-border") : undefined,
    });
    const label = makeText(null, {
      name: "label", chars: p.title, size: 11, style: sel ? "Semi Bold" : "Regular",
      color: cw(scheme, sel ? "text-primary" : "text-secondary"), align: "CENTER",
      wrap: optW - 16,
    });
    flow(c, [{ node: label, w: optW - 16, h: label.height }], {
      direction: "HORIZONTAL", padLeft: 8, padRight: 8, align: "CENTER", mainAlign: "CENTER",
      hugW: false, hugH: false, fixedW: optW, fixedH: 26,
    });
    c.resize(optW, 26);
    return { node: c, w: optW, h: 26 };
  });
  flow(box, opts, { direction: "HORIZONTAL", gap: 0, padLeft: 3, padRight: 3, align: "CENTER" });
  box.resize(w, 32);
  return { node: box, w: w, h: 32 };
}

// Consequence is a fact about the operator's life, so the target list is theirs to
// name. A listed target escalates: it always requires a biometric whatever its
// breadth, which is why the chip carries a caution dot.
function targetChip(o) {
  const scheme = o.scheme || "light";
  const label = o.name;
  const w = Math.ceil(measure(label, 11, "Semi Bold", true)) + (o.listed ? 40 : 24);
  const c = makeComponent(null, {
    name: "TargetChip/" + (o.listed ? "listed" : "placeholder"), w: w, h: 24,
    fill: cw(scheme, o.listed ? "surface-raised" : "surface"), radius: CR["radius-pill"],
    stroke: cw(scheme, o.listed ? "control-border" : "separator"),
  });
  // No dot. The row's own title already says these applications always escalate, so
  // a dot on every chip repeated the point in colour and added nothing.
  const text = makeText(null, {
    name: "label", chars: label, size: 11, style: o.listed ? "Semi Bold" : "Regular",
    color: cw(scheme, o.listed ? "text-primary" : "text-tertiary"), wrap: w - 24,
  });
  flow(c, [{ node: text }], {
    direction: "HORIZONTAL", padLeft: 12, padRight: 12, padTop: 4, padBottom: 4,
    align: "CENTER", hugW: false, fixedW: w,
  });
  return { node: c, w: w, h: c.height };
}

// A settings row. `locked` is not decoration: the biometric requirements that cannot
// be switched off are exactly the ones whose absence would be the vulnerability, and
// a row that merely looked off would invite someone to switch it off.
function settingRow(o) {
  const scheme = o.scheme || "light";
  const w = o.w || 664;
  const inner = w - 24;
  const destructive = o.variant === "destructive";
  const trackW = 38, trackH = 22;
  const on = !!o.on;
  const titleW = destructive || o.variant === "targets" || o.variant === "choice"
    ? inner : inner - trackW - 12;
  const row = makeComponent(null, {
    name: "SettingRow/" + o.variant, w: w, h: 56,
    fill: cw(scheme, "surface"), radius: CR["radius-md"], stroke: cw(scheme, "separator"),
  });
  const items = [];
  if (o.variant === "toggle") {
    const title = makeText(null, {
      name: "title", chars: o.title, size: 13, style: "Semi Bold",
      color: cw(scheme, "text-primary"), wrap: titleW,
    });
    const head = makeFrame(null, { name: "head", w: inner, h: 20, fill: cw(scheme, "surface") });
    const track = makeComponent(null, {
      name: "track", w: trackW, h: trackH, fill: cw(scheme, on ? "accent" : "surface-sunken"),
      radius: CR["radius-pill"], stroke: on ? undefined : cw(scheme, "control-border"),
    });
    const knob = makeRect(null, {
      name: "knob", w: 18, h: 18, fill: cw(scheme, on ? "on-accent" : "control-border"), radius: 9,
    });
    flow(track, [{ node: knob }], {
      direction: "HORIZONTAL", padLeft: 2, padRight: 2, align: "CENTER",
      mainAlign: on ? "MAX" : "MIN", hugW: false, hugH: false, fixedW: trackW, fixedH: trackH,
    });
    track.resize(trackW, trackH);
    flow(head, [
      { node: title, w: titleW, h: title.height },
      { node: track, w: trackW, h: trackH },
    ], { direction: "HORIZONTAL", gap: 12, align: "CENTER", hugW: false, fixedW: inner });
    items.push({ node: head, w: inner, h: head.height });
  } else {
    const title = makeText(null, {
      name: "title", chars: o.title, size: 13, style: "Semi Bold",
      color: cw(scheme, destructive ? "danger" : "text-primary"), wrap: inner,
    });
    items.push({ node: title, w: inner, h: title.height });
  }
  items.push({
    node: makeText(null, {
      name: "desc", chars: o.desc, size: 11, color: cw(scheme, "text-secondary"), wrap: inner,
    }),
    w: inner,
  });
  if (o.locked) {
    items.push({
      node: makeText(null, {
        name: "locked-note", chars: "Required — this cannot be turned off",
        size: 10, style: "Semi Bold", color: cw(scheme, "text-secondary"), wrap: inner,
      }),
      w: inner,
    });
  }
  if (o.value) {
    items.push({
      node: makeText(null, {
        name: "value", chars: o.value, size: 12, style: "Semi Bold",
        color: cw(scheme, "accent-text"), wrap: inner,
      }),
      w: inner,
    });
  }
  if (o.targets) {
    const chips = makeFrame(null, { name: "chips", w: inner, h: 24, fill: cw(scheme, "surface") });
    flow(chips, o.targets.map((t) => targetChip({ scheme, name: t.name, listed: t.listed })), {
      direction: "HORIZONTAL", gap: 8, align: "CENTER", hugW: false, fixedW: inner,
    });
    items.push({ node: chips, w: inner, h: chips.height });
  }
  if (o.action) {
    const b = button({ variant: o.action.variant, scheme, label: o.action.label });
    items.push({ node: b.node, w: b.w, h: b.h });
  }
  flow(row, items, {
    direction: "VERTICAL", gap: 4, padLeft: 12, padRight: 12, padTop: 10, padBottom: 10,
    hugW: false, fixedW: w,
  });
  return { node: row, w: w, h: row.height };
}

// Empty, loading and error are designed, not left to the implementation. A surface
// that has no empty state shows a blank panel when there is nothing to show, which
// reads as a fault.
function emptyState(o) {
  const scheme = o.scheme || "light";
  const w = o.w || 664;
  const inner = w - 48;
  const box = makeComponent(null, {
    name: "EmptyState/" + o.surface, w: w, h: 96,
    fill: cw(scheme, "surface"), radius: CR["radius-md"], stroke: cw(scheme, "separator"),
  });
  const title = makeText(null, {
    name: "title", chars: o.title, size: 15, style: "Semi Bold", align: "CENTER",
    color: cw(scheme, "text-primary"), wrap: inner,
  });
  const body = makeText(null, {
    name: "body", chars: o.body, size: 12, align: "CENTER",
    color: cw(scheme, "text-secondary"), wrap: inner,
  });
  flow(box, [{ node: title, w: inner, h: title.height }, { node: body, w: inner, h: body.height }], {
    direction: "VERTICAL", gap: 6, padLeft: 24, padRight: 24, padTop: 24, padBottom: 24,
    align: "CENTER", hugW: false, fixedW: w,
  });
  return { node: box, w: w, h: box.height };
}

function loadingSkeleton(o) {
  const scheme = o.scheme || "light";
  const w = o.w || 664;
  const inner = w - 24;
  const n = o.rows || 3;
  const widths = [1, 0.62, 0.84, 0.45];
  const box = makeComponent(null, {
    name: "LoadingSkeleton/" + n + "rows", w: w, h: 96,
    fill: cw(scheme, "surface-raised"), radius: CR["radius-md"], stroke: cw(scheme, "separator"),
  });
  const bars = [];
  for (let i = 0; i < n; i++) {
    bars.push({
      node: makeRect(null, {
        name: "bar", w: Math.round(inner * widths[i % widths.length]), h: 10,
        fill: cw(scheme, "separator"), radius: 5,
      }),
    });
  }
  flow(box, bars, { direction: "VERTICAL", gap: 10, padLeft: 12, padRight: 12, padTop: 14, padBottom: 14 });
  return { node: box, w: w, h: box.height };
}

// A surface whose data could not be trusted or read. Amber, not red, and it always
// says what the system does about it — which for a grant store is deny, because an
// unreadable store must never be treated as an empty one.
const ERROR_STATES = {
  grants: {
    title: "Grants could not be read",
    body: "ExactMac cannot tell what is permitted, so it is denying every request that needs consent. Nothing is being granted on a guess.",
  },
  activity: {
    title: "Activity could not be loaded",
    body: "The decision log did not open. Decisions are still being enforced; this view is missing, not the protection.",
  },
  audit: {
    title: "The log has been altered",
    body: "An entry does not match the hash recorded for it, so everything after it cannot be trusted. Grants are still enforced — but this log is not evidence of what happened.",
  },
  server: {
    title: "The service is not answering",
    body: "Nothing can be requested or decided while the server is down. This is the safe direction.",
  },
};

function errorState(o) {
  const scheme = o.scheme || "light";
  const w = o.w || 664;
  const spec = ERROR_STATES[o.what] || ERROR_STATES.server;
  const box = makeComponent(null, {
    name: "ErrorState/" + o.what, w: w, h: 80,
    fill: cw(scheme, "surface-sunken"), radius: CR["radius-md"],
  });
  const stackW = w - 13 - 10 - 10;
  const title = makeText(null, {
    name: "title", chars: o.title || spec.title, size: 13, style: "Semi Bold",
    color: cw(scheme, "text-primary"), wrap: stackW,
  });
  const body = makeText(null, {
    name: "body", chars: o.body || spec.body, size: 11,
    color: cw(scheme, "text-secondary"), wrap: stackW,
  });
  const stack = makeFrame(null, { name: "stack", w: stackW, h: 40, fill: cw(scheme, "surface-sunken") });
  flow(stack, [{ node: title }, { node: body }], { direction: "VERTICAL", gap: 3, fixedW: stackW });
  // The rule and the text share a line; the ACTION does not. It used to, and a 110pt
  // button beside a full-width message pushed the row 100pt past its own container.
  const head = makeFrame(null, { name: "head", w: stackW + 13, h: 40, fill: cw(scheme, "surface-sunken") });
  flow(head, [
    { node: makeRect(null, { name: "rule", w: 3, h: 40, fill: cw(scheme, "control-border"), radius: 1.5 }), w: 3, h: 40 },
    { node: stack, w: stackW, h: stack.height },
  ], { direction: "HORIZONTAL", gap: 10, align: "CENTER", hugW: false, fixedW: stackW + 13 });
  const items = [{ node: head, w: head.width, h: head.height }];
  if (o.action) {
    const b = button({ variant: "quiet", scheme, label: o.action });
    items.push({ node: b.node, w: b.w, h: b.h });
  }
  flow(box, items, {
    direction: "VERTICAL", gap: 10, padLeft: 0, padRight: 10, padTop: 10, padBottom: 10,
    align: "MIN", hugW: false, fixedW: w,
  });
  return { node: box, w: w, h: box.height };
}

// ------------------------------------------------------------------- the page
