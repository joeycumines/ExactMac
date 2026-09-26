// Screens page: the approval prompt, in both schemes and in every state that
// matters. This is the highest-stakes surface in the product, so the design
// answers one question above all: can an operator who does not trust the agent
// still decide correctly, in a few seconds, from this window alone?
//
// The prompt is Okta/1Password-shaped and deliberately small, but it carries more
// context than those need, because a shell is not a login. Five commitments shape
// every state below:
//
//   1. The headline is the CONSEQUENCE ("Read the clipboard in TextEdit"), never
//      the capability name. "clipboard.read" is not something an operator can
//      picture; what it will take is.
//   2. The agent's REASON is above the fold, marked as caller-supplied, because an
//      unexplained request is one the operator should decline. A prompt with no
//      reason is visibly different, not silently sparser.
//   3. The grant's IMPLICATIONS are stated on their face. script.execute is not a
//      peer of clipboard.read, it subsumes it, and information the operator is
//      entitled to before agreeing cannot be buried.
//   4. Nothing is truncated. A long command wraps; it is never elided with "…",
//      because the elided part is exactly where the surprise lives.
//   5. Friction is proportional. A narrow allow-once asks nothing; a global
//      persistent grant asks for a biometric and names the single decision it
//      authorizes.

const ST = TOKENS.color;
const SR = TOKENS.radius;
const PW = TOKENS.layout.promptWidth;   // 420
const PAD = 16;
const INNER = PW - PAD * 2;             // 388

const sk = (scheme, name) => ST[name][scheme];

// A one-line label above a value, the shape most of the disclosure uses.
function field(parent, o) {
  const f = makeFrame(null, {
    name: o.name, w: o.w, h: 16,
    fill: o.fill || sk(o.scheme || "light", "surface"),
  });
  const cap = makeText(null, {
    name: "label", chars: o.label, size: 10, style: "Semibold",
    color: sk(o.scheme || "light", o.labelTone || "text-tertiary"),
  });
  const val = makeText(null, {
    name: "value", chars: o.value, size: o.mono ? 11 : 12, mono: !!o.mono,
    style: o.valueStyle, wrap: o.w, color: sk(o.scheme || "light", o.valueTone || "text-primary"),
  });
  flow(f, [{ node: cap }, { node: val }], {
    direction: "VERTICAL", gap: 3, hugW: false, fixedW: o.w,
  });
  return { node: f, w: o.w, h: f.height };
}

// A hairline that matches the scheme's separator.
function rule(parent, scheme, name, w) {
  const r = makeRect(null, { name: name || "rule", w: w, h: 1, fill: sk(scheme, "separator") });
  return { node: r, w: w, h: 1 };
}

// ------------------------------------------------------------ the prompt itself

