// Shared drawing primitives for the ExactMac console design pages.
//
// Prepended to each page module by build.js and evaluated inside the openpencil
// sandbox, where only `figma` and `console` exist. Two sandbox constraints are
// encoded here rather than left to each page to rediscover:
//
//   1. An unsized text node renders NOTHING. textAutoResize is unimplemented, so
//      the node keeps the default 100x100 box and the page exports blank while
//      still reporting a full node count. Every text node is sized explicitly.
//   2. Token objects carry "$comment" keys. Iterating one feeds a string into
//      resize() and yields NaN geometry that is dropped with no error, so
//      entries() filters $-prefixed keys and sizes are clamped.
//
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

// The sandbox has no text metrics. A SINGLE average advance is not safe: lowercase
// runs containing w/m/M/W are far wider than average, and an average sized to them
// over-allocates everything else. Under-allocating CLIPS INK — a silent, serious
// failure — so this estimates per character class, in em, for Inter, and then adds a
// margin. Verified against rendered specimens: "unknown" (four narrow letters and a
// w) clipped at a flat 0.58 and fits here.
const EM = (() => {
  const narrow = "iljtfrIJ.,;:!|'`()[]{}/\\-";
  const wide = "mwMW@%";
  const upper = "ABCDEFGHKLNOPQRSTUVXYZ";
  // Calibrated so that a string which was observed clipping at a flat 0.58 now
  // measures WIDER than it needs: "unknown" is six ordinary lowercase letters plus
  // a w, and Inter's lowercase advance is close to 0.55 em, not 0.42.
  return (ch) => {
    if (ch === " ") return 0.28;
    if (narrow.includes(ch)) return 0.31;
    if (wide.includes(ch)) return 0.88;
    if (upper.includes(ch)) return 0.68;
    if (ch >= "0" && ch <= "9") return 0.60;
    return 0.55;
  };
})();
const WEIGHT_W = { Regular: 1, Medium: 1.04, "Semi Bold": 1.09, Bold: 1.13 };
const MEASURE_MARGIN = 1.06;   // absorbs the estimate's residual error
const LINE_H = 1.45;
function measure(chars, size, style) {
  let em = 0;
  for (const ch of chars) em += EM(ch);
  // The floor is small on purpose: a 24pt floor made every 1-2 character string
  // (a step number, a digit in a circle) measure 24pt, compute two lines in an 18pt
  // box, and sit high in its own badge.
  return Math.max(8, Math.ceil(em * size * (WEIGHT_W[style] || 1) * MEASURE_MARGIN));
}

function makeText(parent, o) {
  const t = figma.createText();
  t.name = o.name;
  // Figma requires fontName before characters.
  t.fontName = {
    // designMono is null because the renderer bundles no monospace family; a
    // mono-styled node falls back to the sans rather than asking for null. The
    // mono INTENT stays recorded in tokens.json for the app to honour.
    family: (o.mono && TOKENS.type.designMono) || TOKENS.type.designSans,
    style: o.style || "Regular",
  };
  t.characters = o.chars;
  t.fontSize = o.size;
  t.fills = solid(o.color);
  if (o.align) t.textAlignHorizontal = o.align;
  if (o.mono) t.characters = o.chars;

  const lineH = o.size * LINE_H;
  const style = o.style || "Regular";
  let w, h;
  if (o.wrap) {
    w = o.wrap;
    h = Math.max(1, Math.ceil(measure(o.chars, o.size, style) / w)) * lineH;
  } else {
    w = measure(o.chars, o.size, style);
    h = lineH;
  }
  t.resize(Math.max(1, w), Math.max(1, h));

  if (parent) parent.appendChild(t);
  t.x = o.x || 0;
  t.y = o.y || 0;
  return t;
}

function makeRect(parent, o) {
  const r = figma.createRectangle();
  r.name = o.name;
  r.resize(Math.max(1, o.w || 0), Math.max(1, o.h || 0));   // clamp: NaN vanishes silently
  r.fills = solid(o.fill);
  if (o.stroke) {
    r.strokes = solid(o.stroke);
    r.strokeWeight = o.strokeWeight || 1;
  }
  if (o.radius) r.cornerRadius = o.radius;
  if (parent) parent.appendChild(r);
  r.x = o.x || 0;
  r.y = o.y || 0;
  return r;
}

