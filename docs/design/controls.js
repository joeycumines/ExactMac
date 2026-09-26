// Components page layout, continued: the control vocabulary, drawn as a specimen
// sheet. The factories live in widgets.js. This module draws into the root that
// identity.js created, so it must run after it.

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
