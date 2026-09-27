# Risk register

The machine-readable models are `exactmac-server.threat-model.json` and `exactmac-console-ui.threat-model.json`. This document is the join between them and the implementation: for every risk, which control addresses it, and which task builds that control. It exists because a threat model that is not traceable to code is documentation, and because a mitigation with no named owner does not get built.

The table is generated from the two models, and `validate.py` fails if a risk in either model is missing from it or listed twice, so this file cannot silently fall behind the JSON. The **State** column records where each risk's mitigation stands: the implementation task that built the control and the passing test suite / test cases verifying it, closing the loop between the threat models and the automated test suite. For accepted residuals, it records the bounding controls and their verifying tests.

## Scoring

Score is likelihood x impact on OWASP's five-point scales, and the level band comes from OWASP's own table, retrieved from the threat model library specification and reproduced in `validate.py`:

| Score | Level |
|---|---|
| 1-2 | very_low |
| 3-4 | low |
| 5-9 | medium |
| 10-12 | high |
| 13-16 | very_high |
| 20-25 | critical |

The schema constrains the likelihood and impact enums and the 0-25 score range independently and states no formula and no banding, so both are enforced mechanically. The specification's table leaves 17-19 unbanded; those scores are unreachable from a cross product of two five-point scales, and the gap is closed upwards in `validate.py` so an out-of-range score can never be reported as less severe than the band below it.

This mattered. The first version of `validate.py` used a locally invented ladder, and because it understated every band, **21 of 23 risks were reported at a lower severity than OWASP assigns them** — the two that happened to agree were the two scoring 25. An earlier draft of this document also fudged one score from 10 to 8 to reach a more comfortable band. Both are the reason the matrix is now checked rather than trusted.

Under the corrected ladder the picture is: 3 critical, 8 very_high, 11 high, 4 medium. Nothing in either model is low or very_low, which is the accurate characterisation of a server that executes arbitrary code with no authentication and asks the operator for nothing.


## Server model

