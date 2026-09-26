// Screens page, continued: the console's other surfaces — the menu-bar item and its
// popover, the grants manager, the activity timeline, settings, and the states where
// the system fails closed. B5 built the prompt; this builds everything the operator
// sees when no prompt is on screen, which is most of the time.
//
// TWO COMMITMENTS SHAPE EVERY SURFACE HERE.
//
// 1. A SURFACE THAT HAS NO EMPTY STATE SHOWS A BLANK PANEL when there is nothing to
//    show, and a blank panel reads as a fault. So normal, empty, loading and error are
//    all designed, for every surface.
//
// 2. THE FAIL-CLOSED STATES MUST READ AS PROTECTION, NOT AS A FAULT. An operator's
//    default reading of a stopped service is "something is broken", and the operator
//    needs to read it instead as "nothing is being automated, and here is why". So
//    those states are amber rather than red, and every one of them says what the
//    system is doing instead of the action it refused. Red stays reserved for a
//    denied or high-risk request.
//
// The states drawn here are the ones the design can name before any code exists:
// running, pending, console unreachable, server unreachable, the TCP server's reduced
// posture, and the service deliberately stopped.

const CWW = TOKENS.layout.windowWidth;   // 720
const CWP = TOKENS.layout.popoverWidth;  // 360
const CPAD = 16;
const CIN = CWW - CPAD * 2;              // 688
const PPAD = 14;
const PIN = CWP - PPAD * 2;              // 332

// A 1pt separator. Its own helper rather than prompt.js's `rule`, because both modules
// are concatenated into one script and a second declaration of the same name would be
// a duplicate binding in the sandbox.
function hairline(scheme, name, w) {
  return makeRect(null, { name: name, w: w, h: 1, fill: cw(scheme, "separator") });
}

function sectionLabel(scheme, chars, w) {
  return makeText(null, {
    name: "section", chars: chars, size: 10, style: "Semi Bold",
    color: cw(scheme, "text-tertiary"), wrap: w,
  });
}

// The chrome every window shares: a header carrying the title, the subtitle and one
// right-hand status affordance, a scrolling body, and an optional footer below a
// hairline. The header's right column is computed, never guessed, because a guessed
// width pushed the title's wrap box past its own row.
function consoleWindow(o) {
  const scheme = o.scheme || "light";
  const w = o.w || CWW;
  const pad = o.pad === undefined ? CPAD : o.pad;
  const inner = w - pad * 2;
  const win = makeComponent(null, {
    name: o.name, w: w, h: 120, fill: cw(scheme, "surface"),
    radius: CR["radius-lg"], stroke: cw(scheme, "separator"),
  });

  const rightW = o.right ? o.right.w : 0;
  const leftW = o.right ? inner - rightW - 12 : inner;
  const title = makeText(null, {
    name: "title", chars: o.title, size: 15, style: "Semi Bold",
    color: cw(scheme, "text-primary"), wrap: leftW,
  });
  const subtitle = makeText(null, {
    name: "subtitle", chars: o.subtitle, size: 11,
    color: cw(scheme, "text-secondary"), wrap: leftW,
  });
  const headLeft = makeFrame(null, {
    name: "head-left", w: leftW, h: 20, fill: cw(scheme, "surface"),
  });
  flow(headLeft, [{ node: title, w: leftW, h: title.height }, { node: subtitle, w: leftW, h: subtitle.height }], {
    direction: "VERTICAL", gap: 2, fixedW: leftW,
  });
  const head = makeFrame(null, { name: "head", w: inner, h: 20, fill: cw(scheme, "surface") });
  const headItems = [{ node: headLeft, w: leftW, h: headLeft.height }];
  if (o.right) headItems.push({ node: o.right.node, w: o.right.w, h: o.right.h });
  flow(head, headItems, {
    direction: "HORIZONTAL", gap: 12, align: "CENTER", hugW: false, fixedW: inner,
  });

  const body = makeFrame(null, { name: "body", w: inner, h: 20, fill: cw(scheme, "surface") });
  flow(body, o.body, {
    direction: "VERTICAL", gap: o.bodyGap === undefined ? 8 : o.bodyGap, fixedW: inner,
  });

  const out = [
    { node: head, w: inner, h: head.height },
    { node: body, w: inner, h: body.height },
  ];
  if (o.footer && o.footer.length) {
    const foot = makeFrame(null, { name: "footer", w: inner, h: 20, fill: cw(scheme, "surface") });
    flow(foot, o.footer, { direction: "VERTICAL", gap: 8, fixedW: inner });
    out.push({ node: hairline(scheme, "footer-rule", inner), w: inner, h: 1 });
    out.push({ node: foot, w: inner, h: foot.height });
  }
  flow(win, out, {
    direction: "VERTICAL", gap: 12, padLeft: pad, padRight: pad, padTop: 14, padBottom: 14,
    hugW: false, fixedW: w,
  });
  return { node: win, w: w, h: win.height };
}

