// Components page, continued: the console's own vocabulary, as a specimen sheet.
//
// Every family the console surfaces use is documented here, in the same way identity.js
// and controls.js document theirs. The rule B6 sets is that a surface may not draw an
// ad-hoc shape: if a surface uses it, it is a component, and a component the
// implementation tasks can cite by name.

function buildConsoleControls() {
  const page = figma.root.children.find((p) => p.name === "Components");
  if (!page) throw new Error("Components page not found");
  const root = page.children[0];
  if (!root) throw new Error("identity.js must render the page root first");
  const L = "light";
  const W = TOKENS.layout.specimenWidth;
  const M = 64;
  const FULL = W - M * 2;      // 1112
  const HALF = 544;            // two to a row, with a 24pt gutter

  let y = Math.max(root.height, 0) + 48;

  const heading = (chars) => {
    makeText(root, {
      name: "cc/h", chars, size: 15, style: "Semi Bold", color: cw(L, "text-primary"), x: M, y,
    });
    y += 26;
  };
  const note = (chars) => {
    const t = makeText(root, {
      name: "cc/note", chars, size: 11, color: cw(L, "text-tertiary"), x: M, y, wrap: FULL,
    });
    y += t.height + 18;
  };
  const strip = (name, items, w, gap) => {
    const g = gap === undefined ? 16 : gap;
    // A strip with no declared width is sized to its CONTENT. It used to default to
    // the caller's `undefined`, which reached makeFrame as 0 and produced a 1pt-wide
    // frame that every pill then overflowed: three of the strips in this file were
    // written without a width and the gate caught all three.
    const width = w !== undefined
      ? w
      : items.reduce((a, it) => a + (it.w || 0), 0) + g * Math.max(0, items.length - 1);
    const s = makeFrame(root, { name: "cc/" + name, x: M, y, w: width, h: 20, fill: cw(L, "surface") });
    flow(s, items, { direction: "HORIZONTAL", gap: g, align: "MIN", hugW: false, fixedW: width });
    y += s.height + 40;
  };
  const pair = (name, a, b) => {
    const w = HALF * 2 + 24;
    const s = makeFrame(root, { name: "cc/" + name, x: M, y, w: w, h: 20, fill: cw(L, "surface") });
    flow(s, [a, b], { direction: "HORIZONTAL", gap: 24, align: "MIN", hugW: false, fixedW: w });
    y += s.height + 40;
  };

  makeText(root, {
    name: "cc/title", chars: "Console vocabulary", size: 22, style: "Semi Bold",
    color: cw(L, "text-primary"), x: M, y,
  });
  y += 52;

  heading("ServiceStatus, and the menu-bar item it belongs to");
  note("The item is the only part of the console an operator may never consciously look at, so the state has to survive 22pt, greyscale and colour blindness. Every state therefore carries a word, not only a colour; red is never used here, because nothing about a degraded service is a security incident.");
  strip("menubar", SERVICE_STATES.map((s) => {
    const it = menuBarItem({ scheme: L, state: s.key });
    return { node: it.node, w: it.w, h: it.h };
  }), 400, 24);
  strip("status", SERVICE_STATES.map((s) => {
    const p = serviceStatus({ scheme: L, state: s.key });
    return { node: p.node, w: p.w, h: p.h };
  }));

  heading("ServiceToggle — B1's persistent control");
  note("The row states that the state survives a restart, because a toggle an operator believes is a preference will not be trusted to stop a service. Turning it back on does not restore revoked grants, and the popover says so beneath it.");
  pair("toggle", (() => { const t = serviceToggle({ scheme: L, w: HALF, state: "on" }); return { node: t.node, w: HALF, h: t.h }; })(),
    (() => { const t = serviceToggle({ scheme: L, w: HALF, state: "off" }); return { node: t.node, w: HALF, h: t.h }; })());

  heading("FailClosedBand — the states where the answer is deny");
  note("Amber, not red, and every body says what the system is doing instead of the action it refused. That is what makes a stopped or degraded service read as protection rather than as a fault to work around.");
  pair("failclosed-a", (() => { const b = failClosedBand({ scheme: L, w: HALF, reason: "console-unreachable" }); return { node: b.node, w: HALF, h: b.h }; })(),
    (() => { const b = failClosedBand({ scheme: L, w: HALF, reason: "server-unreachable" }); return { node: b.node, w: HALF, h: b.h }; })());
  pair("failclosed-b", (() => { const b = failClosedBand({ scheme: L, w: HALF, reason: "tcp-reduced" }); return { node: b.node, w: HALF, h: b.h }; })(),
    (() => { const b = failClosedBand({ scheme: L, w: HALF, reason: "grants-unreadable" }); return { node: b.node, w: HALF, h: b.h }; })());

  heading("PendingNotice, MenuItem, CountdownChip");
  note("A pending request is not a fault, so it gets an accent rule rather than amber, and it states how many are waiting. A menu row's detail column is computed from the text rather than guessed. A countdown is amber when a grant is about to lapse and quiet once it is inert.");
  pair("pending", (() => { const p = pendingNotice({ scheme: L, w: HALF, count: 1 }); return { node: p.node, w: HALF, h: p.h }; })(),
    (() => { const p = pendingNotice({ scheme: L, w: HALF, count: 3, body: "codex, exactmac-mcp and one more are waiting on you" }); return { node: p.node, w: HALF, h: p.h }; })());
  // Two rows of two, because four 290pt rows on one line needs 1220pt and the
  // specimen sheet is 1112pt wide. The gate caught the one-line version.
  const menuWrap = makeFrame(root, { name: "cc/menu", x: M, y, w: 600, h: 20, fill: cw(L, "surface") });
  const menuRow = (a, b) => {
    const r = makeFrame(null, { name: "menu-row", w: 600, h: 20, fill: cw(L, "surface") });
    flow(r, [a, b], { direction: "HORIZONTAL", gap: 20, align: "MIN", hugW: false, fixedW: 600 });
    return { node: r, w: 600, h: r.height };
  };
  flow(menuWrap, [
    menuRow(
      { node: menuItem({ scheme: L, w: 290, title: "Grants", detail: "3 active" }).node, w: 290, h: 28 },
      { node: menuItem({ scheme: L, w: 290, title: "Settings" }).node, w: 290, h: 28 },
    ),
    menuRow(
      { node: menuItem({ scheme: L, w: 290, title: "Reveal in Finder", variant: "disabled" }).node, w: 290, h: 28 },
      { node: menuItem({ scheme: L, w: 290, title: "Quit ExactMac", variant: "destructive" }).node, w: 290, h: 28 },
    ),
  ], { direction: "VERTICAL", gap: 8, hugW: false, fixedW: 600 });
  y += menuWrap.height + 40;
  strip("countdown", ["live", "soon", "expired"].map((st, i) => {
    const c = countdownChip({ scheme: L, state: st, label: ["3m 12s", "1m 04s", "expired"][i] });
    return { node: c.node, w: c.w, h: c.h };
  }));

  heading("GrantRow — consequence, scope, holder, origin, life left");
  note("The expired row is drawn rather than implied. A grant that silently disappears teaches the operator that the list is unreliable, so it stays visible and marked inert until it is dismissed.");
  pair("grant-a", (() => {
    const r = grantRow({
      scheme: L, w: HALF, consequence: "Read the clipboard in TextEdit",
      capability: "clipboard.read", breadth: "TextEdit only", duration: "for 5 minutes",
      holder: "exactmac-mcp", signature: SIGNATURE_STATES[1], origin: "prompt at 16:42",
      grantedAgo: "granted 4 minutes ago", countdown: "3m 12s",
    });
    return { node: r.node, w: HALF, h: r.h };
  })(), (() => {
    const r = grantRow({
      scheme: L, w: HALF, variant: "expired", consequence: "Read the clipboard in any app",
      capability: "clipboard.read", breadth: "every application", duration: "for 15 minutes",
      holder: "codex", signature: SIGNATURE_STATES[0], origin: "prompt at 15:58",
      grantedAgo: "expired 12 minutes ago", countdown: "expired",
    });
    return { node: r.node, w: HALF, h: r.h };
  })());

  heading("ActivityRow and IntegrityBadge");
  note("The decision word is in the ink as well as the dot, the basis is stated on every row, and the agent's reason carries the untrusted treatment because it is caller-supplied text shown beside system-derived fact. The chain's integrity is on the surface, because the log file is readable by any same-uid process.");
  pair("activity-a", (() => {
    const r = activityRow({
      scheme: L, w: HALF, decision: "allowed", time: "16:42:07",
      consequence: "Read the clipboard in TextEdit", capability: "clipboard.read · TextEdit only",
      basis: "Allowed by a grant you approved at 16:38 · expires in 3m 12s",
      identity: "exactmac-mcp · pid 4517", signature: SIGNATURE_STATES[1],
      reason: "Pasting the test fixture into the TextEdit scratch buffer.",
    });
    return { node: r.node, w: HALF, h: r.h };
  })(), (() => {
    const r = activityRow({
      scheme: L, w: HALF, decision: "denied", time: "16:39:52",
      consequence: "Run a shell command in any application", capability: "script.execute · every application",
      basis: "Denied — no grant matched, and you declined it in the prompt",
      identity: "codex · pid 8823", signature: SIGNATURE_STATES[0],
      reason: "Installing the fixture dependencies before the run.",
      note: "Use the scoped option next time — this reaches every app I have open.",
    });
    return { node: r.node, w: HALF, h: r.h };
  })());
  strip("integrity", ["verified", "broken", "unchecked"].map((st, i) => {
    const b = integrityBadge({
      scheme: L, state: st,
      label: ["Chain verified · 1,284 entries", "Chain broken at 1,283", "Not verified"][i],
    });
    return { node: b.node, w: b.w, h: b.h };
  }));

  heading("Posture, and the rows that are controls rather than preferences");
  note("Three postures and no permissive one: a posture that widens what may happen without asking is the vulnerability this product exists to remove, so the third is Locked down. The biometric requirements that must always be on say so on their own faces.");
  strip("posture", ["strict", "balanced", "locked"].map((p) => {
    const s = segmentedControl({ scheme: L, w: 360, selected: p });
    return { node: s.node, w: 360, h: s.h };
  }), 360 * 3 + 32, 16);
  pair("setting-a", (() => {
    const r = settingRow({
      scheme: L, w: HALF, variant: "toggle", on: true, locked: true,
      title: "Run a shell, AppleScript or JavaScript",
      desc: "A shell can read the screen, the clipboard and the interface, so no script runs without a fingerprint.",
    });
    return { node: r.node, w: HALF, h: r.h };
  })(), (() => {
    const r = settingRow({
      scheme: L, w: HALF, variant: "toggle", on: false,
      title: "Allow once — this exact request",
      desc: "A narrow one-shot ask is where friction is deliberately not spent.",
    });
    return { node: r.node, w: HALF, h: r.h };
  })());
  pair("setting-b", (() => {
    const r = settingRow({
      scheme: L, w: HALF, variant: "destructive", title: "Reset everything",
      desc: "Revoke every grant, empty the high-consequence list and restore the default posture. The decision log is append-only and is not erased.",
      action: { variant: "deny", label: "Reset ExactMac" },
    });
    return { node: r.node, w: HALF, h: r.h };
  })(), (() => {
    const r = settingRow({
      scheme: L, w: HALF, variant: "targets", title: "Applications that always escalate",
      desc: "Requests against these require a biometric whatever their breadth, and are never covered by an existing grant.",
      targets: [{ name: "1Password", listed: true }, { name: "Xcode", listed: true }],
    });
    return { node: r.node, w: HALF, h: r.h };
  })());
  strip("targets", [
    targetChip({ scheme: L, name: "1Password", listed: true }),
    targetChip({ scheme: L, name: "Keychain Access", listed: true }),
    targetChip({ scheme: L, name: "Add an application", listed: false }),
  ]);

  heading("Empty, loading, and the states where the data cannot be trusted");
  note("A surface with no empty state shows a blank panel when there is nothing to show, and a blank panel reads as a fault. Every error state also says what the system does about it, which for an unreadable grant store is deny: a store it cannot read must never be treated as an empty one.");
  pair("empty", (() => {
    const e = emptyState({
      scheme: L, w: HALF, surface: "grants", title: "No grants",
      body: "Nothing is permitted without asking. Every request that needs consent will prompt you.",
    });
    return { node: e.node, w: HALF, h: e.h };
  })(), (() => {
    const l = loadingSkeleton({ scheme: L, w: HALF, rows: 3 });
    return { node: l.node, w: HALF, h: l.h };
  })());
  pair("error", (() => {
    const e = errorState({ scheme: L, w: HALF, what: "grants" });
    return { node: e.node, w: HALF, h: e.h };
  })(), (() => {
    const e = errorState({ scheme: L, w: HALF, what: "audit" });
    return { node: e.node, w: HALF, h: e.h };
  })());

  root.resize(W, y);
  page.resize(W + 240, y + 240);
  return {
    page: "Components",
    consoleFamilies: [
      "ServiceStatus", "MenuBarItem", "ServiceToggle", "FailClosedBand", "PendingNotice",
      "MenuItem", "CountdownChip", "GrantRow", "ActivityRow", "IntegrityBadge",
      "SegmentedControl", "SettingRow", "TargetChip", "EmptyState", "LoadingSkeleton", "ErrorState",
    ],
  };
}

console.log("__RESULT__" + JSON.stringify(buildConsoleControls()));