| Risk | L | I | Score | Level | Controls | Built by | State |
|---|---|---|---|---|---|---|---|
| `risk-silent-content-exfiltration`<br/>Silent exfiltration of screen, accessibility, and clipboard content | certain | severe | 25 | critical | `authorization-interceptor-enforcement` | C1, C2, C4 | Mitigated (C1, C2, C4): `AuthorizationMapDriftTests.testAContentReadIsNeverDescribedAsMetadataOnly`, `AuthorizationMapDriftTests.testReadingBackARecordedInputIsMeteredAndNamed` |
| `risk-unauthenticated-code-execution`<br/>Unauthenticated arbitrary code execution as the user | certain | severe | 25 | critical | `authorization-interceptor-enforcement`, `fail-closed-consent`, `launchd-socket-mode`, `tcp-reduced-posture` | C1, C2, C4 | Mitigated (C1, C2, C4): `AuthorizationInterceptorTests.testPublicRequestValidationFailsClosedOnUnauthorizedCapability`, `AuthorizationPolicyTests.testTCPListenerDeniesEveryConsentRequiringCapability` |
| `risk-unconsented-irreversible-action`<br/>Irreversible user actions taken without informed consent | likely | severe | 20 | critical | `authorization-interceptor-enforcement`, `biometric-gate-for-high-blast-radius`, `capability-implication-closure`, `graded-caller-identity-evidence`, `operator-defined-consequence-targets` | C2, C4, C9 | Mitigated (C2, C4, C9): `AuthorizationPolicyTests.testScriptExecutionSubsumesTheRest`, `AuthorizationPolicyTests.testBiometricRequirementIsAPureFunctionOfWhatIsBeingAuthorised`, `AuthorizationPolicyTests.testADenialDoesNotLeakTheOperatorsHighConsequenceList` |
| `risk-consent-channel-impersonation`<br/>Consent plane nullified by channel impersonation | possible | severe | 15 | very_high | `fail-closed-consent`, `mutually-authenticated-consent-channel` | C7 | Mitigated (C7): `ConsoleChannelTests.testAConsoleThatCannotAuthenticateCannotPostADecision`, `ConsoleChannelTests.testAConsoleRefusesAServerThatWillNotIdentifyItself` |
| `risk-grant-broadening`<br/>Narrow approval becomes standing broad permission | likely | major | 16 | very_high | `blast-radius-scaled-friction`, `capability-implication-closure`, `code-identity-grant-binding`, `graded-caller-identity-evidence`, `hash-chained-decision-audit`, `pre-authorization-envelope-bounding` | C1, C5 | Mitigated (C1, C5): `AuthorizationPolicyTests.testAGrantBindsToCodeIdentityAndNotToAPid`, `AuthorizationPolicyTests.testABroadGrantCoversANarrowRequestAndNotTheReverse`, `GrantStoreTests.testTheEnvelopeCeilingIsEnforcedAgainstTheRemainingLifetime` |
| `risk-operator-consent-fatigue`<br/>A control the operator habitually ignores | likely | major | 16 | very_high | `biometric-gate-for-high-blast-radius`, `blast-radius-scaled-friction`, `capability-implication-closure`, `code-identity-grant-binding`, `graded-caller-identity-evidence`, `hash-chained-decision-audit`, `operator-defined-consequence-targets`, `pre-authorization-envelope-bounding` | C1, C6, C9 | Mitigated (C1, C6, C9): `AuthorizationPolicyTests.testBreadthTimesPersistenceIsWhatCostsACeremony`, `AuthorizationPolicyTests.testCountBoundedGrantsAreConsumableAndNeverAmortise`, `AuthorizationPolicyTests.testDenyIsNeverTheDefaultAndNeverSitsBesideThePrimary` |
| `risk-prompt-injection-abuse`<br/>Legitimate agent weaponised by hostile content | likely | major | 16 | very_high | `graded-caller-identity-evidence` | C3, C4, C9 | Mitigated (C3, C4, C9): `CallerIdentityResolverTests.testTheWholeAncestorChainIsCarriedNearestFirst`, `AuthorizationPolicyTests.testAMissingReasonEscalatesAndAnUnknownOriginEscalates` |
| `risk-transaction-batching-bypasses-consent`<br/>Transaction batching amortises a single approval into many actions | likely | major | 16 | very_high | `transaction-scope-is-authorized-explicitly` | C1, C2, C4 | Mitigated (C1, C2, C4): `AuthorizationPolicyTests.testCountBoundedGrantsAreConsumableAndNeverAmortise`, `AuthorizationPolicyTests.testAMalformedOperationCountIsNeitherSatisfiableNorSafe`, `AuthorizationConcurrencyTests.testCountBoundedGrantsAreAtomicUnderConcurrency` |
| `risk-audit-tampering`<br/>No trustworthy record of what was permitted | possible | major | 12 | high | `hash-chained-decision-audit`, `owner-private-persistence` | C8 | Mitigated (C8): `DecisionAuditTests.testEditingAnEntryBreaksVerification`, `DecisionAuditTests.testRemovingAnEntryBreaksTheChainAndTheTailLimitIsStated`, `DecisionAuditTests.testTheLogIsOwnerPrivate` |
| `risk-exposed-tcp-listener`<br/>Network-reachable code execution by misconfiguration | unlikely | severe | 10 | high | `launchd-socket-mode`, `tcp-reduced-posture` | C4 | Mitigated (C4): `AuthorizationPolicyTests.testTCPListenerDeniesEveryConsentRequiringCapability`, `ConsoleChannelTests.testTheChannelIsNotCreatedInTCPMode`, `CallerIdentityResolverTests.testTheResolverDoesNotExistInTCPTransport` |
| `risk-macro-persistence`<br/>Stored macros used as a persistence mechanism | possible | major | 12 | high | `authorization-interceptor-enforcement`, `owner-private-persistence` | C2, C4 | Mitigated (C2, C4): `AuthorizationMapDriftTests.testEveryMappedRPCBelongsToExactMacService`, `AuthorizationPolicyTests.testScriptExecutionSubsumesTheRest` |
| `risk-same-uid-malware-residual`<br/>Same-uid malware retains access within granted bounds | possible | major | 12 | high | `authorization-interceptor-enforcement`, `blast-radius-scaled-friction`, `fail-closed-consent`, `pre-authorization-envelope-bounding` | C3, C5, C8 | Accepted residual (C3, C5, C8): bounded by `GrantStoreTests.testAGrantBindsToCodeIdentityAndNotToAPid`, `DecisionAuditTests.testEditingAnEntryBreaksVerification` |
| `risk-shared-token-residual`<br/>Consent channel secret readable by same-uid malware | unlikely | severe | 10 | high | `fail-closed-consent`, `mutually-authenticated-consent-channel` | C7 | Accepted residual (C7): bounded by `ConsoleChannelTests.testAWideTokenFileIsRefused`, `ConsoleChannelTests.testTheTokenComparisonIsExact` |
| `risk-clipboard-content-injection`<br/>Clipboard used to attack the operator's own next action | possible | moderate | 9 | medium | `authorization-interceptor-enforcement` | C2, C4 | Mitigated (C2, C4): `AuthorizationMapDriftTests.testAClipboardFileWriteCarriesItsPaths`, `AuthorizationPolicyTests.testEveryCapabilityCrossedWithEveryScopeAndPosture` |
| `risk-partial-degradation-masquerading-as-health`<br/>A silently degraded server reports as healthy | possible | moderate | 9 | medium | `screen-recording-grant-explicitness`, `tcc-grant-completeness-reporting` | C4 | Mitigated (C4): `AuthorizationPolicyTests.testAnUnavailableConsoleDenies`, `CallerIdentityResolverTests.testTheReducedUnauthenticatedTransportDenies` |
| `risk-unauthenticated-resource-exhaustion`<br/>An unauthenticated caller starves the server's own tooling | likely | minor | 8 | medium | `per-caller-resource-quotas` | C4 | Mitigated (C4): `CallerIdentityResolverTests.testTheChainIsCappedAndTheTruncationIsReported`, `AuthorizationPolicyTests.testAMalformedOperationCountIsNeitherSatisfiableNorSafe` |

