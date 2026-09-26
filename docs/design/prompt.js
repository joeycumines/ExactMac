// Screens page: the approval prompt, in both schemes and in every state that
// matters. This is the highest-stakes surface in the product, so the design
// answers one question above all: can an operator who does not trust the agent
// still decide correctly, in a few seconds, from this window alone?
//
// The prompt is Okta/1Password-shaped and deliberately small, but it carries more
// context than those need, because a shell is not a login.
//
// STRUCTURE IS THE DESIGN. B5 requires maximal disclosure AND a reason the
// operator can read without scrolling, and those pull against each other in a
// single scrolling column: a full disclosure is far taller than any popover. So
// the prompt is three regions, and the split is the point:
//
//   HEADER   fixed. Risk, the consequence in words, and the agent's REASON. Never
//            scrolls, because the reason is the thing an operator most needs and
//            the thing a prompt must never hide below a fold.
//   BODY     scrollable. The caller tree, the target, the exact payload and the
//            grant's implications. Clipped to a fixed height with a real scrollbar,
//            so it is obvious there is more rather than silently hiding it.
//   FOOTER   fixed. The biometric naming the one decision, the primary pair, and
//            the expander that reveals the full breadth-and-duration set.
//
// Five further commitments shape every state below:
//
//   1. The headline is the CONSEQUENCE ("Read the clipboard in TextEdit"), never
//      the capability name. "clipboard.read" is not something an operator can
//      picture; what it will take is.
//   2. The agent's REASON is in the fixed header, marked caller-supplied, because
//      an unexplained request is one the operator should decline. A prompt with no
//      reason is visibly different, not silently sparser.
//   3. The grant's IMPLICATIONS are stated on their face. script.execute is not a
//      peer of clipboard.read, it subsumes it, and information the operator is
//      entitled to before agreeing cannot be buried.
//   4. Nothing is truncated. A long command wraps; it is never elided with a
//      character that hides the surprise at the end.
//   5. Friction is proportional. A narrow allow-once asks nothing; a global
//      persistent grant asks for a biometric and names the single decision it
//      authorizes. The pre-authorization REVIEW is a different surface with
//      different chrome, so a batch grant can never be mistaken for one keystroke.

const ST = TOKENS.color;
const SR = TOKENS.radius;
const PW = TOKENS.layout.promptWidth;   // 420
const PAD = 16;
const INNER = PW - PAD * 2;             // 388
const BODY_H = 236;                     // the scrolling region's fixed height

const sk = (scheme, name) => ST[name][scheme];

// A label above a value, the shape most of the disclosure uses.
function field(scheme, o) {
  const f = makeFrame(null, {
    name: o.name, w: o.w, h: 16, fill: sk(scheme, "surface"),
  });
  const cap = makeText(null, {
    name: "label", chars: o.label, size: 10, style: "Semi Bold",
    color: sk(scheme, o.labelTone || "text-tertiary"),
  });
  const val = makeText(null, {
    name: "value", chars: o.value, size: o.mono ? 11 : 12, mono: !!o.mono,
    style: o.valueStyle, wrap: o.w, color: sk(scheme, o.valueTone || "text-primary"),
  });
  flow(f, [{ node: cap }, { node: val }], {
    direction: "VERTICAL", gap: 3, hugW: false, fixedW: o.w,
  });
  return { node: f, w: o.w, h: f.height };
}

function rule(scheme, name, w) {
  return { node: makeRect(null, { name: name || "rule", w: w, h: 1, fill: sk(scheme, "separator") }), w: w, h: 1 };
}

// ------------------------------------------------------------------- the header

