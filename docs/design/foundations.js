// Pure drawing code for the Foundations page. Runs inside the openpencil eval
// sandbox, where only `figma` and `console` exist — no Node APIs. TOKENS is
// prepended by build.js from docs/design/tokens.json, the single source of truth.
// Ids are never hardcoded: pages are resolved by name.
//
// Two hard-won constraints of this sandbox, both verified by probe rather than assumed:
//   1. A text node with no explicit size renders NOTHING. textAutoResize is not
//      implemented, so every text node is resized explicitly. The default 100x100 box
//      silently produced an empty canvas.
//   2. Token objects carry "$comment" keys for documentation. Iterating them feeds a
//      string into resize() and yields NaN geometry that is dropped without error, so
//      entries() filters out $-prefixed keys.
//
// Idempotent: clears the page before drawing, so re-running after a token change
// never accumulates duplicates.

function hexToRgb(hex) {
  const h = hex.replace("#", "");
  return {
    r: parseInt(h.slice(0, 2), 16) / 255,
    g: parseInt(h.slice(2, 4), 16) / 255,
    b: parseInt(h.slice(4, 6), 16) / 255,
  };
}

const solid = (hex) => [{ type: "SOLID", color: hexToRgb(hex), opacity: 1 }];

// Documentation keys are not tokens.
function entries(obj) {
  return Object.keys(obj)
    .filter((k) => k.charAt(0) !== "$")
    .map((k) => [k, obj[k]]);
}

// The sandbox has no text metrics, so width is estimated from the character count.
// 0.68 was calibrated against a rendered Inter specimen: 0.56 clipped real glyphs
// ("Space" rendered as "Spac"). Generous rather than tight, since text is
// left-aligned and a wide box is invisible.
const CHAR_W = 0.68;
function measure(chars, size) {
  return Math.max(24, Math.ceil(chars.length * size * CHAR_W));
}

function makeText(parent, o) {
  const t = figma.createText();
  t.name = o.name;
  // Figma requires fontName before characters.
  t.fontName = {
    family: o.mono ? TOKENS.type.designMono : TOKENS.type.designSans,
    style: o.style || "Regular",
  };
  t.characters = o.chars;
  t.fontSize = o.size;
  t.fills = solid(o.color);

  // Wrap to an explicit width when given; otherwise hug the estimated text width.
  const lineH = o.size * 1.45;
  let w, h;
  if (o.wrap) {
    w = o.wrap;
    h = Math.max(1, Math.ceil(measure(o.chars, o.size) / w)) * lineH;
  } else {
    w = measure(o.chars, o.size);
    h = lineH;
  }
  t.resize(w, h);

  parent.appendChild(t);
  t.x = o.x;
  t.y = o.y;
  return t;
}

function makeRect(parent, o) {
  const r = figma.createRectangle();
  r.name = o.name;
  r.resize(Math.max(1, o.w), Math.max(1, o.h));   // guard: NaN would vanish silently
  r.fills = solid(o.fill);
  if (o.stroke) {
    r.strokes = solid(o.stroke);
    r.strokeWeight = o.strokeWeight || 1;
  }
  if (o.radius) r.cornerRadius = o.radius;
  parent.appendChild(r);
  r.x = o.x;
  r.y = o.y;
  return r;
}

function makeFrame(parent, o) {
  const f = figma.createFrame();
  f.name = o.name;
  f.resize(Math.max(1, o.w), Math.max(1, o.h));
  f.fills = solid(o.fill);
  if (o.radius) f.cornerRadius = o.radius;
  if (o.stroke) {
    f.strokes = solid(o.stroke);
    f.strokeWeight = o.strokeWeight || 1;
  }
  f.clipsContent = true;
  parent.appendChild(f);
  f.x = o.x;
  f.y = o.y;
  return f;
}

const ORDER = [
  "surface", "surface-raised", "surface-sunken", "separator", "control-border",
  "text-primary", "text-secondary", "text-tertiary",
  "accent", "danger", "caution", "success",
];

// WCAG 2.1 relative luminance and contrast ratio, computed here so the specimen
// sheet carries its own accessibility evidence instead of asserting compliance.
function luminance(hex) {
  const x = hex.replace("#", "");
  const ch = (i) => {
    const c = parseInt(x.slice(i, i + 2), 16) / 255;
    return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
  };
  return 0.2126 * ch(0) + 0.7152 * ch(2) + 0.0722 * ch(4);
}
function contrast(a, b) {
  const l1 = luminance(a), l2 = luminance(b);
  const hi = Math.max(l1, l2), lo = Math.min(l1, l2);
  return (hi + 0.05) / (lo + 0.05);
}