// ------------------------------------------------------------------ the popover
//
// B1's control lives here, and the popover is also where a stopped or degraded system
// becomes legible without opening a window. The state block is the difference between
// the states: `normal` has none, because a calm system should look calm, and every
// other state says what is being denied and why.

const POPOVER_STATE_BLOCK = {
  pending: (scheme) => pendingNotice({ scheme, w: PIN, count: 1 }),
  "console-unreachable": (scheme) => failClosedBand({ scheme, w: PIN, reason: "console-unreachable" }),
  "server-unreachable": (scheme) => failClosedBand({ scheme, w: PIN, reason: "server-unreachable" }),
  "tcp-reduced": (scheme) => failClosedBand({ scheme, w: PIN, reason: "tcp-reduced" }),
  stopped: (scheme) => failClosedBand({ scheme, w: PIN, reason: "stopped" }),
};

const POPOVER_STATUS = {
  normal: "running", pending: "running", "console-unreachable": "unreachable",
  "server-unreachable": "degraded", "tcp-reduced": "reduced", stopped: "stopped",
};

const POPOVER_HEADLINE = {
  normal: "Balanced — friction scales with what a grant would permit",
  pending: "Balanced — one request is waiting for you",
  "console-unreachable": "Every request that needs consent is being denied",
  "server-unreachable": "Nothing can be requested while the service is down",
  "tcp-reduced": "TCP listener: no approvals and no identity",
  stopped: "The service is off, so nothing is served",
};

// The transport line and the toggle's own sentence are CLAIMS about how the service is
// reached, so they are per state. Both used to be constant, which made the TCP popover
// assert "Unix socket · launchd-managed · no network listener" directly beneath a band
// saying it is listening on TCP, and made an unreachable server claim it was running.
const POPOVER_TRANSPORT = {
  normal: "Unix socket · launchd-managed · no network listener",
  pending: "Unix socket · launchd-managed · no network listener",
  "console-unreachable": "Unix socket · launchd-managed · the console is not running",
  "server-unreachable": "Unix socket · launchd-managed · the service is not answering",
  "tcp-reduced": "TCP listener · no owning user to authenticate",
  stopped: "Unix socket · launchd-managed · disabled",
};

const POPOVER_TOGGLE_NOTE = {
  normal: null,
  pending: null,
  "console-unreachable": null,
  "server-unreachable": "Enabled, but not answering. It comes back on its own when it does.",
  "tcp-reduced": "Enabled, and listening on TCP where nothing can be authenticated.",
  stopped: null,
};

