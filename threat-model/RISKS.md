# Risk register

The machine-readable models are `exactmac-server.threat-model.json` and `exactmac-console-ui.threat-model.json`. This document is the join between them and the implementation: for every risk, which control addresses it, which task builds that control, and how the control is proved. It exists because a threat model that is not traceable to code and tests is documentation, and because a mitigation with no named owner does not get built.

The table is generated from the two models, and `validate.py` enforces that every risk in either model appears here exactly once, so this file cannot silently fall behind the JSON.

## Scoring

Score is likelihood x impact on the OWASP five-point scales, and level is derived from the score. Both are enforced mechanically in `threat-model/validate.py`, because the schema constrains the two enums and the 0-25 range independently and states no formula — which means a model can claim a severe impact while reporting a comfortable score. One risk in the first draft of the server model did exactly that, and the check exists because of it.

Level bands: 0-4 very_low, 5-9 low, 10-14 medium, 15-19 high, 20-24 very_high, 25 critical.

## Server model

| Risk | L | I | Score | Level | Controls | Built by | Verification |
|---|---|---|---|---|---|---|---|
| `risk-unauthenticated-code-execution`<br/>Unauthenticated arbitrary code execution as the user | certain | severe | 25 | critical | `authorization-interceptor-enforcement`, `fail-closed-consent`, `launchd-socket-mode`, `public-request-wire-validation`, `tcp-reduced-posture` | C1, C2, C4 | scheduled |
| `risk-silent-content-exfiltration`<br/>Silent exfiltration of screen, accessibility, and clipboard content | certain | severe | 25 | critical | `authorization-interceptor-enforcement`, `tcc-accessibility-authority` | C1, C2, C4 | scheduled |
| `risk-unconsented-irreversible-action`<br/>Irreversible user actions taken without informed consent | likely | severe | 20 | very_high | `authorization-interceptor-enforcement`, `biometric-gate-for-high-blast-radius`, `capability-implication-closure`, `graded-caller-identity-evidence`, `operator-defined-consequence-targets`, `tcc-accessibility-authority` | C2, C4, C9 | scheduled |
| `risk-operator-consent-fatigue`<br/>A control the operator habitually ignores | likely | major | 16 | high | `biometric-gate-for-high-blast-radius`, `blast-radius-scaled-friction`, `capability-implication-closure`, `code-identity-grant-binding`, `graded-caller-identity-evidence`, `hash-chained-decision-audit`, `operator-defined-consequence-targets`, `pre-authorization-envelope-bounding` | C1, C6, C9 | scheduled |
| `risk-grant-broadening`<br/>Narrow approval becomes standing broad permission | likely | major | 16 | high | `blast-radius-scaled-friction`, `capability-implication-closure`, `code-identity-grant-binding`, `graded-caller-identity-evidence`, `hash-chained-decision-audit`, `pre-authorization-envelope-bounding` | C1, C5 | scheduled |
| `risk-consent-channel-impersonation`<br/>Consent plane nullified by channel impersonation | possible | severe | 15 | high | `fail-closed-consent`, `mutually-authenticated-consent-channel` | C7 | scheduled |
| `risk-audit-tampering`<br/>No trustworthy record of what was permitted | possible | major | 12 | medium | `hash-chained-decision-audit`, `owner-private-persistence` | C8 | scheduled |
| `risk-exposed-tcp-listener`<br/>Network-reachable code execution by misconfiguration | unlikely | severe | 10 | medium | `launchd-socket-mode`, `tcp-reduced-posture` | C4 | scheduled |
| `risk-prompt-injection-abuse`<br/>Legitimate agent weaponised by hostile content | likely | major | 16 | high | `graded-caller-identity-evidence` | C3, C4, C9 | scheduled |
| `risk-clipboard-content-injection`<br/>Clipboard used to attack the operator's own next action | possible | moderate | 9 | low | `authorization-interceptor-enforcement` | C2, C4 | scheduled |
| `risk-macro-persistence`<br/>Stored macros used as a persistence mechanism | possible | major | 12 | medium | `authorization-interceptor-enforcement`, `owner-private-persistence` | C2, C4 | scheduled |
| `risk-same-uid-malware-residual`<br/>Same-uid malware retains access within granted bounds | possible | major | 12 | medium | `authorization-interceptor-enforcement`, `blast-radius-scaled-friction`, `fail-closed-consent`, `pre-authorization-envelope-bounding`, `public-request-wire-validation` | C3, C5, C8 | accepted residual |
| `risk-shared-token-residual`<br/>Consent channel secret readable by same-uid malware | unlikely | severe | 10 | medium | `fail-closed-consent`, `mutually-authenticated-consent-channel` | C7 | accepted residual |

## Console UI model