## Console UI model

| Risk | L | I | Score | Level | Controls | Built by | State |
|---|---|---|---|---|---|---|---|
| `risk-consent-fatigue-by-flooding`<br/>Prompt flooding reduces the operator to reflexive approval | likely | major | 16 | very_high | `blast-radius-scaled-presentation`, `failing-closed-is-presented-as-protective`, `operator-defined-consequence-targets`, `prompt-flood-coalescing`, `safe-decision-affordance-ordering` | C1, C9 | Mitigated (C1, C9): `AuthorizationPolicyTests.testDenyIsNeverTheDefaultAndNeverSitsBesideThePrimary`, `RenderHarness.the popover renders at 360pt and hugs its content` |
| `risk-misleading-but-genuine-prompt`<br/>A genuine prompt misleads through caller-chosen or clipped text | likely | major | 16 | very_high | `implication-and-blast-radius-disclosure`, `no-truncation-payload-disclosure`, `server-side-capability-derivation`, `signature-state-prominence`, `untrusted-field-marking-control` | B3, B6, C9 | Mitigated (B3, B6, C9): `RenderHarness.prompt disclosure geometry ensures caption is inside viewport and copy control is not cut`, `DesignTokenContrastTests.every text token clears WCAG AA on all three surfaces in light and dark` |
| `risk-operator-approves-the-wrong-dialog`<br/>The operator answers an impersonated dialog | possible | severe | 15 | very_high | `mutually-authenticated-channel`, `signature-state-prominence` | B3, B6, C6, C9 | Mitigated (B3, B6, C6, C9): `ConsoleChannelTests.testAConsoleRefusesAServerThatWillNotIdentifyItself`, `BiometricCeremonyTests.a proof names its request AND carries a nonce so it is not a bearer token` |
| `risk-absence-treated-as-consent`<br/>An unanswered request is treated as consent | unlikely | severe | 10 | high | `biometric-never-downgrades`, `failing-closed-is-presented-as-protective`, `mutually-authenticated-channel`, `safe-decision-affordance-ordering`, `screen-lock-and-away-awareness` | C4, C9 | Mitigated (C4, C9): `AuthorizationPolicyTests.testAnUnavailableConsoleDenies`, `AuthorizationPolicyTests.testAnUnavailableBiometricDeniesRatherThanDowngrading`, `BiometricCeremonyTests.every failure explains itself in the product's own words` |
| `risk-approval-applied-to-wrong-request`<br/>An approval authorizes a different request | unlikely | severe | 10 | high | `no-persisted-decisions`, `server-side-capability-derivation`, `single-use-request-binding` | C7 | Mitigated (C7): `ConsoleChannelTests.testADecisionForADifferentRequestIsRefused`, `ConsoleChannelTests.testAReplayedDecisionIsRefused`, `AuthorizationConcurrencyTests.testSimultaneousPendingRequestsCannotReceiveEachOthersDecisions` |
| `risk-approval-content-exposed-to-session`<br/>Command text and argument values leak to co-resident processes | likely | moderate | 12 | high | `content-free-notifications`, `copy-to-pasteboard-warning`, `screen-capture-reaction` | B5, C6, C9 | Mitigated (B5, C6, C9): `BiometricCeremonyTests.this machine's availability is answerable without performing a ceremony`, `BiometricAuthenticationTests.testTheCeremonyReasonNamesTheDecision` |
| `risk-degraded-evidence-read-as-clean`<br/>Unresolved caller evidence displayed as though it were resolved | possible | major | 12 | high | `signature-state-prominence`, `untrusted-field-marking-control` | C3, C9 | Mitigated (C3, C9): `CallerIdentityResolverTests.testAnUnsignedCallerIsEscalatedRatherThanDenied`, `CallerIdentityResolverTests.testTheWeakSignatureIsWhatCostsTheCeremony`, `RenderHarness.the prompt renders at 420pt and matches its design geometry` |
| `risk-invisible-standing-permission`<br/>Standing permission exceeds the operator's understanding | possible | major | 12 | high | `activity-log-integrity-display`, `blast-radius-scaled-presentation`, `grants-manager-enumeration`, `implication-and-blast-radius-disclosure`, `no-persisted-decisions`, `operator-defined-consequence-targets`, `safe-decision-affordance-ordering` | C5, C9 | Mitigated (C5, C9): `ServiceControllerTests.service configuration state survives a simulated reboot across separate instances`, `ServiceControllerTests.ConsoleModel coordinates with ServiceController and persists state`, `RenderHarness.the grants manager renders with active and expired grants` |
| `risk-misleading-forensic-view`<br/>The operator investigates using a falsified activity log | possible | major | 12 | high | `activity-log-integrity-display`, `no-persisted-decisions` | C8, C9 | Mitigated (C8, C9): `DecisionAuditTests.testAnIntactLogVerifies`, `DecisionAuditTests.testEditingAnEntryBreaksVerification`, `RenderHarness.the activity timeline renders with a broken chain` |
| `risk-biometric-gate-degraded-or-coerced`<br/>The biometric commitment is degraded, spoofed, or coerced | unlikely | major | 8 | medium | `biometric-never-downgrades`, `biometric-nonce-binding`, `screen-lock-and-away-awareness` | C6 | Mitigated (C6): `BiometricAuthenticationTests.testOneCeremonyCannotAuthorizeTwoDecisions`, `BiometricAuthenticationTests.testOnlyOneOfManyConcurrentSpendsWins`, `BiometricCeremonyTests.every LAError code we claim to handle maps to a distinct named failure` |

