# Threat models

Two schema-valid threat models for ExactMac, plus the risk register that joins them to the implementation.

```
threat-model/
├── schema/threat-model.schema.json   OWASP Threat Model Library v1.0.2, vendored byte-identical
├── exactmac-server.threat-model.json the gRPC server, its authorization plane, and its deployment variants
├── exactmac-console-ui.threat-model.json  the consent console, the disclosures, and the human decision
├── RISKS.md                           every risk, its controls, the task that builds them, and the invariants
├── LITERATURE.md                     what each source is and what it is used for here
├── validate.py                        the harness that gates all of the above
└── README.md                          this file
```

## The short version

The ExactMac gRPC server exposes 68 methods and, by design, executes arbitrary shell, AppleScript, and
JavaScript, reads the accessibility tree of every application, captures the screen, reads the clipboard and
keeps a clipboard history, and synthesizes input as the user. **It performs no authentication and no
authorization.** Any process that can reach its socket gets all of it.

The socket is created by the server, held under an advisory lock the kernel releases when the holder
dies, and is 0600, which is a real boundary against other user accounts and against
the network. It is not a boundary against the threat that matters, because the intended consumer of this
product is an AI agent, and an AI agent runs as the same user as everything else. Any malware that has
achieved execution as the user can reach the socket.

So the honest position, which both models state rather than paper over, is that this system **cannot
cryptographically distinguish the user's own agent from malware running as the user's desktop session.** The
response cannot be a stronger boundary, because none is available. It has to be: make the human a
well-informed, low-friction judge; bind standing permission to code identity rather than to a pid; make
friction scale with what a grant actually permits rather than with a static capability label; and record
every decision, with the basis, in a log a same-uid attacker cannot quietly rewrite.

Two risks are recorded as **accepted residual** rather than mitigated, because no control here eliminates
them. A threat model that implied otherwise would be the kind of document that makes a system look reviewed
without being reviewed.

## Why two models and not one

The server model treats the consent plane as a *control*. The console model treats it as an *attack
surface*, because a control that can be spoofed, truncated, replayed, or flooded is not a control. The two
answer different questions — what does the system decide, and is the human in the loop actually in the loop —
and merging them would bury the second question inside the first.

The console model is also where the harder problems live. Authorization is something a server can get right
by comparison. Disclosure is not: a prompt that is correct but unreadable, or readable but misleading, or
complete but illegible at the size the operator is actually looking at, produces the same outcome as a wrong
prompt. The operator's decision is the only consent signal in the system, and it is one person reading a
small amount of text while an agent waits — which has four independent failure modes, and a control that
addresses only one of them is worse than none, because it manufactures confidence.

## The two deployment variants are not one boundary with an option

|  | Unix socket (supported production mode) | TCP (compatibility only) |
|---|---|---|
| Authenticating principal | the owning user, via socket access | none |
| App and process verification | yes, surfaced as graded evidence | never |
| Approvals | yes | no; every consent-requiring capability is denied |
| Threat exposure | same-uid processes, including the operator's own agent | any host that can reach the port |

`GRPC_LISTEN_ADDRESS` is not constrained to loopback and the transport is `.plaintext` in every
configuration, so a supported environment variable can turn a local-only service into an internet-reachable
one with no authentication and no audit. The TCP posture exists to make that consequence explicit rather than
to endorse it, and the reduced posture is reported through the health service so the operator cannot believe
they are protected when they are not.

## Reading the models

Start with `scope` and `description` in each file — they carry the reasoning, not just the classification.
Then the `trust_boundaries`, which is where the variants diverge. `components` names what exists today
alongside what is planned, with `control.status` distinguishing `active` from `scheduled`. **The large
majority of controls in both models are `scheduled`, and most of those are priority `critical`.** The
exact counts are in the generated shape table in [`RISKS.md`](RISKS.md) and are deliberately not restated
here, because a number copied into prose is a number that will be wrong the next time a model changes. That
distribution is the accurate statement of the gap: the mitigation set is unbuilt, and a model marking these
controls active would be describing a system that does not exist.

`threats` carry CAPEC and CWE cross-references; see [`LITERATURE.md`](LITERATURE.md) for what each is used
for and for the two references that were removed rather than left plausible-sounding.

## Validation

```sh
python3 threat-model/validate.py     # or: gmake threat-model.validate
```

Exits nonzero on any failure. It runs three checks, and the second and third exist because the schema
cannot express either:

1. **Schema conformance** against the vendored v1.0.2 file, using `jsonschema` with a `FormatChecker`. The
   format checker is a correctness requirement, not extra strictness — see `LITERATURE.md` for why an
   unsatisfiable `date-or-datetime` would otherwise reject valid timestamps.
2. **Referential integrity.** The schema resolves a `typed-symbolic-name` only to the *shape* of a
   reference and never verifies the referenced `symbolic_name` exists, so a model full of dangling references
   validates cleanly and is useless. This resolves every cross-reference, and distinguishes a dangling name
   from one defined as the wrong kind.
3. **Risk matrix and register coverage.** The schema constrains the likelihood and impact enums and the 0-25 score
   range independently and states no formula and no banding, so a model can claim a severe impact while reporting a
   comfortable score. `score` must equal likelihood x impact, the level band must follow from OWASP's published band
   table, and every risk must appear in `RISKS.md` exactly once. Deleting `RISKS.md` is itself a failure, so a gate
   cannot be made to pass by removing the artifact it checks.

`validate.py` has been hardened against malformed input: a model whose root is not an object, a collection
holding a non-array, a truncated file, or invalid JSON is reported as a per-file `FAIL` and the run continues, so one
broken model cannot hide the verdict of every model after it. It also rejects a trust boundary that bounds a zone to
itself, a cyclic `parent_component` chain, and a `RISKS.md` that is absent or unreadable.

### Known gap, stated rather than hidden

`format: uri` on `repo_link` and `release_docs_link` is **not** syntax-checked. jsonschema requires the
optional `rfc3987` package for URI format checking and it is not installed; adding an undeclared dependency
was judged worse than the gap. No model in this directory sets those fields yet. Relatedly, the schema's
`extensions` map is an empty `patternProperties` subschema, so anything placed there would be unvalidatable —
which is one reason mitigation plans live in `RISKS.md` rather than in the JSON.

## Adding to these models

Add a threat, then the control that addresses it with a real `status` and `priority`, then the risk with a
likelihood, impact, and impact description, then add the risk to `RISKS.md` with the task that will build
its control. Run `validate.py`. It will fail if a risk is missing from the register, if a score disagrees
with its likelihood and impact, if a level band disagrees with its score, or if any cross-reference dangles.

The invariants at the end of [`RISKS.md`](RISKS.md) are the properties that must hold for the system to be
considered sound. Each is a single falsifiable sentence, and they are the source text for the matching
section of the repository's `AGENTS.md`.