// state: "pending" | "denied" | "expired" | "timedout"
function approvalPrompt(o) {
  const scheme = o.scheme || "light";
  const state = o.state || "pending";
  const settled = state !== "pending";

  const p = makeComponent(null, {
    name: "ApprovalPrompt/" + state + (o.reason === null ? "-noreason" : ""),
    w: PW, h: 200, fill: sk(scheme, "surface"), radius: SR["radius-lg"],
    stroke: sk(scheme, settled ? "separator" : "control-border"),
  });

  const items = [];

  // --- header: risk, and the countdown that makes the prompt honest about time
  const head = makeFrame(null, { name: "head", w: INNER, h: 22, fill: sk(scheme, "surface") });
  const chip = riskChip({ level: o.risk || "elevated", scheme });
  // Right-aligned inside a box spanning the slack, for the same reason as the
  // payload's Copy affordance: a stored child offset is not dependable.
  const clock = makeText(null, {
    name: "clock", chars: settled ? "" : "decides in 0:45", size: 11, mono: true,
    color: sk(scheme, "text-tertiary"), align: "RIGHT",
    wrap: INNER - chip.w - 8,
  });
  flow(head, [{ node: chip.node, w: chip.w, h: chip.h }, { node: clock, w: clock.width, h: clock.height }], {
    direction: "HORIZONTAL", gap: 8, align: "CENTER", hugW: false, fixedW: INNER,
  });
  head.resize(INNER, Math.max(chip.h, clock.height));
  items.push({ node: head, w: INNER, h: head.height });

  // --- the consequence, in words, with the capability named beneath it
  const title = makeText(null, {
    name: "title", chars: o.title || "Read the clipboard in TextEdit",
    size: 17, style: "Semibold", color: sk(scheme, "text-primary"), wrap: INNER,
  });
  const cap = makeText(null, {
    name: "capability", chars: o.capability || "clipboard.read  ·  scoped to one application",
    size: 11, mono: true, color: sk(scheme, "text-tertiary"), wrap: INNER,
  });
  const tstack = makeFrame(null, { name: "title-stack", w: INNER, h: 40, fill: sk(scheme, "surface") });
  flow(tstack, [{ node: title }, { node: cap }], { direction: "VERTICAL", gap: 4, fixedW: INNER });
  items.push({ node: tstack, w: INNER, h: tstack.height });
  items.push(rule(null, scheme, "rule-top", INNER));

  // --- who is asking: the whole tree, because a shell is only as safe as the
  //     process that will run it
  const caller = processTree({
    scheme, w: INNER, deep: true, processes: o.tree || [
      { name: "Codex", pid: 8823, depth: 0, isRequester: true },
      { name: "exactmac-mcp", pid: 8840, depth: 1, isRequester: true },
    ],
  });
  items.push({ node: caller.node, w: INNER, h: caller.h });

  // --- the agent's reason, given the room it deserves and marked as unverified
  if (o.reason === null) {
    const missing = makeFrame(null, {
      name: "reason-missing", w: INNER, h: 40,
      fill: sk(scheme, "surface-sunken"), radius: SR["radius-sm"],
      stroke: sk(scheme, "caution"),
    });
    const ruleBar = makeRect(null, { name: "rule", w: 3, h: 24, fill: sk(scheme, "caution"), radius: 1.5 });
    const lbl = makeText(null, {
      name: "label", chars: "THE AGENT GAVE NO REASON", size: 10, style: "Semibold",
      color: sk(scheme, "caution"), wrap: INNER - 40,
    });
    const hint = makeText(null, {
      name: "hint", chars: "Decline, or allow only for this exact request.", size: 11,
      color: sk(scheme, "text-secondary"), wrap: INNER - 40,
    });
    const st = makeFrame(null, { name: "stack", w: INNER - 40, h: 24, fill: sk(scheme, "surface-sunken") });
    flow(st, [{ node: lbl }, { node: hint }], { direction: "VERTICAL", gap: 2, fixedW: INNER - 40 });
    flow(missing, [{ node: ruleBar, w: 3, h: 24 }, { node: st, w: st.width, h: st.height }], {
      direction: "HORIZONTAL", gap: 10, padLeft: 0, padRight: 12, padTop: 8, padBottom: 8,
      align: "CENTER", hugW: false, fixedW: INNER,
    });
    items.push({ node: missing, w: INNER, h: missing.height });
  } else {
    const reason = untrustedField({
      scheme, w: INNER, caption: "REASON GIVEN BY THE AGENT — NOT VERIFIED",
      value: o.reason || "Pasting the test fixture into the TextEdit scratch buffer.",
    });
    items.push({ node: reason.node, w: INNER, h: reason.h });
  }

  // --- the target, resolved by the system rather than claimed by the caller
  const target = field(null, {
    name: "target", scheme, w: INNER, label: "TARGET — RESOLVED BY THE SYSTEM",
    value: o.target || "/Users/joeyc/dev/secret-project/notes.txt",
  });
  items.push({ node: target.node, w: INNER, h: target.h });

  // --- the exact request, wrapping rather than eliding
  const payload = payloadBlock({
    scheme, w: INNER,
    body: o.payload || "pbcopy -Prefer txt < /Users/joeyc/dev/secret-project/notes.txt",
  });
  items.push({ node: payload.node, w: INNER, h: payload.h });

  // --- what the grant silently includes, stated rather than buried
  if (o.implication) {
    const imp = makeFrame(null, {
      name: "implication", w: INNER, h: 40, fill: sk(scheme, "surface-sunken"),
      radius: SR["radius-sm"],
    });
    const bar = makeRect(null, { name: "bar", w: 3, h: 24, fill: sk(scheme, "caution"), radius: 1.5 });
    const txt = makeText(null, {
      name: "text",
      chars: "This grant also permits: screen capture, and reading the focused window's text.",
      size: 11, wrap: INNER - 40, color: sk(scheme, "text-primary"),
    });
    const st = makeFrame(null, { name: "stack", w: INNER - 40, h: 24, fill: sk(scheme, "surface-sunken") });
    flow(st, [{ node: txt }], { direction: "VERTICAL", gap: 0, fixedW: INNER - 40 });
    flow(imp, [{ node: bar, w: 3, h: 24 }, { node: st, w: st.width, h: st.height }], {
      direction: "HORIZONTAL", gap: 10, padLeft: 0, padRight: 12, padTop: 8, padBottom: 8,
      align: "CENTER", hugW: false, fixedW: INNER,
    });
    items.push({ node: imp, w: INNER, h: imp.height });
  }

  items.push(rule(null, scheme, "rule-bottom", INNER));

  // --- the decision, and the reason for it
  if (settled) {
    const outcome = makeFrame(null, {
      name: "outcome", w: INNER, h: 56, fill: sk(scheme, "surface-raised"),
      radius: SR["radius-md"],
    });
    const tone = state === "denied" ? "danger" : state === "expired" ? "caution" : "text-secondary";
    const head2 = makeText(null, {
      name: "headline", chars: o.outcomeTitle || "Denied", size: 14, style: "Semibold",
      color: sk(scheme, tone), wrap: INNER - 24,
    });
    const sub = makeText(null, {
      name: "sub", chars: o.outcomeBody || "The agent was told why, and nothing was granted.",
      size: 11, wrap: INNER - 24, color: sk(scheme, "text-secondary"),
    });
    const st = makeFrame(null, { name: "stack", w: INNER - 24, h: 40, fill: sk(scheme, "surface-raised") });
    flow(st, [{ node: head2 }, { node: sub }], { direction: "VERTICAL", gap: 3, fixedW: INNER - 24 });
    flow(outcome, [{ node: st, w: st.width, h: st.height }], {
      direction: "HORIZONTAL", padLeft: 12, padRight: 12, padTop: 10, padBottom: 10,
      hugW: false, fixedW: INNER,
    });
    items.push({ node: outcome, w: INNER, h: outcome.height });
  } else {
    // Biometric naming the single decision, then the options, then the note.
    const bio = biometricState({
      scheme, w: INNER,
      label: o.bioLabel || "Touch ID will confirm: allow one clipboard read in TextEdit",
    });
    items.push({ node: bio.node, w: INNER, h: bio.h });

    const opts = (o.options || ["deny", "once", "target", "session", "envelope", "global"]).map((k) => {
      const def = OPTIONS.find((x) => x.key === k);
      return optionRow({ option: def, scheme, w: INNER });
    });
    const optWrap = makeFrame(null, {
      name: "options", w: INNER, h: 20, fill: sk(scheme, "surface"),
    });
    flow(optWrap, opts, { direction: "VERTICAL", gap: 6, hugW: false, fixedW: INNER });
    items.push({ node: optWrap, w: INNER, h: optWrap.height });

    const note = noteField({ scheme, w: INNER });
    items.push({ node: note.node, w: INNER, h: note.h });

    const acts = [
      button({ variant: "primary", scheme, label: o.confirmLabel || "Allow once" }),
      button({ variant: "secondary", scheme, label: "Ask every time" }),
      button({ variant: "deny", scheme, label: "Deny" }),
    ];
    const actWrap = makeFrame(null, { name: "actions", w: INNER, h: 34, fill: sk(scheme, "surface") });
    flow(actWrap, acts, {
      direction: "HORIZONTAL", gap: 8, mainAlign: "SPACE_BETWEEN", align: "CENTER", fixedW: INNER,
    });
    items.push({ node: actWrap, w: INNER, h: 34 });
  }

  flow(p, items, {
    direction: "VERTICAL", gap: 12, padLeft: PAD, padRight: PAD, padTop: PAD, padBottom: PAD,
    hugW: false, fixedW: PW,
  });
  return { node: p, w: PW, h: p.height };
}