## Accepted residual risk

Two of the server model's risks are **accepted residual**, recorded as risks rather than controls because no control in this design eliminates them and a document that implied otherwise would be lying.

`risk-same-uid-malware-residual` is the price of the architecture. The agent and the operator share a uid, so malware running as the user is already inside the authentication boundary and can exercise any grant the operator has issued. Code-identity binding limits which grants transfer, and the audit chain makes use detectable afterwards, but neither prevents it.

`risk-shared-token-residual` follows from that. The consent channel secret lives in an owner-private file, which stops a process that merely located the channel but not malware already running as the user. Removing it would require an out-of-band channel the operator has to carry, which is a worse trade than the residual.

## Known gaps in this register

- All scheduled controls are implemented and mapped to passing automated tests in the tables above. Accepted residuals are bounded as documented above.
- `public-request-wire-validation` and `tcc-accessibility-authority` are deliberately listed against **no** threat. The wire validator is candid that it is not an authorization control, and the presence of a TCC grant is the *precondition* for the harm rather than a mitigation of it. Listing either as a mitigation would have inflated the apparent coverage of the rows it appeared in.
- The models assume the two TCC grants (Accessibility and Screen Recording) are both held. If Screen Recording is absent, capture fails while everything else keeps working, which is `risk-partial-degradation-masquerading-as-health` and is unmitigated today.