function menuBarPopover(o) {
  const scheme = o.scheme || "light";
  const state = o.state || "normal";
  const pop = makeComponent(null, {
    name: "MenuBarPopover/" + state, w: CWP, h: 360,
    fill: cw(scheme, "surface"), radius: CR["radius-lg"], stroke: cw(scheme, "separator"),
  });

  const pill = serviceStatus({ scheme, state: POPOVER_STATUS[state] });
  const title = makeText(null, {
    name: "title", chars: "ExactMac", size: 15, style: "Semi Bold",
    color: cw(scheme, "text-primary"), wrap: PIN - pill.w - 12,
  });
  const titleRow = makeFrame(null, { name: "title-row", w: PIN, h: 20, fill: cw(scheme, "surface") });
  flow(titleRow, [
    { node: title, w: PIN - pill.w - 12, h: title.height },
    { node: pill.node, w: pill.w, h: pill.h },
  ], { direction: "HORIZONTAL", gap: 12, align: "CENTER", mainAlign: "SPACE_BETWEEN", hugW: false, fixedW: PIN });
  const headline = makeText(null, {
    name: "headline", chars: POPOVER_HEADLINE[state], size: 11,
    color: cw(scheme, "text-secondary"), wrap: PIN,
  });
  const head = makeFrame(null, { name: "head", w: PIN, h: 20, fill: cw(scheme, "surface") });
  flow(head, [
    { node: titleRow, w: PIN, h: titleRow.height },
    { node: headline, w: PIN, h: headline.height },
  ], { direction: "VERTICAL", gap: 4, fixedW: PIN });

  const stack = makeFrame(null, { name: "stack", w: PIN, h: 40, fill: cw(scheme, "surface") });
  const items = [{ node: head, w: PIN, h: head.height }];
  if (POPOVER_STATE_BLOCK[state]) {
    const block = POPOVER_STATE_BLOCK[state](scheme);
    items.push({ node: block.node, w: PIN, h: block.h });
  }

  // B1: the control is the first thing below the state, and its own row says the
  // state persists, because a toggle an operator believes is a preference will not be
  // trusted to stop a service.
  const toggle = serviceToggle({
    scheme, w: PIN, state: state === "stopped" ? "off" : "on",
    note: POPOVER_TOGGLE_NOTE[state],
  });
  items.push({ node: toggle.node, w: PIN, h: toggle.h });
  // And the clause that makes re-enabling safe to offer at all: a stop is not a
  // revoke, and re-enabling must not quietly restore what the operator removed.
  items.push({
    node: makeText(null, {
      name: "toggle-note", size: 10, color: cw(scheme, "text-tertiary"), wrap: PIN,
      chars: "Turning it back on does not restore grants you revoked.",
    }),
    w: PIN,
  });

  const menu = [
    menuItem({ scheme, w: PIN, title: "Grants", detail: o.grantCount || "3 active" }),
    menuItem({ scheme, w: PIN, title: "Activity", detail: "1,284" }),
    menuItem({ scheme, w: PIN, title: "Settings" }),
  ];
  const list = makeFrame(null, { name: "menu", w: PIN, h: 20, fill: cw(scheme, "surface") });
  flow(list, menu.map((m) => ({ node: m.node, w: PIN, h: m.h })), {
    direction: "VERTICAL", gap: 2, fixedW: PIN,
  });
  items.push({ node: hairline(scheme, "menu-rule", PIN), w: PIN, h: 1 });
  items.push({ node: list, w: PIN, h: list.height });
  const quit = menuItem({ scheme, w: PIN, title: "Quit ExactMac", variant: "destructive" });
  items.push({ node: hairline(scheme, "quit-rule", PIN), w: PIN, h: 1 });
  items.push({ node: quit.node, w: PIN, h: quit.h });
  items.push({
    node: makeText(null, {
      name: "transport", chars: POPOVER_TRANSPORT[state],
      size: 10, color: cw(scheme, "text-tertiary"), wrap: PIN,
    }),
    w: PIN,
  });

  flow(stack, items, { direction: "VERTICAL", gap: 10, fixedW: PIN });
  flow(pop, [{ node: stack, w: PIN, h: stack.height }], {
    direction: "VERTICAL", padLeft: PPAD, padRight: PPAD, padTop: PPAD, padBottom: PPAD,
    hugW: false, fixedW: CWP,
  });
  return { node: pop, w: CWP, h: pop.height };
}

// ------------------------------------------------------------- the grants manager
//
// A grant the operator cannot see is a grant they cannot revoke, so every row states
// the CONSEQUENCE rather than only the capability, the full scope, who holds it, which
// request created it, and how much life is left. The expired row is drawn rather than
// implied: it stays visible, marked inert, because a grant that silently disappears
// teaches the operator that the list is unreliable.

const GRANTS = [
  {
    variant: "normal",
    consequence: "Read the clipboard in TextEdit",
    capability: "clipboard.read", breadth: "TextEdit only", duration: "for 5 minutes",
    holder: "exactmac-mcp", signature: 1, origin: "prompt at 16:42",
    grantedAgo: "granted 4 minutes ago", countdown: "3m 12s", expiring: false,
  },
  {
    variant: "normal",
    consequence: "Type and click as you, in any app",
    capability: "input.synthesize", breadth: "every application", duration: "for 8 hours",
    holder: "exactmac-mcp", signature: 3, origin: "prompt at 16:38",
    grantedAgo: "granted 8 minutes ago", countdown: "1m 04s", expiring: true,
  },
  {
    variant: "normal",
    consequence: "Read the accessibility tree of any app",
    capability: "observation.ax", breadth: "every application", duration: "inside an envelope",
    holder: "codex", signature: 0, origin: "envelope approved at 16:30",
    grantedAgo: "envelope has 1h 52m left", countdown: "1h 52m", expiring: false,
  },
  {
    variant: "expired",
    consequence: "Read the clipboard in any app",
    capability: "clipboard.read", breadth: "every application", duration: "for 15 minutes",
    holder: "codex", signature: 0, origin: "prompt at 15:58",
    grantedAgo: "expired 12 minutes ago", countdown: "expired", expiring: false,
  },
];

