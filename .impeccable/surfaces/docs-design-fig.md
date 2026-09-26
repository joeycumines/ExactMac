---
version: 1
slug: "docs-design-fig"
primary_target: "docs/design.fig"
related_targets: []
---

# Surface brief — ExactMac consent console

Scope: the macOS menu-bar consent console, designed in `docs/design.fig` and implemented as
`Console/Package.swift`. Mode: **Operate**, with the approval prompt treated as a
high-stakes single-decision surface.

Audience and job: the developer-operator, at their desk, mid-task, deciding whether an AI
agent may act on their machine. They are the only decision-maker and the only person the
system protects.

Task: read a request well enough to decide it, then choose a breadth and a duration, or
deny, optionally leaving a note the agent will read.

Constraints carried from PRODUCT.md and the threat models: fail closed everywhere; process
verification is graded evidence, never an authentication gate; grants bind to code identity;
a prompt never truncates a command, script, path, or argument; a request with no stated
reason is one the operator should decline.

Memorable moment: the signature badge and the untrusted-field marker working together — the
operator can see at a glance that the process asking is ad-hoc signed, and that the window
title it printed is caller-supplied rather than a fact the system derived.

Unresolved: whether the operator's high-consequence target list lives in settings or in
configuration the agent host manages; whether the copy affordance writes to the pasteboard
plainly or requires a confirm.

## Direction contract

THESIS: The category default for a permission prompt is a small modal with an icon, one
sentence, and two buttons. This surface refuses that arrangement. The thesis is that the
operator's decision is worth more information than a button pair, and that the information
is the product: the entire call chain, the complete text that will run, and breadth and
duration as explicit separate choices rather than one "allow". The refusal is specifically of
the truncated summary, because truncation is exactly where an operator stops reading.

OWN-WORLD: The world is the macOS system's own consent and instrumentation grammar. Semantic
system surfaces that can vibrancy, separators at system opacity, SF Pro for prose and SF Mono
for anything the machine will execute or the machine reported, which is code and data rather
than costume. Controls are the system's own: a stepped list of grant options each stating its
own consequence, scope, and expiry; a signature state as a small capsule; a process tree as an
indented list whose depth is the trust distance. No illustration, no icon tiles, no card grid,
no eyebrow above any heading. Both light and dark are first-class and follow the system
appearance, because the operator works at this machine across a full day and an approval can
arrive at any hour.

STORY: The operator understands which process is asking, how it is signed, what it wants, what
it wants it against, the complete text that will run, and exactly how broad and how long the
resulting permission will be. They believe they saw all of it and that a narrower option
existed. They act: choose a breadth and a duration, or deny, and may say why in a note the
agent reads.

FIRST VIEWPORT: A popup panel 420 points wide. One scrolling disclosure column above a fixed
decision footer, so the decision controls never move as content length changes. At the top, the
capability as a single sentence at 15pt semibold with no label above it. Beneath it, the
agent's stated reason as an attributed quote, because an unexplained request is one to
decline. Then a disclosure table of label and monospaced value pairs: call chain, signature
state, resolved target, RPC and capability. Then the payload in a sunken monospaced block that
wraps and never clips, with a copy affordance that warns the value lands on the shared
pasteboard. The footer holds a vertical stepped list of grant options — deny, allow once, allow
for this session, allow scoped to this target, allow globally, pre-authorize an envelope — each
carrying one line of consequence and one line of scope and expiry, narrowest first, none
focused by default, the irreversible ones never adjacent to the primary action. Below the
list, a note field. Deny and the chosen grant at opposite ends of the footer.

FORM: The platform's own consent-and-instrumentation grammar, reached through a popup panel.
Seven directions were derived from the world this audience reads daily — System Settings, TCC
consent sheets, Xcode and Instruments, Security.app's access-control sheet, Activity Monitor,
man pages, and gatekeeper output. The roll assigned index 4, the developer inspector. Hana
pinned the topology to a popup after the roll, and a brief-pinned direction beats the roll, so
the inspector's two-pane window is refused. Named translation: the inspector's completeness,
its monospaced disclosure, and its refusal to hide anything behind a disclosure triangle are
kept; its window topology is not, because an approval must be one focused surface rather than
two panes the eye has to reconcile. Seed key `83d7962a`, scope direction, mode operate.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
