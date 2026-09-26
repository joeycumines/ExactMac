# Literature and references

Every entry below was retrieved and read while producing these models, or is a canonical artifact vendored
into this repository. Nothing here is cited from memory, and an entry that could not be verified was
corrected or removed rather than left standing. Where a citation is a taxonomy rather than a standard, the
models lead with a mechanism description and treat the taxonomy identifier as a cross-reference, because
most of the weakness entries in scope are still Draft or Incomplete upstream and a bare identifier would
imply a maturity the taxonomy does not have.

## The OWASP Threat Model Library

**Schema, v1.0.2** — <https://github.com/OWASP/www-project-threat-model-library/blob/v1.0.2/threat-model.schema.json>.
Vendored byte-identical at [`schema/threat-model.schema.json`](schema/threat-model.schema.json), 34,317 bytes,
sha256 `428772fecfed799921e90bb7e7acf7ce7bb8e379128e43c4e7f4346a528539be`. This is the normative structure
for both models. Used for: every field, every enum, and the `additionalProperties: false` root that forces
the model's entire vocabulary to be explicit.

Three properties of this schema shaped the work and are worth recording, because each was found by running
the validator rather than by reading:

- The root is `additionalProperties: false`, and the permitted key set does **not** include a top-level
  `mitigation_plans`, even though `$defs` defines a `mitigation-plan` shape. A mitigation plan therefore
  cannot legally sit at the top level. Rather than force one in through the `extensions` map — which would
  require inventing a namespaced key, and no domain is owned by this project — mitigation planning uses the
  mechanism the schema actually provides, namely each `control` naming its `threats` and carrying its own
  `status` and `priority`, with the explicit risk-to-control traceability in [`RISKS.md`](RISKS.md).
- `typed-symbolic-name.type` is an **unconstrained string**. The schema's own description says only "as a
  `'#/$defs/...'` or simple `'...'` type reference" and mandates no spelling. The published reference model
  in that repository writes `data_store` with an underscore, so both spellings resolve in `validate.py`.
- `date-or-datetime` is `oneOf` over a `date` branch and a `date-time` branch. Format is annotation-only
  unless a `FormatChecker` is supplied, so without one every string satisfies both branches, `oneOf` always
  fails, and a correct `reviewed_at` is **rejected**. A format checker is therefore a correctness requirement
  rather than extra strictness.

**Library README, v1.0.2** — <https://github.com/OWASP/www-project-threat-model-library/blob/v1.0.2/README.md>.
Used for: the project's stated purpose, and specifically its guidance that a threat model may be produced
with any tool provided the output converts to the schema's JSON, and its recommendation to validate with
`check-jsonschema` or `jsonschema`. The second recommendation is why `validate.py` uses the `jsonschema`
library directly, which is also what is installed here.

**Specification** — referenced by the schema's own `$comment` as the `div-specification` anchor on
<https://owasp.org/www-project-threat-model-library/>. The schema points at it as the authority for the risk
scoring matrix, and this project follows that matrix: score is likelihood x impact on five-point scales, and
`validate.py` derives the level bands as 0-4 `very_low`, 5-9 `low`, 10-14 `medium`, 15-19 `high`, 20-24
`very_high`, 25 `critical`.

**Reference model** — `threat-models/ai-ml-systems/husky-ai-threat-model.json` in the same tag, retrieved and
run through `validate.py` as an independent test of the harness. Used for: proving the tool accepts real
schema-valid input, and demonstrating that it also reports four genuine defects in that model — a `$schema`
value that is not the required constant, a dangling `user` actor reference, a `bastion` reference typed as a
data store when it is defined as a component, and `api-keys-storage` / `secret-keys-storage` typos that do
not match their defined stores.

## Threat source taxonomy

**NIST SP 800-30 Rev 1** — <https://nvlpubs.nist.gov/nistpubs/legacy/sp/nistspecialpublication800-30r1.pdf>.
Cited here because the schema's `threat.sources` enum — `adversary`, `human_error`, `failure`,
`events_beyond_org_control` — is drawn from this document, and the schema's own `$comment` points at it for
exactly that attribution. Used for: classifying the source of every threat in both models. The distinction
matters to the model rather than being bookkeeping: `risk-operator-consent-fatigue` is sourced to
`human_error`, which is the reason a uniform prompt is treated as a *failed control* rather than as a
tolerable annoyance.

## CWE — MITRE Common Weakness Enumeration

Catalog retrieved from <https://cwe.mitre.org/data/csv/1000.csv.zip> and every identifier used in these
models was checked against it. All 25 identifiers in scope exist in the catalog. Titles were corrected to the
catalog's exact text in four cases, where an abbreviated form had been written:

| CWE | Catalog name |
|---|---|
| 78 | Improper Neutralization of Special Elements used in an OS Command ('OS Command Injection') |
| 77 | Improper Neutralization of Special Elements used in a Command ('Command Injection') |
| 367 | Time-of-check Time-of-use (TOCTOU) Race Condition |
| 362 | Concurrent Execution using Shared Resource with Improper Synchronization ('Race Condition') |

The CWE load-bearing for this system's design decisions:

- **CWE-306 Missing Authentication for Critical Function** — the server's present state, for every one of
  the 68 methods.
- **CWE-862 Missing Authorization** and **CWE-863 Incorrect Authorization** — the distinction the access
  model turns on: nothing is authorized at all today, and a grant bound too loosely is authorized wrongly.
- **CWE-269 Improper Privilege Management** — standing permission that outlives the session that created it,
  which is the `risk-grant-broadening` family.
- **CWE-367 Time-of-check Time-of-use** — the gap between what the prompt displayed and what the server
  enforces, answered architecturally by re-deriving capability and scope from the request bytes.
- **CWE-451 UI Misrepresentation of Critical Information** — the whole disclosure class in the console
  model: prompt impersonation, in-dialog label spoofing, payload truncation, and degraded evidence rendered
  as though it were clean.

Upstream status of the entries in scope, stated because it bounds how much weight the identifiers carry:
only CWE-20 and CWE-78 are `Stable`; 8 are `Incomplete` and 15 are `Draft`. That is the
reason the models describe mechanisms in prose and cite these as cross-references rather than leaning on the
taxonomy as an authority.

## CAPEC — MITRE Common Attack Pattern Enumeration and Classification

Identifiers checked against `https://capec.mitre.org/data/definitions/<id>.html` at CAPEC version 3.9. Note
that the `data/xml/capec_catalog.xml` bulk catalog URL returns 404, so the per-definition pages were used.

| CAPEC | Name (v3.9) | Used for |
|---|---|---|
| 88 | OS Command Injection | `unauthenticated-local-code-execution`, `remote-code-execution-on-exposed-tcp` |
| 242 | Code Injection | `prompt-injection-driven-capability-abuse` |
| 151 | Identity Spoofing | `consent-channel-impersonation`, and the impersonation and label-spoofing threats in the console model |
| 118 | Collect and Analyze Information | the exfiltration and harvest threats in the server model |

**Two references were removed rather than corrected.** `CAPEC-12` was cited as "Blind Injection" and
`CAPEC-118` as "Data Leakage"; both titles are wrong. CAPEC-12 is "Choosing Message Identifier", and CAPEC-118
is "Collect and Analyze Information", with the string "Data Leakage" appearing nowhere on its page — CAPEC
3.9 reorganised the pattern names around activity-based categories. The CAPEC-118 references were relabelled
to the catalog's current name, which is the correct taxonomy term for the collection half of what those
threats describe. The CAPEC-12 reference was dropped outright and the threat relies on its CWE entries
instead, because no correct identifier was verified and a plausible-sounding one is worse than none.

## macOS platform documentation

Used for the platform mechanisms the design depends on. These are cited for behaviour the implementation
depends on, and each is a place where a wrong assumption would produce a control that does not work.

- **LocalAuthentication** — <https://developer.apple.com/documentation/localauthentication>.
  `LAContext.canEvaluatePolicy` and `evaluatePolicy` with `.deviceOwnerAuthenticationWithBiometrics` and
  `.deviceOwnerAuthentication`. Used for: the `biometric-gate` and `biometric-gate-for-high-blast-radius`
  controls, and for the invariant that an unavailable or locked-out biometric denies rather than downgrading.
- **Security framework code signing** — `SecStaticCodeCreateWithPath`, `SecStaticCodeCheckValidity`, and
  `SecCodeCopySigningInformation` for the signing designated requirement. Used for:
  `caller-identity-resolver` and `code-identity-grant-binding`. The designated requirement is the reason a
  grant can bind to something more stable than a path or a pid.
- **App Sandbox and entitlements** — <https://developer.apple.com/documentation/security>. Used for: the
  decision not to depend on the sandbox for the server, which must reach the accessibility API, CoreGraphics
  event injection, and the pasteboard, and which therefore runs under the operator's own authority instead.
- **TCC / Privacy & Security** — Accessibility, Screen Recording, and Automation. Used for: the
  `tcc-accessibility-authority` control, recorded as `assumed` rather than `active`, and for the explicit
  caveat that it is all-or-nothing per application and cannot distinguish one agent from another, so it must
  not be relied on as the consent control.
- **Screen capture indicators** — <https://developer.apple.com/documentation/screencapturekit>. Used for:
  `screen-capture-detector`, recorded as a `suggested` mitigation rather than a control, because macOS
  provides no primitive by which an application can prevent its own windows from being captured.

## References deliberately not used

- **OWASP Top 10 for LLM Applications.** The prompt-injection threats in these models are the closest
  analogue to LLM01, but the schema's `weaknesses` field accepts only CWE identifiers, so citing an
  LLM-specific catalogue there is not possible. The threat is described by mechanism in prose instead.
- **Any prior-art ExactMac threat model.** None was found, and none is assumed. The `attack-pattern` corpus
  at cwe.mitre.org was not searched exhaustively; the statement is that no published model for this project
  was located, not that none exists.
- **STRIDE, PAFF, or another methodology as a framing.** The models follow the OWASP library's structure
  because that structure is the deliverable. A second methodology layered on top would add vocabulary
  without adding a control, and the CWE and CAPEC cross-references already carry the technique-level detail.