function grantsManager(o) {
  const scheme = o.scheme || "light";
  const variant = o.variant || "normal";
  const subtitles = {
    normal: "4 listed · 1 expires within a minute",
    empty: "None active",
    loading: "Reading the grant store",
    error: "Unavailable",
  };
  let body;
  if (variant === "empty") {
    const e = emptyState({
      scheme, w: CIN, surface: "grants",
      title: "No grants",
      body: "Nothing is permitted without asking. Every request that needs consent will prompt you, and every decision you make here is shown in Activity.",
    });
    body = [{ node: e.node, w: CIN, h: e.h }];
  } else if (variant === "loading") {
    const l = loadingSkeleton({ scheme, w: CIN, rows: 3 });
    body = [{ node: l.node, w: CIN, h: l.h }];
  } else if (variant === "error") {
    const e = errorState({ scheme, w: CIN, what: "grants" });
    body = [{ node: e.node, w: CIN, h: e.h }];
  } else {
    body = GRANTS.map((g) => {
      const r = grantRow({
        scheme, w: CIN, variant: g.variant, consequence: g.consequence,
        capability: g.capability, breadth: g.breadth, duration: g.duration,
        holder: g.holder, signature: SIGNATURE_STATES[g.signature], origin: g.origin,
        grantedAgo: g.grantedAgo, countdown: g.countdown, expiring: g.expiring,
      });
      return { node: r.node, w: CIN, h: r.h };
    });
  }
  const footer = variant === "normal" ? [
    (() => {
      const b = biometricState({
        scheme, w: CIN, label: "Touch ID will confirm: revoke every grant at once",
      });
      return { node: b.node, w: CIN, h: b.h };
    })(),
    (() => {
      const b = button({ variant: "caution", scheme, label: "Revoke every grant" });
      return { node: b.node, w: b.w, h: b.h };
    })(),
    {
      node: makeText(null, {
        name: "revoke-note", size: 10, color: cw(scheme, "text-tertiary"), wrap: CIN,
        chars: "Revocation is immediate and survives a restart. An envelope is revoked as a unit, never partially.",
      }),
      w: CIN,
    },
  ] : [];
  return consoleWindow({
    scheme, w: CWW, name: "GrantsManager/" + variant, title: "Grants",
    subtitle: subtitles[variant], body, footer,
  });
}

// -------------------------------------------------------- the activity timeline
//
// The operator-facing view of the decision audit. It shows what was asked, by whom, on
// what BASIS it was allowed or denied, and whether a biometric was required — because
// a log that records only outcomes cannot answer "was that reasonable". The chain's
// integrity is on the surface, not in a log line: the file is readable by any same-uid
// process, so a doctored log has to look doctored.

const ACTIVITY = [
  {
    decision: "allowed", time: "16:42:07",
    consequence: "Read the clipboard in TextEdit",
    capability: "clipboard.read · TextEdit only",
    basis: "Allowed by a grant you approved at 16:38 · expires in 3m 12s",
    identity: "exactmac-mcp · pid 4517", signature: 1,
    reason: "Pasting the test fixture into the TextEdit scratch buffer.",
  },
  {
    decision: "denied", time: "16:39:52",
    consequence: "Run a shell command in any application",
    capability: "script.execute · every application",
    basis: "Denied — no grant matched, and you declined it in the prompt",
    identity: "codex · pid 8823", signature: 0,
    reason: "Installing the fixture dependencies before the run.",
    note: "Use the scoped option next time — this reaches every app I have open.",
  },
  {
    decision: "allowed", time: "16:31:02",
    consequence: "Read the accessibility tree of any app",
    capability: "observation.ax · every application",
    basis: "Allowed inside a pre-authorization envelope · 1h 52m left · Touch ID confirmed",
    identity: "codex · pid 8823", signature: 0,
    reason: "Mapping the parser's element tree before refactoring it.",
  },
];