// Colors that carry meaning as text or as a button fill, and so must clear AA.
const TEXTUAL = [
  "text-primary", "text-secondary", "text-tertiary",
  "accent", "danger", "caution", "success",
];

function buildFoundations() {
  const page = figma.root.children.find((p) => p.name === "Foundations");
  if (!page) throw new Error("Foundations page not found");

  // Clear the page so a re-run is exact, not additive.
  while (page.children.length > 0) page.children[0].remove();

  const W = TOKENS.layout.specimenWidth;
  const M = 64;
  const C = TOKENS.color;
  const R = TOKENS.radius;

  // Drawn on an explicit grid rather than an auto-layout stack: this is a
  // documentation artefact that must stay legible and diffable, not a component.
  // Screens and components use auto-layout, which is where the rule matters.
  const root = makeFrame(page, { name: "foundations", x: 0, y: 0, w: W, h: 400, fill: C.surface.light });
  let y = M;

  makeText(root, {
    name: "fnd/title", chars: "Foundations", size: 22, style: "Semibold",
    color: C["text-primary"].light, x: M, y,
  });
  y += 36;
  makeText(root, {
    name: "fnd/subtitle",
    chars: "ExactMac consent console. Generated from docs/design/tokens.json.",
    size: 13, color: C["text-secondary"].light, x: M, y,
  });
  y += 44;

  for (const scheme of ["light", "dark"]) {
    const isDark = scheme === "dark";
    // The sheet is light, so headings always use light-scheme ink; only the panel
    // below them switches to dark.
    makeText(root, {
      name: "fnd/color-" + scheme + "-label",
      chars: isDark ? "Dark" : "Light",
      size: 15, style: "Semibold",
      color: C["text-primary"].light,
      x: M, y,
    });
    y += 26;

    const inner = W - M * 2;
    const cellW = inner / ORDER.length;
    const panel = makeFrame(root, {
      name: "fnd/color-" + scheme,
      x: M, y, w: inner, h: 128,
      fill: isDark ? C.surface.dark : C.surface.light,
      radius: R["radius-lg"],
      stroke: isDark ? C.separator.dark : C.separator.light,
    });

    ORDER.forEach((token, i) => {
      const hex = C[token][scheme];
      const cx = i * cellW;
      // A hairline keeps a near-white swatch visible on the light panel.
      makeRect(panel, {
        name: "swatch-" + scheme + "-" + token,
        x: cx + 10, y: 12, w: cellW - 20, h: 44,
        fill: hex, radius: R["radius-sm"],
        stroke: C.separator[scheme],
      });
      makeText(panel, {
        name: "label-" + scheme + "-" + token, chars: token, size: 11,
        color: isDark ? C["text-secondary"].dark : C["text-secondary"].light,
        x: cx + 10, y: 64, wrap: cellW - 20,
      });
      makeText(panel, {
        name: "hex-" + scheme + "-" + token, chars: hex.toUpperCase(), size: 11, mono: true,
        color: isDark ? C["text-tertiary"].dark : C["text-tertiary"].light,
        x: cx + 10, y: 98, wrap: cellW - 20,
      });
    });
    y += 128 + 44;
  }

  // ---- contrast: the evidence behind the tertiary-ink decision
  makeText(root, {
    name: "fnd/contrast-label", chars: "Contrast", size: 15, style: "Semibold",
    color: C["text-primary"].light, x: M, y,
  });
  y += 26;
  const colW = (W - M * 2 - 24) / 2;
  for (const scheme of ["light", "dark"]) {
    const isDark = scheme === "dark";
    const bg = isDark ? C.surface.dark : C.surface.light;
    const panel = makeFrame(root, {
      name: "fnd/contrast-" + scheme,
      x: M + (isDark ? colW + 24 : 0), y, w: colW, h: 34 + TEXTUAL.length * 22,
      fill: bg, radius: R["radius-lg"],
      stroke: isDark ? C.separator.dark : C.separator.light,
    });
    makeText(panel, {
      name: "contrast-head-" + scheme,
      chars: (isDark ? "Dark" : "Light") + " on " + bg.toUpperCase(),
      size: 11, style: "Semibold", color: C["text-secondary"][scheme], x: 14, y: 10,
    });
    TEXTUAL.forEach((name, i) => {
      const hex = C[name][scheme];
      const r = contrast(hex, bg);
      const ok = r >= 4.5;
      const rowY = 30 + i * 22;
      makeText(panel, {
        name: "contrast-name-" + scheme + "-" + name, chars: name, size: 11, mono: true,
        color: C["text-primary"][scheme], x: 14, y: rowY,
      });
      makeText(panel, {
        name: "contrast-hex-" + scheme + "-" + name, chars: hex.toUpperCase(), size: 11, mono: true,
        color: C["text-tertiary"][scheme], x: 150, y: rowY,
      });
      makeText(panel, {
        name: "contrast-ratio-" + scheme + "-" + name,
        chars: r.toFixed(2) + ":1", size: 11, mono: true,
        color: C["text-secondary"][scheme], x: 250, y: rowY,
      });
      makeText(panel, {
        name: "contrast-status-" + scheme + "-" + name,
        chars: ok ? "AA" : "FAIL", size: 11, mono: true,
        color: ok ? C.success[scheme] : C.danger[scheme], x: 320, y: rowY,
      });
    });
  }
  y += 34 + TEXTUAL.length * 22 + 44;

  makeText(root, {
    name: "fnd/space-label", chars: "Space", size: 15, style: "Semibold",
    color: C["text-primary"].light, x: M, y,
  });
  y += 26;
  const spacePanel = makeFrame(root, {
    name: "fnd/space", x: M, y, w: W - M * 2, h: 92,
    fill: C["surface-raised"].light, radius: R["radius-lg"],
  });
  let sx = 20;
  for (const [name, v] of entries(TOKENS.space)) {
    makeRect(spacePanel, {
      name: "space-bar-" + name, x: sx, y: 18, w: v, h: 32,
      fill: C.accent.light, radius: R["radius-sm"],
    });
    makeText(spacePanel, {
      name: "space-label-" + name, chars: name.replace("space-", "") + " · " + v,
      size: 11, mono: true, color: C["text-secondary"].light, x: sx, y: 58,
    });
    sx += v + 30;
  }
  y += 92 + 44;

  makeText(root, {
    name: "fnd/radius-label", chars: "Radius", size: 15, style: "Semibold",
    color: C["text-primary"].light, x: M, y,
  });
  y += 26;
  let rx = M;
  for (const [name, v] of entries(TOKENS.radius)) {
    makeRect(root, {
      name: "radius-box-" + name, x: rx, y, w: 96, h: 64,
      fill: C["surface-raised"].light, radius: Math.min(v, 28),
      stroke: C.separator.light,
    });
    makeText(root, {
      name: "radius-label-" + name, chars: name.replace("radius-", "") + " · " + v,
      size: 11, mono: true, color: C["text-secondary"].light, x: rx, y: y + 72,
    });
    rx += 124;
  }
  y += 64 + 52;

  makeText(root, {
    name: "fnd/type-label", chars: "Type", size: 15, style: "Semibold",
    color: C["text-primary"].light, x: M, y,
  });
  y += 30;
  const metaX = M + 320;
  for (const step of TOKENS.type.scale) {
    // Sample is constrained to the left column so it cannot run into the meta
    // column; the row then advances by whichever is taller.
    const sample = makeText(root, {
      name: "type-sample-" + step.role, chars: step.sample, size: step.size,
      style: step.style, mono: !!step.mono, wrap: 300,
      color: step.mono ? C.accent.light : C["text-primary"].light,
      x: M, y,
    });
    makeText(root, {
      name: "type-meta-" + step.role,
      chars: step.role + " · " + step.size + " · " + step.style + (step.mono ? " · mono" : ""),
      size: 11, mono: true, color: C["text-tertiary"].light,
      x: metaX, y: y + Math.max(0, step.size * 0.35),
    });
    y += Math.max(sample.height, step.size * 1.5, 28) + 8;
  }
  y += 20;

  root.resize(W, y + M);
  page.resize(W + 240, y + M + 240);
  return { nodes: page.children.length, width: W, height: y + M, swatches: ORDER.length * 2 };
}

console.log("__RESULT__" + JSON.stringify(buildFoundations()));