// -------------------------------------------------------------------- the page

function buildScreens() {
  const page = figma.root.children.find((p) => p.name === "Screens");
  if (!page) throw new Error("Screens page not found");
  while (page.children.length > 0) page.children[0].remove();

  const sheet = makeFrame(page, {
    name: "screens", x: 0, y: 0, w: 1400, h: 400, fill: ST.surface.light,
  });
  const M = 64;
  let y = M;

  const text = (name, chars, size, color, x, style, wrap) => {
    const t = makeText(sheet, { name, chars, size, style: style || "Regular", color, x, y, wrap });
    return t.height;
  };

  y += text("scr/title", "Approval prompt", 22, sk("light", "text-primary"), M, "Semibold") + 12;
  y += text("scr/subtitle",
    "The window an operator reads before an agent touches their machine. 420pt wide, popup-shaped, in the register of a TCC or 1Password sheet.",
    13, sk("light", "text-secondary"), M, "Regular", 1200) + 40;

  // --- the two schemes, side by side, because a prompt is read in whichever one
  //     the system is in and only one of them will ever be reviewed
  const pair = makeFrame(sheet, { name: "scr/pair", x: M, y, w: 1200, h: 20, fill: ST.surface.light });
  const light = approvalPrompt({ scheme: "light", state: "pending", implication: true, risk: "elevated" });
  const dark = approvalPrompt({ scheme: "dark", state: "pending", implication: true, risk: "elevated" });
  flow(pair, [light, dark], { direction: "HORIZONTAL", gap: 32, hugW: false, fixedW: 1200 });
  y += Math.max(light.h, dark.h) + 48;

  text("scr/states-h", "Settled states", 15, sk("light", "text-primary"), M, "Semibold");
  y += 24;
  const states = makeFrame(sheet, { name: "scr/states", x: M, y, w: 1308, h: 20, fill: ST.surface.light });
  const settled = [
    approvalPrompt({ scheme: "light", state: "denied", outcomeTitle: "Denied", outcomeBody: "Your note went back to the agent: use the scoped option, not this one." }),
    approvalPrompt({ scheme: "light", state: "expired", outcomeTitle: "Expired unanswered", outcomeBody: "After 45 seconds with no decision the request was denied. Nothing was granted." }),
    approvalPrompt({ scheme: "light", state: "timedout", outcomeTitle: "Console unreachable", outcomeBody: "ExactMac could not reach the consent service, so it denied. This is the safe direction." }),
  ];
  flow(states, settled, { direction: "HORIZONTAL", gap: 24, hugW: false, fixedW: 1308 });
  y += states.height + 48;

  text("scr/noreason-h", "The same request with no reason supplied", 15, sk("light", "text-primary"), M, "Semibold");
  y += 24;
  const nr = makeFrame(sheet, { name: "scr/noreason", x: M, y, w: 1200, h: 20, fill: ST.surface.light });
  const withReason = approvalPrompt({
    scheme: "light", state: "pending", risk: "routine", implication: true,
    reason: "Pasting the fixture text into the TextEdit scratch buffer for the clipboard test.",
  });
  const noReason = approvalPrompt({ scheme: "light", state: "pending", risk: "high", implication: true, reason: null });
  flow(nr, [withReason, noReason], { direction: "HORIZONTAL", gap: 32, hugW: false, fixedW: 1200 });
  y += Math.max(withReason.h, noReason.h) + 40;

  sheet.resize(1400, y);
  page.resize(1400 + 240, y + 240);
  return {
    page: "Screens", prompts: 7,
    states: ["pending", "denied", "expired", "timedout", "pending-noreason"],
    schemes: ["light", "dark"],
  };
}

console.log("__RESULT__" + JSON.stringify(buildScreens()));