function activityTimeline(o) {
  const scheme = o.scheme || "light";
  const variant = o.variant || "normal";
  const integrity = {
    normal: { state: "verified", label: "Chain verified · 1,284 entries" },
    broken: { state: "broken", label: "Chain broken at entry 1,283" },
    empty: { state: "unchecked", label: "Nothing to verify" },
    loading: { state: "unchecked", label: "Not verified" },
    error: { state: "unchecked", label: "Not verified" },
  }[variant];
  const subtitles = {
    normal: "Today · newest first",
    broken: "Today · entries after 1,283 are untrusted",
    empty: "Nothing recorded yet",
    loading: "Reading the decision log",
    error: "Unavailable",
  };
  const badge = integrityBadge({ scheme, state: integrity.state, label: integrity.label });
  let body;
  if (variant === "empty") {
    const e = emptyState({
      scheme, w: CIN, surface: "activity",
      title: "No activity yet",
      body: "Every decision will appear here: what was asked, by whom, and whether a grant, your prompt or an envelope allowed it.",
    });
    body = [{ node: e.node, w: CIN, h: e.h }];
  } else if (variant === "loading") {
    const l = loadingSkeleton({ scheme, w: CIN, rows: 4 });
    body = [{ node: l.node, w: CIN, h: l.h }];
  } else if (variant === "error") {
    const e = errorState({ scheme, w: CIN, what: "activity", action: "Try again" });
    body = [{ node: e.node, w: CIN, h: e.h }];
  } else {
    body = ACTIVITY.map((a) => {
      const r = activityRow({
        scheme, w: CIN, decision: a.decision, time: a.time, consequence: a.consequence,
        capability: a.capability, basis: a.basis, identity: a.identity,
        signature: SIGNATURE_STATES[a.signature], reason: a.reason, note: a.note,
      });
      return { node: r.node, w: CIN, h: r.h };
    });
    if (variant === "broken") {
      const e = errorState({ scheme, w: CIN, what: "audit" });
      body.push({ node: e.node, w: CIN, h: e.h });
    }
  }
  const footer = variant === "normal" || variant === "broken" ? [
    {
      node: makeText(null, {
        name: "chain-note", size: 10, color: cw(scheme, "text-tertiary"), wrap: CIN,
        chars: "The log is append-only and hash-chained: removing or editing an entry breaks the chain and is shown here rather than hidden.",
      }),
      w: CIN,
    },
  ] : [];
  return consoleWindow({
    scheme, w: CWW, name: "ActivityTimeline/" + variant, title: "Activity",
    subtitle: subtitles[variant], right: badge, body, footer,
  });
}

// --------------------------------------------------------------------- settings
//
// Posture, the biometric requirements, the operator's own high-consequence targets,
// the console lock, and the destructive reset. Two of those five are security
// controls rather than preferences, and they are drawn so they cannot be mistaken for
// preferences: the biometric requirements that must always be on say so on their face.

const BIOMETRIC_ROWS = [
  {
    title: "Run a shell, AppleScript or JavaScript",
    desc: "A shell can read the screen, the clipboard and the interface, so no script runs without a fingerprint.",
    on: true, locked: true,
  },
  {
    title: "Grant every application, indefinitely",
    desc: "The broadest grant there is. It is a standing permission, so it is worth proving you are you.",
    on: true, locked: true,
  },
  {
    title: "Observe any application continuously",
    desc: "Sustained reading of everything on screen, in any application, for the life of the grant.",
    on: true, locked: true,
  },
  {
    title: "Revoke every grant at once",
    desc: "Wiping every standing permission is exactly the moment a stolen session would want.",
    on: true, locked: true,
  },
  {
    title: "Allow once — this exact request",
    desc: "A narrow one-shot ask is where friction is deliberately not spent. Turning this on makes every trivial request cost a fingerprint.",
    on: false, locked: false,
  },
];

