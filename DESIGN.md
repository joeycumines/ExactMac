# Design

<!-- impeccable:design-schema 1 -->

This document is the written design authority for the ExactMac consent console. `docs/design.fig`
is the drawn contract (2,869 nodes across four pages, verified by `openpencil`); this file states
the world it implements and where the artifact deviates from the declared tokens. Where they
disagree, fix whichever is wrong and update both — never let a code change land that neither
authorizes (AGENTS.md invariant 16).

## Platform

macos. The console is a menu-bar accessory (LSUIElement, no Dock icon). SwiftUI on macOS 15.
Light and dark are both first-class and follow system appearance; every color token carries both
values under one name.

## Mode

Operate. The approval prompt is a high-stakes single-decision surface; Grants, Activity, and
Settings are management surfaces. Nothing here is marketing. The design's job is disclosure:
the operator reads a request well enough to decide it.

## World

The macOS system's own consent and instrumentation grammar. The direction contract is pinned in
`.impeccable/surfaces/docs-design-fig.md` and is retained here in distilled form:

- Thesis: the operator's decision is worth more information than a button pair. The information
  is the product: the whole call chain, the complete text that will run, and breadth and duration
  as explicit separate choices rather than one "allow". Truncation is refused everywhere.
- Surfaces: semantic system surfaces, separators at system opacity, no illustration, no icon
  tiles, no card grids, no eyebrows above headings. Controls are the system's own grammar:
  stepped grant options each stating consequence, scope, and expiry; signature states as
  dot-plus-word annotations; the process tree as an indented list whose depth is trust distance.
- Color discipline: chrome never takes semantic color. Status is a 5–8pt dot plus a word; the
  label is ink-colored except the two verdicts an operator must not skim past (Allowed/Denied in
  Activity, and a broken hash chain). Red ink marks destructive options by title, never by a
  filled red button.
- Provenance rules carry security meaning and are expressed as three independent differences,
  never one: caller-supplied text gets a sunken fill, an amber 3pt rule, and a NOT VERIFIED
  caption; system-derived text gets none of the three; unknown facts (errors, fail-closed bands)
  get a grey rule. Amber means "someone else wrote this"; grey means "we cannot tell you this".
  Color is never the only carrier of any of these meanings.

## Palette

25 hardcoded literals in the .fig, and they are the tokens: `Console/Sources/ExactMacConsole/Resources/tokens.json`
is the single source of truth and the .fig's literals match it one-for-one (verified by
`openpencil analyze colors` on 2026-10-09). The .fig holds zero variables — a known toolchain
limit, recorded in tokens.json — so the JSON is authoritative and the .fig is the rendered proof.

Roles, light/dark:

| Token | Light | Dark | Job |
|---|---|---|---|
| surface | #FFFFFF | #1C1C1E | card, rows, fields at rest |
| surface-raised | #F5F5F7 | #2C2C2E | chips, selected rows, default option |
| surface-sunken | #EBEBF0 | #141416 | payload blocks, scroll regions, strips |
| separator | #D2D2D7 | #3A3A3C | hairlines (decorative; deliberately under 3:1) |
| control-border | #8A8A8F | #5C5C61 | interactive edges; must be perceivable |
| text-primary | #1D1D1F | #F5F5F7 | prose and load-bearing lines |
| text-secondary | #5E5E63 | #A8A8AD | supporting lines, scroll rail |
| text-tertiary | #68686D | #949499 | quietest text, timestamps |
| accent | #0A6CFF | #3D8BFF | FILL ONLY (buttons, toggles, rules) |
| accent-text | #0A5CD5 | #66A8FF | ink form of accent for text |
| on-accent | #FFFFFF | #1C1C1E | label on an accent fill — DARK in dark mode |
| danger | #D70015 | #FF5E52 | deny ink, verdicts, broken chain |
| caution | #A04A00 | #FF9F0A | untrusted rule, expiry dots, menu-bar badge |
| success | #1A753F | #30C46C | signed dots, active grants, running state |

Every text token clears WCAG AA (4.5:1) on surface, surface-raised, and surface-sunken in both
schemes; on-accent clears 4.5:1 on accent. This is mechanically enforced by automated tests
against tokens.json — do not retune values without re-running them.

## Type

One face: Inter, weights Regular and SemiBold only. The declared scale is title 22, heading 15,
body 13, caption 11, mono 12 — and the artifact uses four more roles than it declares:
10/600 (the eyebrow carrying every security caption, 123 nodes), 12/600, 14/600, and 9/400
(the clipboard fine print). Weight spelling is load-bearing: only "SemiBold" renders; any other
spelling silently downgrades to Regular (verified by `openpencil fonts`).

