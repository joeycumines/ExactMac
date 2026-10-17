# Design

<!-- impeccable:design-schema 1 -->

This document is the written design authority for the ExactMac consent console. `docs/design.fig`
is the drawn contract (3,054 nodes across four pages, verified by `openpencil info`); this file states
the world it implements and how tokens, components, screens, and operational sequences map to behavior.
Where they disagree, fix whichever is wrong and update both — never let a code change land that neither
authorizes (AGENTS.md invariant 16).

## Platform

macos. The console is a menu-bar accessory (LSUIElement, no Dock icon). SwiftUI on macOS 15.
Light and dark are both first-class and follow system appearance; every color token carries both
values under one name.

## Mode

Operate. The approval prompt is a high-stakes single-decision surface; Grants, Activity, and
Settings are management surfaces. Nothing here is marketing. The design's job is disclosure and
control: the operator reads a request well enough to decide it, and every setting directly changes
runtime enforcement.

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
- Plain-English invariant (Standing Invariant 17): no operator-facing string exposes an internal
  capability identifier (`clipboard.read`, `script.execute`, `observation.ax`, `input.synthesize`),
  an enum `rawValue`, or an RPC name. Every surface names the human-verifiable consequence and reach.

## Permission Model and Behavioral Mapping

Rather than an opaque global posture mode (`Ask every time / Balanced / Locked down`) or read-only
"Enforced" rows, Settings organizes enforcement around what local agents are allowed to do by
default, when Touch ID is required, how unattended prompts behave, and how to reset state:

1. **Default Access (4 capability groups + Allow all + Reset defaults)**
   - Summary bar (`AccessSummaryBar/default` and `AccessSummaryBar/allowing-all`): states whether
     ExactMac is asking before new capabilities or allowing all local requests, with one-click
     **Allow all** (flips all 4 groups to `Allow`; Touch ID confirms when broad-approval Touch ID
     is enabled) and **Reset defaults** (restores all 4 groups to `Ask`).
   - Every gRPC RPC in `RPCAuthorizationMap` maps to one of four operator-facing capability groups,
     each controlled by an `Ask | Allow` segmented control (`CapabilityAccessRow`):
     - **Inspect windows and screen** — `observation.window` (`windowObserve`), `observation.ax`
       (`accessibilityTraverse`), `observation.screen` (`screenObserve`), `observation.stream`
       (`observationStream`) (read-only discovery and capture; `local.echo` and `display.read`
       remain non-consent capabilities and never prompt).
     - **Read and write clipboard** — `clipboard.read` (`clipboardRead`), `clipboard.write`
       (`clipboardWrite`).
     - **Control apps and input** — `input.synthesize` (`inputSynthesize`), `window.manage`
       (`windowManage`), `application.control` (`applicationControl`), `file.automate`
       (`fileDialogAutomate`), `macro.execute` (`macroExecute`), `transaction.manage`
       (`transactionManage`), `session.manage` (`sessionManage`), `operations.manage`
       (`operationsManage`), `authorization.manage` (`authorizationManage`).
     - **Run scripts and shell commands** — `script.execute` (`scriptExecute`).
   - When a group is set to `Ask` (the default), any request without a matching code-identity grant
     or active pre-authorization envelope opens the approval prompt. When set to `Allow`, local
     Unix-socket requests in that group execute without prompting and are still recorded in the
     hash-chained decision audit log (`audit.log`).

2. **Touch ID Rules (4 operable toggles)**
   - Every Touch ID row is a live toggle (`SettingRow/toggle-on`, `SettingRow/toggle-off`) that the
     operator can turn on or off; turning any Touch ID rule off requires one final Touch ID
     confirmation so a same-UID process cannot silently disarm biometric checks:
     - **Run scripts or shell commands** (default On): require Touch ID before running shell,
       AppleScript, or JavaScript commands.
     - **All-application and multi-hour approvals** (default On): require Touch ID for grants
       across all apps, pre-authorized sessions, and Allow all.
     - **Unsigned or unverified callers** (default On): require Touch ID when the calling binary
       has no valid code signature.
     - **Open Grants and Activity** (default On): require Touch ID to inspect active grants or the
       decision log.

3. **Unattended & System**
   - **Unanswered prompts** (`TimeoutSettingRow/90s`, `60s | 90s | 3m`, default `90s`): when a
     prompt goes unanswered or the screen locks, the server denies the pending request when the
     timer expires while active grants and pre-authorized sessions continue uninterrupted.
   - **Start ExactMac at login** (`SettingRow/login`, default On): launches the menu-bar console and
     local Unix socket when the operator signs in. Turning the service off in the menu-bar popover
     stops the listener immediately without revoking existing grants.

4. **Reset**
   - **Reset to defaults** (`SettingRow/destructive`, `Reset ExactMac`): revokes all active grants
     and restores default access (`Ask`) and Touch ID rules (all On), while preserving `audit.log`.

## Palette and Design Token Variables

`Console/Sources/ExactMacConsole/Resources/tokens.json` and `docs/design.fig` carry the same 26
design tokens across 3 variable collections (`color` with `light` and `dark` modes, `Space`, and
`Radius`, verified by `openpencil variables docs/design.fig`):

| Token | Light | Dark | Job |
|---|---|---|---|
| surface | #FFFFFF | #1C1C1E | card, rows, fields at rest |
| surface-raised | #F5F5F7 | #2C2C2E | chips, summary bar, selected rows, default option |
| surface-sunken | #EBEBF0 | #141416 | payload blocks, segmented tracks, scroll regions, strips |
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