function makeFrame(parent, o) {
  const f = figma.createFrame();
  f.name = o.name;
  f.resize(Math.max(1, o.w || 0), Math.max(1, o.h || 0));
  f.fills = solid(o.fill);
  if (o.radius) f.cornerRadius = o.radius;
  if (o.stroke) {
    f.strokes = solid(o.stroke);
    f.strokeWeight = o.strokeWeight || 1;
  }
  f.clipsContent = o.clips !== false;
  if (parent) parent.appendChild(f);
  f.x = o.x || 0;
  f.y = o.y || 0;
  return f;
}

// Turn a frame into a component, which is what the implementation tasks will cite.
function makeComponent(parent, o) {
  const c = figma.createComponent();
  c.name = o.name;
  c.resize(Math.max(1, o.w || 0), Math.max(1, o.h || 0));
  c.fills = solid(o.fill);
  if (o.radius) c.cornerRadius = o.radius;
  if (o.stroke) {
    c.strokes = solid(o.stroke);
    c.strokeWeight = o.strokeWeight || 1;
  }
  c.clipsContent = o.clips !== false;
  if (parent) parent.appendChild(c);
  c.x = o.x || 0;
  c.y = o.y || 0;
  return c;
}

// Auto-layout. The sandbox has no figma.setLayoutMode, but assigning the property
// works, as do itemSpacing, padding, and the HUG/FILL sizing modes.
function auto(node, direction, o) {
  o = o || {};
  node.layoutMode = direction;                    // "HORIZONTAL" | "VERTICAL"
  node.primaryAxisSizingMode = o.hugMain === false ? "FIXED" : "AUTO";
  node.counterAxisSizingMode = o.fixedCross ? "FIXED" : "AUTO";
  if (o.spacing !== undefined) node.itemSpacing = o.spacing;
  const p = o.padding === undefined ? 0 : o.padding;
  node.paddingLeft = o.padLeft !== undefined ? o.padLeft : p;
  node.paddingRight = o.padRight !== undefined ? o.padRight : p;
  node.paddingTop = o.padTop !== undefined ? o.padTop : p;
  node.paddingBottom = o.padBottom !== undefined ? o.padBottom : p;
  if (o.align) node.counterAxisAlignItems = o.align;
  if (o.mainAlign) node.primaryAxisAlignItems = o.mainAlign;
  if (o.wrap) node.layoutWrap = "WRAP";
  return node;
}