The production app maps Inter → SF Pro for prose and Menlo for machine text (payloads, pids,
identifiers). The .fig cannot render Menlo and substitutes everything to Inter, so in the design
the code/prose distinction is carried by fill, rule, and caption instead of typeface. The app
renders both signals.

## Space and radius

Declared grid is 4pt; the artifact's de-facto rhythm is 2, 3, 5, 6, 9, 10, 13, 14 — 10pt is the
component padding throughout, 6pt the intra-row gap, 12pt the section gap, 16pt the card
padding. Off-grid flags from `openpencil analyze spacing` are the design's real values, not
violations to fix. Radii: 4 small (fields, strips), 6 medium (rows, buttons), 10 large (window
and popover shells only), pill for dots-in-capsule chrome.

## Layout

- Approval prompt: 420pt wide, three regions — hugging header (system-derived facts only),
  fixed 348pt scrolling disclosure (cut on purpose, with a visible 4pt scroll rail), hugging
  footer (the decision). Measured 755pt in its tallest state against a 1008pt window ceiling.
- Popover: 360pt, content-hugging, flat (no shadow; a 1pt hairline does the separation).
- Window surfaces (Grants, Activity, Settings): 720pt wide, 688pt content column that never
  varies; a row's internal split is the only columnar structure.
- The agent's reason is capped at 96pt of growth and scrolls inside its own box; nothing is
  ever truncated or elided.

## Components

From the Components page (509 COMPONENT nodes): SignatureBadge (6 states, dot-plus-word, no
chrome), IdentityRow, CallerTree, UntrustedField/SystemField pair, RiskChip, ConsoleButton
(primary/secondary/caution/deny/quiet), OptionRow (six grant kinds, destructive marked by red
title ink only), NoteField, biometric strip, PayloadBlock, MenuBarItem, StatusPill/StatusDot,
ServiceToggle, FailClosedBand (two fail-closed presentations), PendingNotice, menu rows,
CountdownChip, GrantRow, ActivityRow, IntegrityBadge, PostureControl, SettingRow, TargetChip,
EmptyState, ErrorState, LoadingSkeleton, ScrollRail.

## Screens

From the Screens page, each in light and dark where drawn: the approval prompt pair, the
expanded prompt, the settled states (denied/expired/unreachable), the no-reason variant, the
menu-bar item and popover, both fail-closed presentations, Grants (populated, empty, loading,
error), Activity (populated, chain-broken, empty, loading, error), Settings pair, the
pre-authorization envelope pair, and the trust escalation screen. The Flows page draws the
three consent sequences and the lane rules.

## Known gaps (design must grow before code)

Recorded 2026-10-09 during the UI-redesign replan. These are real operator needs with no drawn
surface yet; each gets a design first, then code (invariant 16):

1. Queue affordance — RESOLVED 2026-10-09 (drawn on the Screens page as `scr/queue-review`).
   The design now draws both halves: a queue-indicator band at the top of the active prompt's
   footer whenever requests wait behind it (hidden once the options expand or the prompt
   settles), and the QueueReview sheet — full-bleed band with a Back link, the waiting count,
   one row per queued request carrying its consequence, its server-default scope and a Decide
   link that promotes it to the full prompt, then Approve all as default, the note, Deny all,
   and the invariant line "Each request receives its own decision. No blanket grant is
   created." The code implements exactly this: `QueueReview.swift` and the
   `queuedCount`/`onReviewQueue` affordances on `ApprovalPrompt`.
2. Notification: the app has no notification center integration. The drawn attention mechanism
   is the window surfacing plus the menu-bar state change; the design does not yet specify what
   happens when the operator is full-screen elsewhere.
3. Grant countdown live-tick: CountdownChip states are drawn but nothing specifies the ticking
   behavior on Grants rows or the prompt clock.

## Deviations

- The .fig carries zero variables and hardcoded literals: recorded toolchain limit, JSON is the
  token authority.
- Inter-only in the .fig, SF Pro + Menlo in production: recorded, deliberate, both signals
  (typeface in the app, fill/rule/caption in the .fig) carry the same distinction.
- Off-grid spacing: the de-facto values above are the design's real rhythm; the 4pt grid is the
  declared base, not a lint rule.
- PRODUCT.md `## Platform` says `macos`, which the impeccable schema does not recognize; the
  real platform is recorded here and in PRODUCT.md rather than the nearest wrong enum value.
