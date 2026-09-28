# Copy pass — the swap table

Hana paired the redesign with "rewrite all copy using /ai-anti-patterns Skill". The skill's
Iron Law is that writing is checked sentence by sentence against its pattern list, and that
**the table is the deliverable rather than the edits**, because listing swaps without naming
what each one smuggled in hides the substantive change.

The pass ran over the console's operator-facing strings, the server-side reason sentences, and
the audit text the operator reads. It is a diction pass: meaning and structure are kept, direct
sentences are left alone, and nothing was shortened for its own sake.

## What was left alone, and why

Not every flagged-looking string is an anti-pattern, and saying so is part of a real pass.

| String | Why it stays |
|---|---|
| `EXACT REQUEST — NOTHING IS TRUNCATED`, `REASON GIVEN BY THE AGENT — NOT VERIFIED`, `TARGET — RESOLVED BY THE SYSTEM`, `NOTE TO THE AGENT — SENT BACK WITH YOUR DECISION`, `PRE-AUTHORIZATION ENVELOPE` | The ALL-CAPS eyebrow is a **type role**, not a shout: 10/600, 115 nodes, carrying every provenance caption in the product. Case is the treatment and the set is systematic. Flattening it would be a design change, and `docs/design.fig` holds it. The em dash in these is a delimiter with a job, not punctuation. |
| `Balanced — friction scales with what a grant would permit`, `Required — this cannot be turned off`, `Allow once — this exact request` | Same: an em dash separating a label from its gloss, used consistently. A system, not overuse. |
| `A shell can read the screen, the clipboard and the interface, so no script runs without a fingerprint.` | Three items because there are three things, not because three is the number that sounds good. The skill's rule of three is about *exactly three every time* as a structural tic; this is an enumeration of reachable surfaces. |
| `The service is off, so nothing is served` / `This is the safe direction.` | Direct, literal, and load-bearing: the second is the system telling the operator a failure failed safely. |

## The swaps

| # | Was | Now | What the original smuggled in |
|---|---|---|---|
| 1 | `the caller's signature is \(signature.rawValue)` | `this caller is not signed by a developer you can identify` | An **engine enum in the operator's face**. `unsigned` and `unresolved` are the finding, but they are a classification the operator cannot act on. It also claimed the signature *was* the reason, when the reason is what the classification means for this decision. |
| 2 | `running a shell reaches everything this Mac can do` | `a shell can read your screen, your clipboard and your keystrokes` | **A false claim, and an unfalsifiable one in the wrong direction.** A shell is bounded by the sandbox, TCC and SIP. An operator who can disprove the sentence stops believing the product. The replacement is narrower and true, and it is the part that matters for the decision. |
| 3 | `this grant would permit a lot` | `\(consequence) across \(every application \| the applications in scope)` | **An English opinion where an authorisation is requested.** "A lot" is not a quantity, and it was the only sentence in the function saying nothing checkable — no capability, no scope, no duration, though all three fed the risk class that raised it. |
| 4 | `The broadest grant there is.` | `The broadest grant ExactMac can issue.` | "There is" is filler and the superlative is unanchored. Naming what it is the broadest *of* removes the need to assert it. |
| 5 | `It is a standing permission, so it is worth proving you are you.` | `It stays in force until you revoke it, so approving it proves you are you.` | "Worth proving you are you" asks the operator to weigh the *value* of the grant, which is an argument. "Stays in force until you revoke it" is the duration, which is the fact. |
| 6 | `Sustained reading of everything on screen, in any application, for the life of the grant.` | `Reads everything on screen, in every application, for as long as the grant lasts.` | **Nominalisation, twice.** "Sustained reading" is a category rather than an act, and "the life of the grant" gives a permission a life. Neither tells the operator what happens. |
| 7 | `Wiping every standing permission is exactly the moment a stolen session would want.` | `If someone else has your session, this is the first control they would use.` | **Motive attributed to an actor that has none.** A stolen session does not want anything. The original also smuggled in coordination — "exactly the moment" implies a plan. The skill's own example is this failure: a phrasing that implies coordinated evasion where a plain one makes no claim about motive. |
| 8 | `A narrow one-shot ask is where friction is deliberately not spent.` | `A single narrow request does not need a fingerprint.` | **Abstract nouns doing the work of a fact.** "Friction", "narrow one-shot ask", "is not spent" — three abstractions where one concrete sentence was available, and the reader has to reverse-engineer that the thing being discussed is a fingerprint. |
| 9 | `Turning this on makes every trivial request cost a fingerprint.` | `With this on, it does.` | A clumsy causative — "makes every request cost" — and "trivial" is the writer's judgement of the operator's business, not a fact. The replacement is a clause. |
| 10 | `Nothing else is asked of you — this one needs no fingerprint.` | `Nothing else is asked of you. This one needs no fingerprint.` | Not a content fault: the em dash was doing the work of a full stop in a sentence, which is the one place this product should not use a delimiter as punctuation. |

## The habit, which matters more than the ten rows

**The writer's recurring move is nominalisation: turning a concrete act into a category.**
"Sustained reading" for reading, "the life of the grant" for however long it lasts, "friction
is not spent" for no fingerprint is asked for. Each one is a small abstraction and together
they are a voice — a writer who reaches for the noun when the verb was right there, which is
also why the em dash accumulated: a noun needs a dash to carry it, a verb does not.

The second habit is **attributing intent to a system that has none** — "a stolen session would
want", "this grant would permit a lot". Both make a claim about what something wants or is
worth, and neither can be checked. On a consent prompt that is the specific failure worth
eliminating: the operator is being asked to authorise, and every sentence they read should be
something they could verify or something they could act on.

A related pattern, named rather than swapped because the skill puts it out of scope for the
table: **antithesis**. "Nothing is truncated", "not a request but a grant", "no ceremony is
required" — the product leans on "not X, but Y" and on the balanced two-part clause. It reads
as designed emphasis here rather than as machine cadence, but it is a tic and it is the thing
to watch next time the copy grows.