function settingsWindow(o) {
  const scheme = o.scheme || "light";
  const body = [];

  const posture = o.posture || "balanced";
  body.push({ node: sectionLabel(scheme, "POSTURE", CIN), w: CIN, h: 15 });
  const seg = segmentedControl({ scheme, w: CIN, selected: posture });
  body.push({ node: seg.node, w: CIN, h: seg.h });
  const postureDesc = makeText(null, {
    name: "posture-desc", size: 11, color: cw(scheme, "text-secondary"), wrap: CIN,
    chars: POSTURES.find((p) => p.key === posture).desc,
  });
  body.push({ node: postureDesc, w: CIN, h: postureDesc.height });

  body.push({ node: sectionLabel(scheme, "BIOMETRIC REQUIREMENTS", CIN), w: CIN, h: 15 });
  for (const b of BIOMETRIC_ROWS) {
    const r = settingRow({ scheme, w: CIN, variant: "toggle", on: b.on, locked: b.locked, title: b.title, desc: b.desc });
    body.push({ node: r.node, w: CIN, h: r.h });
  }

  body.push({ node: sectionLabel(scheme, "HIGH-CONSEQUENCE TARGETS", CIN), w: CIN, h: 15 });
  const targets = settingRow({
    scheme, w: CIN, variant: "targets",
    title: "Applications that always escalate",
    desc: "Requests against these require a biometric whatever their breadth, and are never covered by an existing grant. Consequence is a fact about your life, so you name it.",
    targets: [
      { name: "1Password", listed: true },
      { name: "Keychain Access", listed: true },
      { name: "Xcode", listed: true },
      { name: "Add an application", listed: false },
    ],
  });
  body.push({ node: targets.node, w: CIN, h: targets.h });

  body.push({ node: sectionLabel(scheme, "CONSOLE", CIN), w: CIN, h: 15 });
  const lock = settingRow({
    scheme, w: CIN, variant: "toggle", on: true,
    title: "Require Touch ID to open the console",
    desc: "Opening the console reveals what is permitted and what was asked. Without this, anyone at the keyboard can read both.",
  });
  body.push({ node: lock.node, w: CIN, h: lock.h });

  body.push({ node: sectionLabel(scheme, "RESET", CIN), w: CIN, h: 15 });
  const reset = settingRow({
    scheme, w: CIN, variant: "destructive",
    title: "Reset everything",
    desc: "Revoke every grant, empty the high-consequence list and restore the default posture. The decision log is append-only and is not erased.",
    action: { variant: "deny", label: "Reset ExactMac" },
  });
  body.push({ node: reset.node, w: CIN, h: reset.h });

  return consoleWindow({
    scheme, w: CWW, name: "SettingsWindow/normal", title: "Settings",
    subtitle: "Owner-private · stored under your own account", body, bodyGap: 8,
  });
}

// -------------------------------------------------------------------- the page
//
// The sheet prompt.js already drew is CONTINUED, not replaced, for the same reason
// controls.js continues identity.js: a page may be composed of several modules, and the
// module that owns clearing still has to run.