// THE SANDBOX STORES layoutMode BUT NEVER RUNS THE LAYOUT ENGINE. Children keep
// whatever x/y they were handed, so an auto-layout container renders as a pile of
// children at the origin: all six SignatureBadges on top of each other, only the
// last IdentityRow visible. Verified by rendering, not inferred.
//
// So flow() both ATTACHES and POSITIONES each child explicitly, and sets the
// auto-layout properties that reproduce the same geometry in a tool that does lay
// out. The file is therefore correct in this renderer AND semantically auto-layout
// for anyone who opens it elsewhere. Items are {node} or {node, w, h}; sizes are
// required because the engine that would measure them is the one that does not run.
//
// Attaching here rather than at each call site is deliberate: an unattached child
// is silently invisible, which is how IdentityRow, ProcessTree and UntrustedField
// all first rendered as empty boxes.
function flow(parent, items, o) {
  o = o || {};
  const dir = o.direction || "VERTICAL";
  const gap = o.gap === undefined ? 0 : o.gap;
  const pl = o.padLeft || 0, pr = o.padRight || 0, pt = o.padTop || 0, pb = o.padBottom || 0;

  const sized = items.map((it) => {
    const n = it.node || it;
    // A plain object here means the caller double-wrapped a {node,w,h} item. It
    // used to append a bare object and yield a NaN height that reached the .fig and
    // then broke PNG export document-wide, with no error at any step.
    if (!n || typeof n.appendChild !== "function") {
      throw new Error(
        "flow(): item is not a node — did you wrap a {node,w,h} item in another " +
        "{node: ...}? got " + JSON.stringify(it),
      );
    }
    parent.appendChild(n);
    return {
      node: n,
      w: it.w !== undefined ? it.w : n.width,
      h: it.h !== undefined ? it.h : n.height,
    };
  });

  // Extent along the flow axis and across it. For HORIZONTAL, "along" is the sum
  // of widths; for VERTICAL it is the sum of heights. Mapping these onto
  // contentW/contentH by direction matters: getting it backwards sized a strip of
  // six 20pt badges to 682pt tall, because it used the sum of their WIDTHS as the
  // height. Caught by measuring the saved nodes, not by reading the code.
  let along = 0, across = 0;
  for (const s of sized) {
    if (dir === "HORIZONTAL") { along += s.w; across = Math.max(across, s.h); }
    else { along += s.h; across = Math.max(across, s.w); }
  }
  along += gap * Math.max(0, sized.length - 1);

  const contentW = (dir === "HORIZONTAL" ? along : across) + pl + pr;
  const contentH = (dir === "HORIZONTAL" ? across : along) + pt + pb;
  // Hug each axis independently. Gating the height resize on hugW meant a VERTICAL
  // container given hugW:false kept its initial height and clipsContent cut off
  // every row after the first.
  const w = o.fixedW !== undefined ? o.fixedW : (o.hugW === false ? parent.width : contentW);
  const h = o.fixedH !== undefined ? o.fixedH : (o.hugH === false ? parent.height : contentH);
  parent.resize(Math.max(1, w), Math.max(1, h));

  // Sizing modes must be derived from the direction, because the primary axis is
  // horizontal for HORIZONTAL and vertical for VERTICAL. They were previously never
  // passed at all, so every container was AUTO/AUTO and a "fixed height" region
  // quietly became a hug.
  const mainFixed = dir === "HORIZONTAL" ? o.fixedW !== undefined : o.fixedH !== undefined;
  const crossFixed = dir === "HORIZONTAL" ? o.fixedH !== undefined : o.fixedW !== undefined;
  auto(parent, dir, {
    spacing: gap, padLeft: pl, padRight: pr, padTop: pt, padBottom: pb,
    align: o.align, mainAlign: o.mainAlign,
    hugMain: !mainFixed, fixedCross: crossFixed,
  });

  // Main-axis placement. Centering must be relative to the CONTAINER's inner
  // length, not the content extent: a 150pt button holding an 88pt label has 62pt
  // of slack in the button, which is the slack that has to be distributed. Using
  // the content extent gave x=0, and using `across` (a height) for a horizontal
  // axis was simply the wrong quantity. SPACE_BETWEEN distributes the slack too.
  const innerMain = (dir === "HORIZONTAL" ? parent.width - pl - pr : parent.height - pt - pb);
  const slack = Math.max(0, innerMain - along);
  let mainStart, extraGap = 0;
  if (o.mainAlign === "CENTER") {
    mainStart = (dir === "HORIZONTAL" ? pl : pt) + slack / 2;
  } else if (o.mainAlign === "MAX") {
    mainStart = (dir === "HORIZONTAL" ? pl : pt) + slack;
  } else if (o.mainAlign === "SPACE_BETWEEN" && sized.length > 1) {
    mainStart = dir === "HORIZONTAL" ? pl : pt;
    extraGap = slack / (sized.length - 1);
  } else {
    mainStart = dir === "HORIZONTAL" ? pl : pt;
  }

  let cursor = 0;
  for (const s of sized) {
    if (dir === "HORIZONTAL") {
      s.node.x = mainStart + cursor;
      s.node.y = o.align === "CENTER" ? pt + (across - s.h) / 2 : pt + (o.align === "MAX" ? across - s.h : 0);
      cursor += s.w + gap + extraGap;
    } else {
      s.node.x = o.align === "CENTER" ? pl + (across - s.w) / 2 : pl + (o.align === "MAX" ? across - s.w : 0);
      s.node.y = mainStart + cursor;
      cursor += s.h + gap + extraGap;
    }
  }
  return parent;
}

// WCAG 2.1 relative luminance and contrast ratio, so pages can carry their own
// accessibility evidence instead of asserting compliance.
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

// Worst (lowest) ratio for a token across every surface it can sit on, plus the
// surface that produced it. TEXT_TOKENS and SURFACES are injected by build.js, so
// the table drawn on the Foundations page is driven by the same declaration the
// build gate enumerates. The gate deliberately does NOT use this summary: it walks
// every pair so it can report each failure, and the shared invariant is the list.
function worstContrast(token, scheme) {
  let worst = Infinity, on = null;
  for (const surface of SURFACES) {
    const r = contrast(TOKENS.color[token][scheme], TOKENS.color[surface][scheme]);
    if (r < worst) { worst = r; on = surface; }
  }
  return { ratio: worst, surface: on, pass: worst >= 4.5 };
}