// Never scrolls. Carries the three things that decide whether the operator can
// act at all: how bad this is, what will happen, and why the agent wants it.
function promptHeader(scheme, o) {
  const h = makeFrame(null, {
    name: "header", w: PW, h: 20, fill: sk(scheme, "surface"),
  });

  // Risk and the countdown that makes the prompt honest about time. The countdown
  // right-aligns INSIDE a box spanning the slack, because a stored child offset is
  // not reliably round-tripped by the writer.
  const chip = riskChip({ level: o.risk || "elevated", scheme });
  const clock = makeText(null, {
    name: "clock", chars: o.settled ? "" : "decides in 0:45", size: 11, mono: true,
    color: sk(scheme, "text-tertiary"), align: "RIGHT", wrap: INNER - chip.w - 8,
  });
  const head = makeFrame(null, { name: "risk-row", w: INNER, h: 22, fill: sk(scheme, "surface") });
  flow(head, [{ node: chip.node, w: chip.w, h: chip.h }, { node: clock, w: clock.width, h: clock.height }], {
    direction: "HORIZONTAL", gap: 8, align: "CENTER", hugW: false, fixedW: INNER,
  });
  head.resize(INNER, Math.max(chip.h, clock.height));

  const title = makeText(null, {
    name: "title", chars: o.title || "Read the clipboard in TextEdit",
    size: 17, style: "Semi Bold", color: sk(scheme, "text-primary"), wrap: INNER,
  });
  const cap = makeText(null, {
    name: "capability", chars: o.capability || "clipboard.read  ·  scoped to one application",
    size: 11, mono: true, color: sk(scheme, "text-tertiary"), wrap: INNER,
  });
  const tstack = makeFrame(null, { name: "title-stack", w: INNER, h: 40, fill: sk(scheme, "surface") });
  flow(tstack, [{ node: title }, { node: cap }], { direction: "VERTICAL", gap: 4, fixedW: INNER });

  const items = [
    { node: head, w: INNER, h: head.height },
    { node: tstack, w: INNER, h: tstack.height },
  ];

  // The reason, in the fixed region. A missing reason is a different prompt, not a
  // shorter one: it gets a caution border and an explicit instruction to decline.
  if (o.reason === null) {
    const missing = makeFrame(null, {
      name: "reason-missing", w: INNER, h: 40,
      fill: sk(scheme, "surface-sunken"), radius: SR["radius-sm"], stroke: sk(scheme, "caution"),
    });
    const bar = makeRect(null, { name: "bar", w: 3, h: 24, fill: sk(scheme, "caution"), radius: 1.5 });
    const lbl = makeText(null, {
      name: "label", chars: "THE AGENT GAVE NO REASON", size: 10, style: "Semi Bold",
      color: sk(scheme, "caution"), wrap: INNER - 40,
    });
    const hint = makeText(null, {
      name: "hint", chars: "Decline, or allow only for this exact request.", size: 11,
      color: sk(scheme, "text-secondary"), wrap: INNER - 40,
    });
    const st = makeFrame(null, { name: "stack", w: INNER - 40, h: 24, fill: sk(scheme, "surface-sunken") });
    flow(st, [{ node: lbl }, { node: hint }], { direction: "VERTICAL", gap: 2, fixedW: INNER - 40 });
    flow(missing, [{ node: bar, w: 3, h: 24 }, { node: st, w: st.width, h: st.height }], {
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

  if (o.implication) {
    const imp = makeFrame(null, {
      name: "implication", w: INNER, h: 34, fill: sk(scheme, "surface-sunken"),
      radius: SR["radius-sm"],
    });
    const bar = makeRect(null, { name: "bar", w: 3, h: 18, fill: sk(scheme, "caution"), radius: 1.5 });
    const txt = makeText(null, {
      name: "text", chars: o.implicationText ||
        "Also permits screen capture and reading the focused window's text.",
      size: 11, wrap: INNER - 40, color: sk(scheme, "text-primary"),
    });
    const st = makeFrame(null, { name: "stack", w: INNER - 40, h: 18, fill: sk(scheme, "surface-sunken") });
    flow(st, [{ node: txt }], { direction: "VERTICAL", gap: 0, fixedW: INNER - 40 });
    flow(imp, [{ node: bar, w: 3, h: 18 }, { node: st, w: st.width, h: st.height }], {
      direction: "HORIZONTAL", gap: 10, padLeft: 0, padRight: 12, padTop: 8, padBottom: 8,
      align: "CENTER", hugW: false, fixedW: INNER,
    });
    items.push({ node: imp, w: INNER, h: imp.height });
  }

  flow(h, items, {
    direction: "VERTICAL", gap: 12, padLeft: PAD, padRight: PAD, padTop: PAD, padBottom: 14,
    hugW: false, fixedW: PW,
  });
  return { node: h, w: PW, h: h.height };
}

// ----------------------------------------------------------------- scroll region

// Clipped to a fixed height with a visible scrollbar. The alternative — letting the
// disclosure grow the window — is what makes a "maximal disclosure" prompt either
// unreadably tall or quietly truncated; a real scrollbar is the honest third option.
function promptBody(scheme, o) {
  const wrap = makeFrame(null, {
    name: "body-scroll", w: PW, h: BODY_H,
    fill: sk(scheme, "surface-sunken"), clips: true,
  });
  // clips:false is the point: this frame is TALLER than the region and the WRAP
  // clips it, which is what a scroll view is.
  const inner = makeFrame(null, {
    name: "disclosure", w: INNER, h: 20, fill: sk(scheme, "surface-sunken"), clips: false,
  });
  const items = [];

  const caller = processTree({
    scheme, w: INNER, deep: true, compact: true, processes: o.tree || [
      // Exactly ONE requester: the process whose code identity lands in the grant.
      // Marking both rows made the emphasis meaningless and misstated who was asking.
      // Every row carries signature state, because a tree with no evidence of who is
      // calling is not the graded-evidence model, it is a process list.
      { name: "Codex", pid: 8823, depth: 0, detail: "agent host", signature: SIGNATURE_STATES[0] },
      { name: "exactmac-mcp", pid: 8840, depth: 1, isRequester: true, signature: SIGNATURE_STATES[1] },
    ],
  });
  items.push({ node: caller.node, w: INNER, h: caller.h });

  const target = field(scheme, {
    name: "target", w: INNER, label: "TARGET — RESOLVED BY THE SYSTEM",
    value: o.target || "/Users/joeyc/dev/secret-project/notes.txt",
  });
  items.push({ node: target.node, w: INNER, h: target.h });

  const payload = payloadBlock({
    scheme, w: INNER,
    body: o.payload || "pbcopy -Prefer txt < /Users/joeyc/dev/secret-project/notes.txt",
  });
  items.push({ node: payload.node, w: INNER, h: payload.h });

  flow(inner, items, { direction: "VERTICAL", gap: 10, hugW: false, fixedW: INNER });
  // The scrollbar is a COLUMN placed by the flow, not an absolutely positioned
  // child: a stored child offset is not reliably round-tripped, which previously
  // put the thumb 189pt below its own clipping frame, i.e. invisible.
  const track = makeFrame(null, {
    name: "scrollbar", w: 4, h: BODY_H - 24, fill: sk(scheme, "separator"),
  });
  const thumb = makeFrame(null, {
    name: "thumb-box", w: 4, h: Math.round((BODY_H - 24) * 0.45), fill: sk(scheme, "control-border"),
  });
  flow(track, [{ node: thumb, w: 4, h: thumb.height }], {
    direction: "VERTICAL", gap: 0, padLeft: 0, padRight: 0, padTop: 0, padBottom: 0,
    hugW: false, hugH: false, fixedW: 4, fixedH: BODY_H - 24,
  });

  flow(wrap, [
    { node: inner, w: INNER, h: inner.height },
    { node: track, w: 4, h: BODY_H - 24 },
  ], {
    direction: "HORIZONTAL", gap: 8, padLeft: PAD, padRight: 4, padTop: 12, padBottom: 12,
    align: "MIN", hugW: false, hugH: false, fixedW: PW, fixedH: BODY_H,
  });

  return { node: wrap, w: PW, h: BODY_H };
}

// --------------------------------------------------------------------- the footer

function promptFooter(scheme, o) {
  const f = makeFrame(null, { name: "footer", w: PW, h: 20, fill: sk(scheme, "surface") });
  const items = [];

  const bio = biometricState({
    scheme, w: INNER,
    label: o.bioLabel || "Touch ID will confirm: allow one clipboard read in TextEdit",
  });
  items.push({ node: bio.node, w: INNER, h: bio.h });

  if (o.expanded) {
    // Every option, each stating its own breadth and duration. Deny is placed so it
    // is neither the default nor next to the option holding focus.
    const keys = o.options || ["once", "target", "session", "envelope", "deny", "global"];
    const optWrap = makeFrame(null, { name: "options", w: INNER, h: 20, fill: sk(scheme, "surface") });
    flow(optWrap, keys.map((k) => optionRow({
      option: OPTIONS.find((x) => x.key === k), scheme, w: INNER,
    })), { direction: "VERTICAL", gap: 6, hugW: false, fixedW: INNER });
    items.push({ node: optWrap, w: INNER, h: optWrap.height });
  } else {
    // Collapsed: the primary decision alone on its row. Deny is NOT beside it.
    const primary = button({ variant: "primary", scheme, label: o.confirmLabel || "Allow once" });
    const actWrap = makeFrame(null, { name: "actions", w: INNER, h: 34, fill: sk(scheme, "surface") });
    flow(actWrap, [{ node: primary.node, w: primary.w, h: primary.h }], {
      direction: "HORIZONTAL", gap: 8, mainAlign: "MAX", align: "CENTER",
      hugW: false, fixedW: INNER,
    });
    items.push({ node: actWrap, w: INNER, h: 34 });
  }

  // The note is on BOTH paths, approve and deny. It is the only channel by which a
  // rejection teaches the agent anything, so it must never sit behind the expander.
  const note = noteField({ scheme, w: INNER });
  items.push({ node: note.node, w: INNER, h: note.h });

  if (!o.expanded) {
    // A hairline, then Deny and the expander on their own row: separated from the
    // primary by the note and a rule, never adjacent to it.
    items.push(rule(scheme, "rule-before-deny", INNER));
    const deny = button({ variant: "deny", scheme, label: "Deny" });
    // Widths: deny 96 + gap 8 + more 284 = 388. Inside `more`, 12 + label 200 +
    // gap 8 + hint 48 + 12 = 280 <= 284, and the row is 36 tall because the label
    // wraps to two lines.
    const moreW = INNER - deny.w - 8;
    const more = makeFrame(null, {
      name: "more-options", w: moreW, h: 36,
      fill: sk(scheme, "surface-sunken"), radius: SR["radius-sm"],
    });
    const mLabel = makeText(null, {
      name: "label", chars: "4 more choices — scope, session, batch, always", size: 11,
      color: sk(scheme, "text-secondary"), wrap: 200,
    });
    const mHint = makeText(null, {
      name: "hint", chars: "Show", size: 11, style: "Semi Bold",
      color: sk(scheme, "accent-text"), align: "RIGHT", wrap: 48,
    });
    flow(more, [{ node: mLabel, w: 200, h: mLabel.height }, { node: mHint, w: 48, h: mHint.height }], {
      direction: "HORIZONTAL", gap: 8, padLeft: 12, padRight: 12, padTop: 6, padBottom: 6,
      align: "CENTER", hugW: false, fixedW: moreW,
    });
    const tail = makeFrame(null, { name: "deny-row", w: INNER, h: 36, fill: sk(scheme, "surface") });
    flow(tail, [
      { node: deny.node, w: deny.w, h: deny.h },
      { node: more, w: moreW, h: 36 },
    ], {
      direction: "HORIZONTAL", gap: 8, align: "CENTER", hugW: false, fixedW: INNER,
    });
    items.push({ node: tail, w: INNER, h: 36 });
  }

  flow(f, items, {
    direction: "VERTICAL", gap: 12, padLeft: PAD, padRight: PAD, padTop: 12, padBottom: PAD,
    hugW: false, fixedW: PW,
  });
  return { node: f, w: PW, h: f.height };
}

// ------------------------------------------------------------- the prompt itself

function approvalPrompt(o) {
  const scheme = o.scheme || "light";
  const state = o.state || "pending";
  const settled = state !== "pending";
  const p = makeComponent(null, {
    name: "ApprovalPrompt/" + state + (o.reason === null ? "-noreason" : "") + (o.expanded ? "-expanded" : ""),
    w: PW, h: 200, fill: sk(scheme, "surface"), radius: SR["radius-lg"],
    stroke: sk(scheme, "control-border"),
  });

  if (settled) {
    // A settled request has no decision left to make, so it shows the outcome and
    // nothing else: an expired prompt must not still be approvable.
    const head = promptHeader(scheme, { ...o, settled: true });
    const outcome = makeFrame(null, {
      name: "outcome", w: INNER, h: 20, fill: sk(scheme, "surface-raised"), radius: SR["radius-md"],
    });
    const tone = state === "denied" ? "danger" : state === "expired" ? "caution" : "text-secondary";
    const h2 = makeText(null, {
      name: "headline", chars: o.outcomeTitle || "Denied", size: 14, style: "Semi Bold",
      color: sk(scheme, tone), wrap: INNER - 24,
    });
    const sub = makeText(null, {
      name: "sub", chars: o.outcomeBody || "The agent was told why, and nothing was granted.",
      size: 11, wrap: INNER - 24, color: sk(scheme, "text-secondary"),
    });
    const st = makeFrame(null, { name: "stack", w: INNER - 24, h: 40, fill: sk(scheme, "surface-raised") });
    flow(st, [{ node: h2 }, { node: sub }], { direction: "VERTICAL", gap: 3, fixedW: INNER - 24 });
    flow(outcome, [{ node: st, w: st.width, h: st.height }], {
      direction: "HORIZONTAL", padLeft: 12, padRight: 12, padTop: 10, padBottom: 10,
      hugW: false, fixedW: INNER,
    });
    flow(p, [
      { node: head.node, w: PW, h: head.h },
      rule(scheme, "rule", PW),
      { node: outcome, w: INNER, h: outcome.height },
    ], {
      direction: "VERTICAL", gap: 12, padLeft: 0, padRight: 0, padTop: 0, padBottom: PAD,
      hugW: false, fixedW: PW,
    });
    // Re-indent the outcome, which the flat flow cannot express.
    outcome.x = PAD;
    return { node: p, w: PW, h: p.height };
  }

  const head = promptHeader(scheme, o);
  const body = promptBody(scheme, o);
  const foot = promptFooter(scheme, o);
  flow(p, [
    { node: head.node, w: PW, h: head.h },
    { node: body.node, w: PW, h: body.h },
    { node: foot.node, w: PW, h: foot.h },
  ], { direction: "VERTICAL", gap: 0, hugW: false, fixedW: PW });
  return { node: p, w: PW, h: p.height };
}

// ------------------------------------------------- the pre-authorization review

// A DIFFERENT SURFACE, not a variant of the prompt. Approving a batch is not
// approving a keystroke, and the chrome says so: a band naming it a
// pre-authorization, a per-capability list with each consequence and breadth, a
// duration the operator sets, and a primary action that names the duration rather
// than saying "allow". The envelope can never widen to global scope or exceed the
// configured maximum, so neither control offers it.
function envelopeReview(scheme, o) {
  const caps = o.capabilities || [
    { name: "clipboard.read", consequence: "Read the clipboard in any app the agent names", breadth: "any application", risk: "elevated" },
    { name: "observation.ax", consequence: "Read the accessibility tree of any app", breadth: "any application", risk: "elevated" },
    { name: "input.synthesize", consequence: "Type and click as you, in any app", breadth: "any application", risk: "high" },
  ];
  const rev = makeComponent(null, {
    name: "EnvelopeReview/" + (o.variant || "default"), w: PW, h: 200,
    fill: sk(scheme, "surface"), radius: SR["radius-lg"], stroke: sk(scheme, "control-border"),
  });

  // The band. Nothing else in the product uses this treatment, so the surface is
  // identifiable at a glance from across the desk.
  const band = makeFrame(null, {
    name: "envelope-band", w: PW, h: 34, fill: sk(scheme, "caution"), radius: SR["radius-lg"],
  });
  const bandText = makeText(null, {
    name: "band-label", chars: "PRE-AUTHORIZATION ENVELOPE", size: 11, style: "Semi Bold",
    color: sk(scheme, "surface"), wrap: INNER,
  });
  flow(band, [{ node: bandText, w: INNER, h: bandText.height }], {
    direction: "HORIZONTAL", padLeft: PAD, padRight: PAD, padTop: 9, padBottom: 9,
    hugW: false, fixedW: PW,
  });
  band.resize(PW, 34);

  const head = makeFrame(null, { name: "header", w: PW, h: 20, fill: sk(scheme, "surface") });
  const title = makeText(null, {
    name: "title", chars: "Pre-authorize a batch of capabilities", size: 17, style: "Semi Bold",
    color: sk(scheme, "text-primary"), wrap: INNER,
  });
  const sub = makeText(null, {
    name: "sub", chars: "3 capabilities  ·  requested by Codex", size: 11, mono: true,
    color: sk(scheme, "text-tertiary"), wrap: INNER,
  });
  const tstack = makeFrame(null, { name: "title-stack", w: INNER, h: 40, fill: sk(scheme, "surface") });
  flow(tstack, [{ node: title }, { node: sub }], { direction: "VERTICAL", gap: 4, fixedW: INNER });

  const reason = untrustedField({
    scheme, w: INNER, caption: "REASON GIVEN BY THE AGENT — NOT VERIFIED",
    value: o.reason || "Refactoring the parser, which needs clipboard and tree reads at each step.",
  });

  const hitems = [
    { node: tstack, w: INNER, h: tstack.height },
    { node: reason.node, w: INNER, h: reason.h },
  ];
  flow(head, hitems, {
    direction: "VERTICAL", gap: 12, padLeft: PAD, padRight: PAD, padTop: 14, padBottom: 14,
    hugW: false, fixedW: PW,
  });

  // The per-capability list. Each row states the CONSEQUENCE, never the token.
  const list = makeFrame(null, {
    name: "capability-list", w: PW, h: 20, fill: sk(scheme, "surface-sunken"), clips: true,
  });
  const rows = caps.map((c) => {
    const row = makeFrame(null, {
      name: "cap-" + c.name, w: INNER, h: 20, fill: sk(scheme, "surface-sunken"),
    });
    const chip = riskChip({ level: c.risk, scheme });
    const txt = makeFrame(null, { name: "text", w: INNER - 100, h: 32, fill: sk(scheme, "surface-sunken") });
    const cons = makeText(null, {
      name: "consequence", chars: c.consequence, size: 12, wrap: INNER - 100,
      color: sk(scheme, "text-primary"),
    });
    const breadth = makeText(null, {
      name: "breadth", chars: c.name + "  ·  " + c.breadth, size: 10, mono: true,
      color: sk(scheme, "text-tertiary"), wrap: INNER - 100,
    });
    flow(txt, [{ node: cons }, { node: breadth }], { direction: "VERTICAL", gap: 2, fixedW: INNER - 100 });
    flow(row, [
      { node: chip.node, w: chip.w, h: chip.h },
      { node: txt, w: txt.width, h: txt.height },
    ], {
      direction: "HORIZONTAL", gap: 8, align: "CENTER", hugW: false, fixedW: INNER,
    });
    return { node: row, w: INNER, h: row.height };
  });
  const listInner = makeFrame(null, { name: "rows", w: INNER, h: 20, fill: sk(scheme, "surface-sunken") });
  flow(listInner, rows, { direction: "VERTICAL", gap: 8, hugW: false, fixedW: INNER });
  flow(list, [{ node: listInner, w: INNER, h: listInner.height }], {
    direction: "VERTICAL", gap: 0, padLeft: PAD, padRight: PAD, padTop: 12, padBottom: 12,
    hugW: false, fixedW: PW,
  });

  // Duration is the operator's to set, and the ceiling is not negotiable here.
  const foot = makeFrame(null, { name: "footer", w: PW, h: 20, fill: sk(scheme, "surface") });
  // Widths sum to exactly INNER (12 + 52 + 10 + 76 + 10 + 216 + 12 = 388). The
  // previous row needed 402 and the clipped panel sliced the "s" off "hours" — on
  // the one surface that states the envelope's ceiling.
  const dur = makeFrame(null, {
    name: "duration", w: INNER, h: 34, fill: sk(scheme, "surface-sunken"), radius: SR["radius-sm"],
  });
  const durLabel = makeText(null, {
    name: "label", chars: "Valid for", size: 12, color: sk(scheme, "text-secondary"), wrap: 52,
  });
  const durVal = makeText(null, {
    name: "value", chars: "2 hours", size: 12, style: "Semi Bold",
    color: sk(scheme, "text-primary"), wrap: 76,
  });
  const durCeil = makeText(null, {
    name: "ceiling", chars: "maximum 8 hours", size: 10, mono: true,
    color: sk(scheme, "text-tertiary"), align: "RIGHT", wrap: 216,
  });
  flow(dur, [
    { node: durLabel, w: 52, h: durLabel.height },
    { node: durVal, w: 76, h: durVal.height },
    { node: durCeil, w: 216, h: durCeil.height },
  ], {
    direction: "HORIZONTAL", gap: 10, padLeft: 12, padRight: 12, padTop: 8, padBottom: 8,
    align: "CENTER", hugW: false, fixedW: INNER,
  });

  // --- B1: the primary gets its own row; Deny sits below a hairline, so it is
  //     never adjacent to the action it would cancel.
  const approve = button({ variant: "primary", scheme, label: "Approve for 2 hours" });
  const actWrap = makeFrame(null, { name: "actions", w: INNER, h: 34, fill: sk(scheme, "surface") });
  flow(actWrap, [{ node: approve.node, w: approve.w, h: approve.h }], {
    direction: "HORIZONTAL", gap: 8, mainAlign: "MAX", align: "CENTER",
    hugW: false, fixedW: INNER,
  });
  const deny = button({ variant: "deny", scheme, label: "Deny" });
  const denyRow = makeFrame(null, { name: "deny-row", w: INNER, h: 34, fill: sk(scheme, "surface") });
  flow(denyRow, [{ node: deny.node, w: deny.w, h: deny.h }], {
    direction: "HORIZONTAL", gap: 8, align: "MIN", hugW: false, fixedW: INNER,
  });
  const note = noteField({ scheme, w: INNER, caption: "NOTE TO THE AGENT — SENT BACK WITH YOUR DECISION" });
  const bioNote = makeText(null, {
    name: "never-global", chars: "An envelope can never become global or outlive its duration.", size: 10,
    color: sk(scheme, "text-tertiary"), wrap: INNER,
  });

  const bioState = biometricState({
    scheme, w: INNER, label: "Touch ID will confirm: pre-authorize 3 capabilities for 2 hours",
  });

  flow(foot, [
    { node: bioState.node, w: INNER, h: bioState.h },
    { node: dur, w: INNER, h: 34 },
    { node: actWrap, w: INNER, h: 34 },
    { node: note.node, w: INNER, h: note.h },
    rule(scheme, "rule-before-deny", INNER),
    { node: denyRow, w: INNER, h: 34 },
    { node: bioNote, w: INNER, h: bioNote.height },
  ], {
    direction: "VERTICAL", gap: 10, padLeft: PAD, padRight: PAD, padTop: 12, padBottom: PAD,
    hugW: false, fixedW: PW,
  });

  flow(rev, [
    { node: band, w: PW, h: 34 },
    { node: head, w: PW, h: head.height },
    { node: list, w: PW, h: list.height },
    { node: foot, w: PW, h: foot.height },
  ], { direction: "VERTICAL", gap: 0, hugW: false, fixedW: PW });
  return { node: rev, w: PW, h: rev.height };
}

// -------------------------------------------------------------------- the page

function buildScreens() {
  const page = figma.root.children.find((p) => p.name === "Screens");
  if (!page) throw new Error("Screens page not found");
  while (page.children.length > 0) page.children[0].remove();

  const sheet = makeFrame(page, {
    name: "screens", x: 0, y: 0, w: 1900, h: 400, fill: ST.surface.light,
  });
  const M = 64;
  let y = M;

  const text = (name, chars, size, color, style, wrap) => {
    const t = makeText(sheet, { name, chars, size, style: style || "Regular", color, x: M, y, wrap });
    return t.height;
  };
  const row = (name, items, w) => {
    const r = makeFrame(sheet, { name: name, x: M, y, w: w, h: 20, fill: ST.surface.light });
    flow(r, items, { direction: "HORIZONTAL", gap: 24, hugW: false, fixedW: w });
    return r.height;
  };

  y += text("scr/title", "Approval prompt", 22, sk("light", "text-primary"), "Semi Bold") + 12;
  y += text("scr/subtitle",
    "The window an operator reads before an agent touches their machine. Three regions: a fixed header carrying the reason, a scrolling disclosure, and a fixed footer. 420pt wide, popup-shaped, in the register of a TCC or 1Password sheet.",
    13, sk("light", "text-secondary"), "Regular", 1700) + 40;

  y += text("scr/h1", "Both schemes, collapsed options", 15, sk("light", "text-primary"), "Semi Bold") + 20;
  y += row("scr/pair", [
    approvalPrompt({ scheme: "light", implication: true, risk: "elevated" }),
    approvalPrompt({ scheme: "dark", implication: true, risk: "elevated" }),
  ], 880) + 40;

  y += text("scr/h2", "Expanded options, and the pre-authorization review — a different surface, not a variant", 15, sk("light", "text-primary"), "Semi Bold") + 20;
  y += row("scr/expanded", [
    approvalPrompt({ scheme: "light", implication: true, risk: "elevated", expanded: true }),
    envelopeReview("light", {}),
  ], 880) + 40;

  y += text("scr/h3", "Settled states — the decision controls are gone, so an expired request cannot be approved", 15, sk("light", "text-primary"), "Semi Bold") + 20;
  y += row("scr/states", [
    approvalPrompt({ scheme: "light", state: "denied", outcomeTitle: "Denied", outcomeBody: "Your note went back to the agent: use the scoped option, not this one." }),
    approvalPrompt({ scheme: "light", state: "expired", outcomeTitle: "Expired unanswered", outcomeBody: "After 45 seconds with no decision the request was denied. Nothing was granted." }),
    approvalPrompt({ scheme: "light", state: "timedout", outcomeTitle: "Console unreachable", outcomeBody: "ExactMac could not reach the consent service, so it denied. This is the safe direction." }),
  ], 1332) + 40;

  y += text("scr/h4", "The same request with no reason supplied — a different prompt, not a shorter one", 15, sk("light", "text-primary"), "Semi Bold") + 20;
  y += row("scr/noreason", [
    // Same risk on both sides: the pair exists to isolate the REASON, so a differing
    // risk chip would confound the comparison it is meant to demonstrate.
    approvalPrompt({ scheme: "light", risk: "elevated", implication: true, reason: "Pasting the fixture text into the TextEdit scratch buffer for the clipboard test." }),
    approvalPrompt({ scheme: "light", risk: "elevated", implication: true, reason: null }),
  ], 880) + 40;

  sheet.resize(1900, y);
  page.resize(1900 + 240, y + 240);
  return {
    page: "Screens", prompts: 8,
    states: ["pending", "pending-expanded", "denied", "expired", "timedout", "pending-noreason"],
    envelopeReview: 1, schemes: ["light", "dark"],
    regions: ["header-fixed", "body-scrolling", "footer-fixed"],
  };
}

console.log("__RESULT__" + JSON.stringify(buildScreens()));
