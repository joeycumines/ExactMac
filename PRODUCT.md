# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

The schema's bare-value enum covers `web`, `ios`, `android`, and `adaptive`. macOS native is not among them and
none of those four is an honest description of a SwiftUI menu-bar application, so the real platform is recorded
here rather than the nearest wrong value. This is a known deviation from the schema, flagged rather than papered
over. There is a consequence worth stating: `init.md` loads a native platform reference for `ios` and `android`,
and this project gets none, so the macOS-specific guidance in the impeccable references is assumed rather than
supplied.

## Stack

Answered by the existing codebase, not delegated. ExactMac is a Swift package repository with three Swift
packages and a Go module: the root `Package.swift` (the `ExactMac` SDK), `Server/Package.swift` (the gRPC
server), and a `Console/Package.swift` to be added for the consent app. SwiftUI, AppKit, and LocalAuthentication.
Swift 6, macOS 15 deployment target for the server, macOS 12 for the SDK. gRPC over HTTP/2 on a launchd-activated
Unix socket, with a Go MCP proxy in front for agent access.

## Users

One audience, confirmed directly: **the developer-operator**. The person who installed ExactMac, granted its TCC
permissions, and runs agents against their own Mac.

No non-technical end user is a design target. This was asked and answered rather than assumed, and it is
load-bearing: it means the console may disclose densely and technically — process trees, signing designated
requirements, literal command text — because the reader is expected to be able to interpret all of it. A design
that flattens that detail to suit a broader audience would be solving for a user who does not exist here.

Several distinct agents or tools will call ExactMac concurrently — an IDE assistant, a terminal agent, a
scheduled job, a background service. Also confirmed. Consequences: grants bind per code identity rather than
per session, every surface that shows a grant must show its holder, and the consent plane must handle more than
one requester at a time without ever letting a decision land on the wrong one.

## Product Purpose

ExactMac is a macOS automation server. It exposes 68 gRPC methods and, by design, performs work ordinary
applications may not: it executes arbitrary shell, AppleScript, and JavaScript; it reads the accessibility tree
of every running application; it captures the screen; it reads the clipboard and keeps a clipboard history; and
it synthesizes mouse and keyboard input, acting as the user.

This product — the consent console — is what stands between that capability and the operator's machine. The
server has no authentication and no authorization of its own. The Unix socket that reaches it is mode 0600,
which excludes other user accounts and the network but not the operator's own processes, and the intended
consumer is an AI agent running as that same user. So the console cannot isolate the agent from malware. What it
can do is make one person, quickly and with minimal friction, correctly decide what an agent may do.

Success means: the operator approves precisely what they intend to approve, they are never asked twice for
something they have already decided, and every grant they have given is visible and revocable. Not "the system
is secure" — that is not available here — but "the operator was in the loop and the loop meant something."

## Positioning

Neighboring automation and agent tooling has one of two failure modes. It either gives the agent everything and
tells the user nothing, or it interrupts for every single low-stakes read until the user stops reading and
clicks through. The second is worse than the first, because it produces a system that looks protected while
having taught the user that its prompts are noise.

The mechanism here is that **friction is a function of blast radius rather than of capability**. A clipboard
read scoped to a single application costs almost nothing. The same capability across every application,
continuously, for two hours, costs a biometric. That single decision is what makes both minimal friction and
real security possible at once, and it is not something a fixed taxonomy or a per-app toggle list can express.

The second half of the position is honesty about what the mechanism is not. Same-uid malware is not
cryptographically distinguishable from the operator's own agent, and a design that implied otherwise would be
selling a protection it does not provide. So the console's job is to make the operator a well-informed judge,
and to record what it decided. The differentiator is informed consent with full caller disclosure, not
isolation.

## Operating Context

A single macOS login session. The server runs as a launchd-activated daemon holding the user's ambient
authority through two independent TCC grants: Accessibility, for the accessibility tree and input synthesis, and
Screen Recording, for ScreenCaptureKit capture. Losing either degrades the product partially and silently.

Agents run inside other applications — an IDE, a terminal — and inherit those applications' authority. The
operator is typically at the machine, often mid-task, and is the only decision-maker. The console is a
menu-bar presence rather than a window that is summoned, because a request can arrive at any moment and the
operator cannot be required to go looking for it.

The consent plane exists only in the Unix-socket deployment variant. A TCP-configured server is unauthenticated
with no socket access to restrict, so it offers no approvals at all and denies every consent-requiring
capability.

## Capabilities and Constraints

Confirmed and load-bearing:

- **No enrolment, and no agent registry.** Every agent starts with nothing and earns each grant. There is no
  trust-on-first-use, no list of known agents, and no way to mark an application trusted. This removes a whole
  class of confused-deputy risk that an enrolment feature would introduce, and it means a compromised agent host
  inherits nothing.
- **Grants bind to code identity** — executable path, bundle identifier, signing designated requirement — and
  never to a pid, which changes on every run.
- **Capabilities form an implication lattice, not a flat list.** Script execution subsumes screen reading,
  clipboard reading, and input synthesis, because a shell can perform all of them. A prompt states what a grant
  silently includes.
- **Process and app verification is Unix-socket only, and is graded evidence, not an authentication gate.** The
  operator is shown the process tree, the path, the signature state, and the parent chain. An unsigned caller
  is escalated in risk and friction, never silently rejected, because a control that rejected same-uid callers
  would be unusable and false.
- **Fail closed, everywhere.** Unreachable console, timeout, failed or locked-out biometric, corrupt grant
  store, unauthenticated channel peer, absent operator — all deny. There is no path on which any of these
  allows.
- **Biometric approval uses LocalAuthentication**, bound to a per-decision nonce, required by blast radius and
  never silently downgraded to a weaker check.
- **Pre-authorization is required for long agentic sessions.** An agent declares the capabilities, scopes, and
  duration it will need; the operator approves that envelope once. Envelopes are time-bounded, revocable
  immediately, and can never confer a global-persistent grant.
- **Two TCC grants, not one.** Accessibility and Screen Recording are independent and neither substitutes for
  the other. The absence of any `NSScreenCaptureUsageDescription` in the repository is unexplained and may be a
  deployment defect.

Explicitly undecided:

- Whether the risk register's accepted residuals — same-uid malware, and the consent channel token readable by
  same-uid malware — are acceptable to ship, or whether they force a different architecture. Recorded as
  residual rather than mitigated, and not presented as solved.
- Whether the console is the right place to surface the operator's own list of high-consequence target
  applications, or whether that belongs in configuration the agent host manages.

## Evidence on Hand

Real and citable:

- Two OWASP-schema-valid threat models under `threat-model/`, with a risk register tracing every risk to a
  control and a task, and 16 falsifiable invariants.
- The protobuf surface: `proto/exactmac/v1/exact_mac.proto`, 68 methods, which is the actual capability
  inventory.
- The server implementation, which is the authority on what the platform grants and what the transport is.

Absences that future work must not fabricate:

- No users, no testimonials, no customer names, no usage data, no benchmarks, no adoption figures. None of
  these exist and none may be invented.
- No brand assets, no logo, no established visual identity, no naming precedent beyond `ExactMac` itself.
- No competitive analysis. The positioning above is an argument about mechanism, not a claim about what named
  competitors do.
- No prior art threat model for this project was located, which is a statement about what was searched, not a
  claim that none exists.

## Product Principles

1. **Friction tracks blast radius, never capability.** The cost of a decision is a function of what the grant
   actually permits — breadth, duration, target, and caller quality — not of a static label. A uniform prompt
   trains the operator to approve without reading, which is a failed control, not a tolerable annoyance.
2. **Disclosure is the product.** Authorization can be got right by comparison; disclosure cannot. A prompt that
   is correct but unreadable, readable but misleading, or complete but illegible at the size the operator is
   actually looking at produces the same outcome as a wrong prompt. Truncating a command is a security defect.
3. **Fail closed, and make the closed state legible.** Every failure mode denies. The console says so in a
   register that reassures, because an operator who experiences denial as a fault will work around it.
4. **Never claim protection that is not there.** Same-uid is authenticated only as far as the socket. The
   console's job is informed consent and an honest record, and it must not imply isolation it cannot deliver.
5. **Design before code, every time.** No interface lands before it exists in the design document, because the
   disclosure decisions in a consent prompt are design decisions with security consequences.

## Accessibility & Inclusion

Derived from the platform rather than asserted by a stakeholder, and treated as a requirement: the console is
native macOS and therefore expected to be fully operable by keyboard alone and to expose correct accessibility
semantics to VoiceOver. For a security prompt this is not a courtesy. A consent decision that can only be made by
pointer is a decision some operators cannot make, and the blast-radius design depends on operators being able to
compare what they are approving.

Two consequences for the design specifically. Focus order must place the safe answer first and must never
default to an irreversible one, since keyboard operation makes the default focus the decisive one. And no
consequence of a request may be communicated by colour alone, because the signal that distinguishes a signature
state or a risk band has to survive being read aloud.