function buildConsole() {
  const page = figma.root.children.find((p) => p.name === "Screens");
  if (!page) throw new Error("Screens page not found");
  const root = page.children[0];
  if (!root) throw new Error("prompt.js must render the page root first");
  const L = "light";
  const M = 64;
  const W = root.width;
  const INNER = W - M * 2;

  let y = root.height + 48;

  const heading = (chars) => {
    const t = makeText(root, {
      name: "scr/h", chars, size: 15, style: "Semi Bold", color: cw(L, "text-primary"), x: M, y,
    });
    y += t.height + 20;
  };
  const note = (chars) => {
    const t = makeText(root, {
      name: "scr/note", chars, size: 11, color: cw(L, "text-tertiary"), x: M, y, wrap: INNER,
    });
    y += t.height + 18;
  };
  const row = (name, items) => {
    // The row is sized to its CONTENT plus its own gap. A hand-written width was
    // wrong twice — the four-popover row declared 1488 against an actual 1512, because
    // the 24pt gap was not counted — and a wrong width here is an invisible bug that
    // only the overflow gate can see.
    const gap = 24;
    const w = items.reduce((a, it) => a + (it.w || 0), 0) + gap * Math.max(0, items.length - 1);
    if (w > INNER) throw new Error(name + " is " + w + "pt wide, past the " + INNER + "pt sheet");
    const r = makeFrame(root, { name: name, x: M, y, w: w, h: 20, fill: cw(L, "surface") });
    flow(r, items, { direction: "HORIZONTAL", gap: gap, align: "MIN", hugW: false, fixedW: w });
    y += r.height + 40;
  };

  // ---- the menu-bar item, and the popover behind it
  heading("The menu-bar item, and the popover behind it");
  note("The item is icon-only and 22pt, so the only thing that must survive at that size is the state. The popover names the state in words, because a dot cannot distinguish \"degraded\" from \"reduced\".");
  const barItems = makeFrame(root, { name: "scr/menubar", x: M, y, w: 400, h: 22, fill: cw(L, "surface") });
  flow(barItems, SERVICE_STATES.map((s) => {
    const it = menuBarItem({ scheme: L, state: s.key });
    return { node: it.node, w: it.w, h: it.h };
  }), { direction: "HORIZONTAL", gap: 24, align: "CENTER" });
  y += barItems.height + 16;
  note("Running · Degraded · Reduced · Stopped · No console");
  y += 8;
  row("scr/popover", [
    menuBarPopover({ scheme: "light", state: "normal" }),
    menuBarPopover({ scheme: "light", state: "pending" }),
    menuBarPopover({ scheme: "dark", state: "pending" }),
  ]);

  // ---- the states where the answer is deny
  heading("Failing closed — four states where the answer is deny, and each says so");
  note("Amber, not red: red is reserved for a denied or high-risk request. Each of these says what the system is doing instead of the action it refused, because a stopped service that reads as a fault teaches the operator to work around it.");
  row("scr/failclosed", [
    menuBarPopover({ scheme: "light", state: "console-unreachable" }),
    menuBarPopover({ scheme: "light", state: "server-unreachable" }),
    menuBarPopover({ scheme: "light", state: "tcp-reduced" }),
    menuBarPopover({ scheme: "light", state: "stopped" }),
  ]);
  row("scr/failclosed-dark", [
    menuBarPopover({ scheme: "dark", state: "console-unreachable" }),
    menuBarPopover({ scheme: "dark", state: "tcp-reduced" }),
  ]);

  // ---- grants manager
  heading("Grants manager — a grant you cannot see is a grant you cannot revoke");
  note("Every row states the consequence, the full scope, who holds it, which request created it and how much life is left. The expired row stays visible and inert rather than vanishing, because a list that silently changes teaches the operator to distrust it.");
  row("scr/grants-pair", [
    grantsManager({ scheme: "light", variant: "normal" }),
    grantsManager({ scheme: "dark", variant: "normal" }),
  ]);
  row("scr/grants-states", [
    grantsManager({ scheme: "light", variant: "empty" }),
    grantsManager({ scheme: "light", variant: "loading" }),
  ]);
  row("scr/grants-error", [
    grantsManager({ scheme: "light", variant: "error" }),
    settingsWindow({ scheme: "light" }),
  ]);

  // ---- activity timeline
  heading("Activity — what was asked, by whom, and on what basis");
  note("The agent's reason is drawn with the untrusted treatment, beside system-derived fact, because it is caller-supplied text. Your note is not: it is yours, and it went back to the agent.");
  row("scr/activity-pair", [
    activityTimeline({ scheme: "light", variant: "normal" }),
    activityTimeline({ scheme: "dark", variant: "normal" }),
  ]);
  row("scr/activity-broken", [
    activityTimeline({ scheme: "light", variant: "broken" }),
    activityTimeline({ scheme: "dark", variant: "broken" }),
  ]);
  row("scr/activity-states", [
    activityTimeline({ scheme: "light", variant: "empty" }),
    activityTimeline({ scheme: "light", variant: "error" }),
  ]);

  // ---- settings
  heading("Settings — two of these five are security controls, and they are drawn so they cannot be mistaken for preferences");
  note("Consequence is a fact about the operator's life, so the high-consequence list is theirs to name. The biometric requirements that must always be on say so on their own faces, because a row that merely looked optional would be switched off.");
  row("scr/settings-pair", [
    settingsWindow({ scheme: "light" }),
    settingsWindow({ scheme: "dark" }),
  ]);

  root.resize(W, y);
  page.resize(W + 240, y + 240);
  return {
    page: "Screens",
    popovers: ["normal", "pending", "console-unreachable", "server-unreachable", "tcp-reduced", "stopped"],
    menuBarStates: SERVICE_STATES.map((s) => s.key),
    grants: ["normal", "empty", "loading", "error"],
    activity: ["normal", "broken", "empty", "error"],
    settings: ["normal"],
  };
}

console.log("__RESULT__" + JSON.stringify(buildConsole()));