One face: Inter, weights Regular (400) and Semi Bold (600) only. The declared scale is title 22,
heading 15, body 13, caption 11, mono 12 — plus 17/600 (section headings), 14/600, 12/600, 10/600
(security captions and section labels), and 9/400 (clipboard fine print). In OpenPencil (`render`
and `set_font`), weight spelling is `"Semi Bold"` (with a space).

The production app maps Inter → SF Pro for prose and Menlo for machine text (payloads, pids,
identifiers). The .fig substitutes Menlo to Inter, so in the design the code/prose distinction is
carried by fill, rule, and caption in addition to layout. The app renders both signals.

## Space and radius

Declared grid is 4pt (`space-1`=4, `space-2`=8, `space-3`=12, `space-4`=16, `space-5`=20,
`space-6`=24, `space-8`=32, `space-10`=40); component padding uses 10–14pt, intra-row gap 6–8pt,
section gap 12–16pt, and window padding 16pt. Radii (`Radius` collection): `radius-sm`=4 (fields,
strips, settings rows), `radius-md`=6 (buttons, inner segments), `radius-lg`=10 (window and popover
shells), `radius-pill`=999 (dots-in-capsule chrome and toggle tracks).

## Layout

- Approval prompt: 420pt wide, three regions — hugging header (system-derived facts only),
  fixed 348pt scrolling disclosure (with a visible 4pt scroll rail), hugging footer (the decision).
  Measured 755pt in its tallest state against a 1008pt window ceiling.
- Popover: 360pt, content-hugging, flat (1pt hairline border).
- Window surfaces (Grants, Activity, Settings): 720pt wide, 688pt content column (`SettingsWindow`
  is 720×866pt in both schemes).
- The agent's reason is capped at 96pt of growth and scrolls inside its own box; nothing is
  ever truncated or elided.

## Components

From the Components page (`0:4`, 552 `COMPONENT` nodes across the document): `SignatureBadge` (6
states, dot-plus-word, no chrome), `IdentityRow`, `ProcessTree` (`deep`, `direct`, `deep-seven`),
`UntrustedField`/`SystemField` pair, `RiskChip`, `Button` (`primary`, `secondary`, `caution`,
`deny`, `quiet`), `OptionRow` (six grant kinds, destructive marked by red title ink only),
`NoteField`, `BiometricState`, `PayloadBlock`, `MenuBarItem`, `StatusPill`/`StatusDot`,
`ServiceToggle`, `FailClosedBand` (two fail-closed presentations), `PendingNotice`, menu rows,
`CountdownChip`, `GrantRow`, `ActivityRow`, `IntegrityBadge`, `AccessSummaryBar` (`default` and
`allowing-all`), `CapabilityAccessRow` (`ask` and `allow` with `SegmentedAccess`), `SettingRow`
(`toggle-on`, `toggle-off`, `destructive`), `TimeoutSettingRow` (`90s` with `SegmentedTimeout`),
`EmptyState`, `ErrorState`, `LoadingSkeleton`, `ScrollRail`.

## Screens and Flows

From the Screens page (`0:5`), each in light and dark where drawn: the approval prompt pair
(`scr/pair`), the expanded prompt (`scr/expanded`), the settled states (`scr/states`: denied,
expired, unreachable), the no-reason variant (`scr/noreason`), the menu-bar item (`scr/menubar`)
and popover (`scr/popover`), both fail-closed presentations (`scr/failclosed`,
`scr/failclosed-dark`), Grants (`scr/grants-pair`, empty, loading, error), Activity
(`scr/activity-pair`, chain-broken, empty, loading, error), Settings pair (`scr/settings-pair`,
`SettingsWindow/normal` and `SettingsWindow/dark`), the pre-authorization envelope pair
(`scr/envelope-pair`), the trust-ordered non-scrolling header study (`scr/trust`), and the queue
review surface (`scr/queue-review`, `QueueReview/default` and `QueueReview/dark`, plus
`QueueIndicator` in both schemes).

The Flows page (`0:6`, frame `flows`) draws five operational sequences:
1. A single request prompts once (capability group default `Ask`/`Allow` and code-identity grants).
2. A pre-authorized envelope, and the silence inside it (bounded capability set and duration).
3. Revocation is immediate and total (service toggle vs grant revocation).
4. Concurrent agents and sandboxed helper ancestry (per-peer Unix socket credentials, parent-chain
   walk, FIFO consent queue with caller attribution and starvation-free timer reset).
5. Unanswered prompts, locked screen, and remote TCP callers (timeout auto-deny, screen-lock
   fail-closed for interactive prompts while active grants continue, and TCP consent denial).

## Known gaps (design must grow before code)

1. Queue affordance — RESOLVED (drawn on the Screens page as `scr/queue-review` with per-agent
   caller attribution on each queued row, `Approve all as default`, and `Deny all`).
2. Notification: the app has no notification center integration. The drawn attention mechanism
   is the window surfacing plus the menu-bar state change; the design does not yet specify what
   happens when the operator is full-screen elsewhere.
3. Grant countdown live-tick: CountdownChip states are drawn but nothing specifies the ticking
   behavior on Grants rows or the prompt clock.

## Deviations

- Inter-only in the .fig, SF Pro + Menlo in production: recorded, deliberate, both signals
  (typeface in the app, fill/rule/caption in the .fig) carry the same distinction.
- Off-grid spacing: the de-facto values above are the design's real rhythm; the 4pt grid is the
  declared base, not a lint rule.
- PRODUCT.md `## Platform` says `macos`, which the impeccable schema does not recognize; the
  real platform is recorded here and in PRODUCT.md rather than the nearest wrong enum value.