| Risk | L | I | Score | Level | Controls | Built by | Verification |
|---|---|---|---|---|---|---|---|
| `risk-operator-approves-the-wrong-dialog`<br/>The operator answers an impersonated dialog | possible | severe | 15 | high | `mutually-authenticated-channel`, `signature-state-prominence` | B3, B6, C6, C9 | scheduled |
| `risk-misleading-but-genuine-prompt`<br/>A genuine prompt misleads through caller-chosen or clipped text | likely | major | 16 | high | `implication-and-blast-radius-disclosure`, `no-truncation-payload-disclosure`, `server-side-capability-derivation`, `signature-state-prominence`, `untrusted-field-marking-control` | B3, B6, C9 | scheduled |
| `risk-approval-applied-to-wrong-request`<br/>An approval authorizes a different request | unlikely | severe | 10 | medium | `no-persisted-decisions`, `server-side-capability-derivation`, `single-use-request-binding` | C7 | scheduled |
| `risk-consent-fatigue-by-flooding`<br/>Prompt flooding reduces the operator to reflexive approval | likely | major | 16 | high | `blast-radius-scaled-presentation`, `failing-closed-is-presented-as-protective`, `operator-defined-consequence-targets`, `prompt-flood-coalescing`, `safe-decision-affordance-ordering` | C1, C9 | scheduled |
| `risk-approval-content-exposed-to-session`<br/>Command text and argument values leak to co-resident processes | likely | moderate | 12 | medium | `content-free-notifications`, `copy-to-pasteboard-warning`, `screen-capture-reaction` | B5, C6, C9 | scheduled |
| `risk-biometric-gate-degraded-or-coerced`<br/>The biometric commitment is degraded, spoofed, or coerced | unlikely | major | 8 | low | `biometric-never-downgrades`, `biometric-nonce-binding`, `screen-lock-and-away-awareness` | C6 | scheduled |
| `risk-invisible-standing-permission`<br/>Standing permission exceeds the operator's understanding | possible | major | 12 | medium | `activity-log-integrity-display`, `blast-radius-scaled-presentation`, `grants-manager-enumeration`, `implication-and-blast-radius-disclosure`, `no-persisted-decisions`, `operator-defined-consequence-targets`, `safe-decision-affordance-ordering` | C5, C9 | scheduled |
| `risk-misleading-forensic-view`<br/>The operator investigates using a falsified activity log | possible | major | 12 | medium | `activity-log-integrity-display`, `no-persisted-decisions` | C8, C9 | scheduled |
| `risk-absence-treated-as-consent`<br/>An unanswered request is treated as consent | unlikely | severe | 10 | medium | `biometric-never-downgrades`, `failing-closed-is-presented-as-protective`, `mutually-authenticated-channel`, `safe-decision-affordance-ordering`, `screen-lock-and-away-awareness` | C4, C9 | scheduled |
| `risk-degraded-evidence-read-as-clean`<br/>Unresolved caller evidence displayed as though it were resolved | possible | major | 12 | medium | `signature-state-prominence`, `untrusted-field-marking-control` | C3, C9 | scheduled |

Two of the server model's risks are **accepted residual**, recorded as risks rather than controls because no control in this design eliminates them and a document that implied otherwise would be lying. `risk-same-uid-malware-residual` is the price of the architecture: the agent and the operator share a uid, so malware running as the user sits inside the authentication boundary and can exercise any grant the operator has issued. Code-identity binding limits which grants transfer and the audit chain makes use detectable afterwards, but neither prevents it. `risk-shared-token-residual` follows from that: the consent channel secret lives in an owner-private file, which stops a process that merely located the channel but not malware already running as the user. Removing it would require an out-of-band channel the operator has to carry, which is a worse trade than the residual.


## Invariants

These are the properties that must hold for this system to be considered sound. Each is a single falsifiable
sentence, and each has at least one test that would fail if it were violated. They are the source text for the
matching section of `AGENTS.md`, and they apply beyond any single change: a future change that breaks one has
broken the system, not just the feature.

1. No RPC reaches a handler without a decision recorded in the decision audit log.
2. Every consent failure mode denies: an unreachable console, a timeout, a cancelled, failed, or locked-out
   biometric, a corrupt or unreadable grant store, an unauthenticated channel peer, and an absent or locked
   operator. There is no path on which any of these produces allow.
3. A biometric success authorizes exactly one decision, is bound to a per-decision nonce, and never downgrades
   silently to a weaker check.
4. Capability and scope are re-derived by the server from the request bytes at enforcement time. The console's
   classification is for display only and is never an authorization input.
5. A pre-authorization envelope can never confer a global-persistent grant, and expires as a unit on a
   monotonic clock.
6. A grant binds to a caller's code identity — executable path, bundle identifier, and signing designated
   requirement — and never to a pid.
7. App and process verification exists only in the Unix-socket variant, and is graded evidence surfaced to the
   operator, never an authentication gate. An unsigned caller is escalated, not silently rejected.
8. A TCP-configured server never enters the consent or verification path. It denies every consent-requiring
   capability and reports that posture through the health service.
9. The decision audit log is hash-chained, and the console verifies the chain before displaying it rather than
   presenting unverified bytes as authoritative.
10. The console persists no decision state, so there is nothing on disk for a same-uid process to forge.
11. A prompt never truncates a command, script, path, or argument. It wraps and scrolls.
12. Text the caller supplied is visually distinguished in the prompt from text the system derived.
13. Payloads, command text, and target paths never appear in a notification.
14. No UI change lands before the corresponding design exists in `docs/design.fig`.

## How to add a risk

Add the threat to the appropriate model, add the control that addresses it with a real `status` and `priority`,
add the risk with a likelihood, impact, impact description, and a score that satisfies the enforced matrix, then
regenerate this file so the register and the models agree. `python3 threat-model/validate.py` will fail if a
risk is missing from this register, if a score is inconsistent with its likelihood and impact, or if a level
band disagrees with its score.