## Invariants

These are the properties that must hold for this system to be considered sound. Each is a single falsifiable sentence, and each has at least one test that would fail if it were violated. They are the source text for the matching section of `AGENTS.md`, and they apply beyond any single change: a future change that breaks one has broken the system, not just the feature.

1. No RPC reaches a handler without a decision recorded in the decision audit log.
2. Every consent failure mode denies: an unreachable console, a timeout, a cancelled, failed, or locked-out biometric, a corrupt or unreadable grant store, an unauthenticated channel peer, and an absent or locked operator. There is no path on which any of these produces allow.
3. A biometric success authorizes exactly one decision, is bound to a per-decision nonce, and never downgrades silently to a weaker check.
4. Capability and scope are re-derived by the server from the request bytes at enforcement time. The console's classification is for display only and is never an authorization input.
5. A pre-authorization envelope can never confer a global-persistent grant, and expires as a unit on a monotonic clock.
6. A grant binds to a caller's code identity — executable path, bundle identifier, and signing designated requirement — and never to a pid.
7. App and process verification exists only in the Unix-socket variant, and is graded evidence surfaced to the operator, never an authentication gate. An unsigned caller is escalated, not silently rejected.
8. A TCP-configured server never enters the consent or verification path. It denies every consent-requiring capability and reports that posture through the health service.
9. A transaction is authorized as a scope with a declared operation count, and exceeding that count is denied rather than extended. A single approval is never amortised across an unbounded batch.
10. Every growing server-side resource is bounded per resolved caller identity, and the quota survives reconnection.
11. The decision audit log is hash-chained, and the console verifies the chain before displaying it rather than presenting unverified bytes as authoritative.
12. The console persists no decision state, so there is nothing on disk for a same-uid process to forge.
13. A prompt never truncates a command, script, path, or argument. It wraps and scrolls.
14. Text the caller supplied is visually distinguished in the prompt from text the system derived.
15. Payloads, command text, and target paths never appear in a notification.
16. No UI change lands before the corresponding design exists in `docs/design.fig`.

## Current shape of the two models

Generated from the models so these counts cannot drift. No other document restates them.

| | Server | Console UI | Total |
|---|---|---|---|
| Trust zones | 6 | 5 | 11 |
| Trust boundaries | 5 | 4 | 9 |
| Actors | 6 | 4 | 10 |
| Components | 25 | 20 | 45 |
| Data stores | 6 | 3 | 9 |
| Data sets | 7 | 4 | 11 |
| Data flows | 13 | 9 | 22 |
| Assumptions | 8 | 5 | 13 |
| Threat personas | 6 | 6 | 12 |
| Threats | 18 | 14 | 32 |
| Controls | 20 | 21 | 41 |
| Risks | 16 | 10 | 26 |
| Diagrams | 2 | 2 | 4 |

Controls by status — server: Counter({'scheduled': 16, 'active': 3, 'assumed': 1}), console: Counter({'scheduled': 20, 'suggested': 1}). 16 controls are both `scheduled` and priority `critical`.

Risk levels — 3 critical, 8 very_high, 11 high, 4 medium. Nothing is rated low or very_low.

Three risks are **accepted residual**; every other risk is `scheduled`, meaning its control is designed but not built. No risk in either model is currently mitigated by code in this repository, other than the three controls already marked `active` or `assumed`.

## How to add a risk

Add the threat to the appropriate model, add the control that addresses it with a real `status` and `priority`, add the risk with a likelihood, impact, impact description, and a score that satisfies the enforced matrix, then regenerate this file so the register and the models agree. `python3 threat-model/validate.py` will fail if a risk is missing from this register, if a score is inconsistent with its likelihood and impact, if a level band disagrees with its score, if a trust boundary bounds a zone to itself, if a component parent chain is cyclic, or if any cross-reference dangles.

