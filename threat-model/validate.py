#!/usr/bin/env python3
"""Validate ExactMac threat models against the OWASP Threat Model Library schema.

Three independent checks run over every ``*.threat-model.json`` file found under the
threat-model directory:

1. **Schema conformance** against the vendored OWASP schema
   (``threat-model/schema/threat-model.schema.json``, v1.0.2), using
   ``jsonschema.Draft202012Validator``. The schema is the authority on structure,
   enumerations, and required properties.

2. **Referential integrity**, which the schema cannot express. The schema resolves
   ``typed-symbolic-name`` only to the *shape* of a reference; nothing verifies that
   the referenced ``symbolic_name`` actually exists. A model full of dangling
   references validates cleanly against the schema and is useless, so this check
   resolves every cross-reference against the collections that define symbols.

Usage::

    python3 threat-model/validate.py [--quiet]

Exits 0 only when every discovered model passes all three checks.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

try:
    from jsonschema import Draft202012Validator, FormatChecker
except ImportError:  # pragma: no cover - environment guard
    sys.stderr.write(
        "validate.py requires the jsonschema package.\n"
        "Install it with: python3 -m pip install jsonschema\n"
    )
    raise SystemExit(2) from None

REPO_ROOT = Path(__file__).resolve().parent.parent
THREAT_MODEL_DIR = REPO_ROOT / "threat-model"
SCHEMA_PATH = THREAT_MODEL_DIR / "schema" / "threat-model.schema.json"
MODEL_GLOB = "*.threat-model.json"

# The OWASP risk score is the product of likelihood and impact, each on a five-point
# scale. The schema constrains the two enums and the 0-25 score range independently
# and states no formula, so both the scale and the banding are defined here.
LIKELIHOOD_VALUES = {"rare": 1, "unlikely": 2, "possible": 3, "likely": 4, "certain": 5}
IMPACT_VALUES = {
    "negligible": 1,
    "minor": 2,
    "moderate": 3,
    "major": 4,
    "severe": 5,
}

# Maps a ``typed-symbolic-name`` type reference to the top-level collection that
# defines that kind of symbol. The schema types ``type`` as a bare, UNCONSTRAINED
# string and its own description says only "as a '#/$defs/...' or simple '...'
# type reference", so it mandates no spelling. The published OWASP reference models
# write the token with an underscore (``data_store``) while the ``$defs`` keys use a
# hyphen (``data-store``), so both spellings must resolve. An unknown token is
# reported rather than guessed at.
TYPE_REFERENCE_TO_COLLECTION = {
    "trust-zone": "trust_zones",
    "trust-boundary": "trust_boundaries",
    "actor": "actors",
    "component": "components",
    "data-store": "data_stores",
    "data-set": "data_sets",
    "data-flow": "data_flows",
    "threat-persona": "threat_personas",
    "threat": "threats",
    "control": "controls",
    "risk": "risks",
}

# ``trust_boundaries`` is listed above for completeness, but a trust boundary has no
# ``symbolic_name`` in the schema, so it can never be the target of a reference.
COLLECTIONS_WITH_SYMBOLIC_NAMES = (
    "trust_zones",
    "actors",
    "components",
    "data_stores",
    "data_sets",
    "data_flows",
    "threat_personas",
    "threats",
    "controls",
    "risks",
)

_VOWELS = "aeiou"


def article(type_name: str) -> str:
    return "an" if type_name[:1].lower() in _VOWELS else "a"


def normalize_type_reference(reference: str) -> str:
    """Reduce a type reference to its canonical ``$defs`` key spelling.

    Accepts ``#/$defs/data-store``, ``data-store``, and ``data_store`` — the last
    because the published OWASP reference models use it — and lowercases the result
    so casing differences are not treated as distinct kinds.
    """
    prefix = "#/$defs/"
    if reference.startswith(prefix):
        reference = reference[len(prefix) :]
    return reference.replace("_", "-").lower()


def collect_symbols(model: dict[str, Any]) -> tuple[dict[str, set[str]], list[tuple[str, str]]]:
    """Collect defined symbolic names per collection, plus any structural problems.

    Tolerates a malformed model: a non-object root or a collection holding something
    other than a list is reported rather than raised, so one broken file cannot abort
    the run and hide the verdict of every file after it.
    """
    symbols: dict[str, set[str]] = {name: set() for name in COLLECTIONS_WITH_SYMBOLIC_NAMES}
    problems: list[tuple[str, str]] = []
    if not isinstance(model, dict):
        return symbols, [("<root>", "model must be a JSON object")]

    for collection in COLLECTIONS_WITH_SYMBOLIC_NAMES + ("trust_boundaries",):
        raw = model.get(collection)
        if raw is None:
            continue
        if not isinstance(raw, list):
            problems.append((collection, "must be an array"))
            continue
        for index, entry in enumerate(raw):
            location = f"{collection}[{index}]"
            if not isinstance(entry, dict):
                problems.append((location, "entry must be an object"))
                continue
            name = entry.get("symbolic_name")
            if name is None:
                # trust_boundaries have no symbolic_name, which is expected.
                continue
            if not isinstance(name, str):
                problems.append((location, "symbolic_name must be a string"))
                continue
            if name in symbols[collection]:
                problems.append(
                    (
                        location,
                        f"duplicate symbolic_name {name!r} in {collection}; references "
                        "to it are ambiguous",
                    )
                )
            symbols[collection].add(name)
    return symbols, problems


class IntegrityChecker:
    """Resolves every cross-reference in a model against its defining collection."""

    def __init__(self, model: dict[str, Any]) -> None:
        self.model = model
        self.symbols, self.errors = collect_symbols(model)
        # The union supports untyped references. The schema types
        # `assumption.topics` items as a bare `symbolic-name` with no type
        # qualifier at all, so membership is the only sound check for them.
        self.all_symbols: set[str] = set().union(*self.symbols.values())

    def _resolve_untyped(self, names: list[Any] | None, path: str, field: str) -> None:
        """Resolve bare symbolic names that the schema leaves untyped.

        Used for ``assumption.topics``, whose items carry no type, so any modeled
        object is a valid topic and rejecting a trust zone here would be a false
        positive on a schema-valid model.
        """
        if not isinstance(names, list):
            return
        for index, name in enumerate(names):
            location = path if len(names) == 1 else f"{path}[{index}]"
            if not isinstance(name, str):
                self.errors.append((location, f"{field} must be a string"))
            elif name not in self.all_symbols:
                self.errors.append((location, f"dangling reference: {name!r} is not defined"))

    def _resolve(self, reference: dict[str, Any], path: str) -> None:
        if not isinstance(reference, dict):
            self.errors.append((path, "reference must be an object"))
            return
        object_name = reference.get("object")
        raw_type = reference.get("type")
        if not isinstance(object_name, str) or not object_name:
            self.errors.append((path, "reference has no usable 'object' symbolic name"))
            return
        if not isinstance(raw_type, str) or not raw_type:
            self.errors.append((path, f"reference {object_name!r} has no 'type'"))
            return
        type_name = normalize_type_reference(raw_type)
        collection = TYPE_REFERENCE_TO_COLLECTION.get(type_name)
        if collection is None:
            self.errors.append(
                (
                    path,
                    f"type reference {raw_type!r} is not a known kind; expected one of "
                    + ", ".join(sorted(TYPE_REFERENCE_TO_COLLECTION)),
                )
            )
            return
        if object_name in self.symbols.get(collection, set()):
            return
        # Distinguish "defined nowhere" from "defined as a different kind", which
        # is a modelling slip rather than a typo and deserves its own message.
        elsewhere = sorted(
            other for other, names in self.symbols.items() if object_name in names
        )
        if elsewhere:
            self.errors.append(
                (
                    path,
                    f"{object_name!r} is defined as {', '.join(elsewhere)} but referenced "
                    f"as {article(type_name)} {type_name}",
                )
            )
        else:
            self.errors.append(
                (
                    path,
                    f"dangling reference: {object_name!r} is not defined as "
                    f"{article(type_name)} {type_name}",
                )
            )

    def _resolve_bare(
        self,
        names: list[Any] | None,
        collection: str,
        path_prefix: str,
        field: str,
    ) -> None:
        """Resolve a list of bare symbolic names against one collection.

        ``path_prefix`` is the full field path (for example
        ``trust_boundaries[0].trust_zone_b``) so reported locations point at the
        offending field rather than at a synthetic list index.
        """
        if not isinstance(names, list):
            return
        known = self.symbols.get(collection, set())
        for index, name in enumerate(names):
            location = path_prefix if len(names) == 1 else f"{path_prefix}[{index}]"
            if not isinstance(name, str):
                self.errors.append((location, f"{field} must be a string"))
            elif name not in known:
                self.errors.append(
                    (location, f"dangling reference: {name!r} is not in {collection}")
                )

    def _items(self, collection: str) -> list[Any]:
        """Return a collection as a list, or empty if it is absent or malformed.

        Structural problems are already reported by ``collect_symbols``, so this
        only needs to keep the traversal below from raising on a malformed file.
        """
        raw = self.model.get(collection) if isinstance(self.model, dict) else None
        return raw if isinstance(raw, list) else []

    def run(self) -> list[tuple[str, str]]:
        if not isinstance(self.model, dict):
            # collect_symbols already reported this; there is nothing to traverse.
            return self.errors
        # Every loop below tolerates a malformed collection rather than raising, so
        # one broken file cannot abort the run and hide the verdict of later files.
        for index, boundary in enumerate(self._items("trust_boundaries")):
            prefix = f"trust_boundaries[{index}]"
            if not isinstance(boundary, dict):
                self.errors.append((prefix, "entry must be an object"))
                continue
            for key in ("trust_zone_a", "trust_zone_b"):
                self._resolve_bare(
                    [boundary.get(key)] if boundary.get(key) is not None else [],
                    "trust_zones",
                    f"{prefix}.{key}",
                    key,
                )

        for index, flow in enumerate(self._items("data_flows")):
            prefix = f"data_flows[{index}]"
            if not isinstance(flow, dict):
                self.errors.append((prefix, "entry must be an object"))
                continue
            for key in ("source", "destination"):
                if key in flow:
                    self._resolve(flow[key], f"{prefix}.{key}")

        for index, entry in enumerate(self._items("actors")):
            prefix = f"actors[{index}]"
            if isinstance(entry, dict) and entry.get("trust_zone") is not None:
                self._resolve_bare(
                    [entry["trust_zone"]], "trust_zones", f"{prefix}.trust_zone", "trust_zone"
                )

        for index, entry in enumerate(self._items("components")):
            prefix = f"components[{index}]"
            if not isinstance(entry, dict):
                continue
            if entry.get("trust_zone") is not None:
                self._resolve_bare(
                    [entry["trust_zone"]], "trust_zones", f"{prefix}.trust_zone", "trust_zone"
                )
            if entry.get("parent_component") is not None:
                if entry["parent_component"] == entry.get("symbolic_name"):
                    self.errors.append(
                        (f"{prefix}.parent_component", "a component cannot be its own parent")
                    )
                self._resolve_bare(
                    [entry["parent_component"]],
                    "components",
                    f"{prefix}.parent_component",
                    "parent_component",
                )

        # data-store.trust_zone is a REQUIRED symbolic-name reference into
        # trust_zones, and is checked here alongside the sibling fields on actor and
        # component so the three cannot drift apart again.
        for index, entry in enumerate(self._items("data_stores")):
            prefix = f"data_stores[{index}]"
            if isinstance(entry, dict) and entry.get("trust_zone") is not None:
                self._resolve_bare(
                    [entry["trust_zone"]], "trust_zones", f"{prefix}.trust_zone", "trust_zone"
                )

        for index, entry in enumerate(self._items("data_sets")):
            prefix = f"data_sets[{index}]"
            if not isinstance(entry, dict):
                continue
            placements = entry.get("placements")
            if not isinstance(placements, list):
                self.errors.append((f"{prefix}.placements", "must be an array"))
                continue
            for placement_index, placement in enumerate(placements):
                if isinstance(placement, dict) and placement.get("data_store") is not None:
                    self._resolve_bare(
                        [placement["data_store"]],
                        "data_stores",
                        f"{prefix}.placements[{placement_index}].data_store",
                        "data_store",
                    )

        for index, entry in enumerate(self._items("assumptions")):
            if not isinstance(entry, dict):
                continue
            # topics items are untyped symbolic names, so any modeled object resolves.
            self._resolve_untyped(entry.get("topics"), f"assumptions[{index}].topics", "topics")

        for index, threat in enumerate(self._items("threats")):
            prefix = f"threats[{index}]"
            if not isinstance(threat, dict):
                continue
            if threat.get("threat_persona") is not None:
                self._resolve_bare(
                    [threat["threat_persona"]],
                    "threat_personas",
                    f"{prefix}.threat_persona",
                    "threat_persona",
                )
            self._resolve_bare(
                threat.get("components_affected"),
                "components",
                f"{prefix}.components_affected",
                "components_affected",
            )

        for index, control in enumerate(self._items("controls")):
            prefix = f"controls[{index}]"
            if not isinstance(control, dict):
                continue
            self._resolve_bare(control.get("threats"), "threats", f"{prefix}.threats", "threats")
            boundary = control.get("trust_boundary")
            if isinstance(boundary, dict):
                # A trust_boundary is a ref between two zones, not a symbolic object,
                # so verify both endpoints name real zones.
                for key in ("trust_zone_a", "trust_zone_b"):
                    self._resolve_bare(
                        [boundary.get(key)] if boundary.get(key) is not None else [],
                        "trust_zones",
                        f"{prefix}.trust_boundary.{key}",
                        key,
                    )

        for index, risk in enumerate(self._items("risks")):
            prefix = f"risks[{index}]"
            if isinstance(risk, dict):
                self._resolve_bare(risk.get("threats"), "threats", f"{prefix}.threats", "threats")

        # OWASP v1.0.2 defines $defs/mitigation-plan but exposes no top-level array
        # for it. Mitigation planning is therefore expressed the way the schema
        # actually supports — each control names the threats it addresses and
        # carries its own status and priority — and the explicit risk-to-control
        # traceability lives in threat-model/RISKS.md rather than being forced into
        # the machine-readable model through the extensions map.
        #
        # KNOWN GAP, recorded rather than hidden: the `extensions` map is declared as
        # patternProperties with an empty subschema, so anything placed there is
        # unconstrained and unvalidatable. The two symbolic-name fields the unused
        # $defs/mitigation-plan would have contributed are therefore unenforced. No
        # ExactMac model uses `extensions`, so nothing is currently unverified.
        return self.errors


def build_validator(schema: dict[str, Any]) -> Draft202012Validator:
    """Build the schema validator with format checking enabled.

    Format is annotation-only unless a FormatChecker is supplied, and that matters
    here in a way that produces a FALSE NEGATIVE if ignored: the schema defines
    `date-or-datetime` as `oneOf` over a `date` branch and a `date-time` branch. With
    no format checker, every string satisfies both branches and `oneOf` always fails,
    so a correct value such as "2026-09-26" is rejected. A FormatChecker is therefore
    required for correctness, not merely for stricter checking.

    jsonschema implements `date` but, with no third-party packages installed, has no
    `date-time` validator at all — so `date-time` is registered here as a pattern
    check. The alternative was adding an undeclared dependency.

    The pattern is deliberately MORE PERMISSIVE than strict RFC 3339, which mandates
    a timezone offset. Requiring the offset would reject the common authoring form
    ("2026-09-26T11:22:33"), which is a triviality rather than a defect and would
    make the tool reject work it has no reason to reject. An offset, when present,
    must still be well-formed. The goal of this checker is to distinguish a real
    timestamp from a non-timestamp, not to enforce a particular offset policy.

    Also honest about what remains unenforced: `uri` format checking in jsonschema
    requires the optional `rfc3987` package, which is not installed, so the schema's
    `format: uri` on repo_link and release_docs_link is not syntax-checked here.
    """
    checker = FormatChecker()

    @checker.checks("date-time", raises=())
    def _is_date_time(value: object) -> bool:
        if not isinstance(value, str):
            return True
        return (
            re.fullmatch(
                r"\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(\.\d+)?"
                r"([Zz]|[+-]\d{2}:\d{2})?",
                value,
            )
            is not None
        )

    return Draft202012Validator(schema, format_checker=checker)


def validate_schema(model: dict[str, Any], validator: Draft202012Validator) -> list[str]:
    errors = []
    for error in sorted(validator.iter_errors(model), key=lambda e: list(e.absolute_path)):
        location = "/".join(str(part) for part in error.absolute_path) or "<root>"
        errors.append(f"{location}: {error.message}")
    return errors


def risk_level_band(score: int) -> str:
    """The OWASP risk level band for a 0-25 risk score.

    The schema constrains the enums and the score range but states no formula, so the
    banding is stated here explicitly and applied to every risk. Encoding it means a
    score can no longer be quietly lowered to reach a more comfortable band.
    """
    if score <= 4:
        return "very_low"
    if score <= 9:
        return "low"
    if score <= 14:
        return "medium"
    if score <= 19:
        return "high"
    if score <= 24:
        return "very_high"
    return "critical"


def validate_risk_matrix(model: dict[str, Any]) -> list[tuple[str, str]]:
    """Check each risk's score against the OWASP likelihood x impact matrix.

    The schema permits any 0-25 score and any level band independently, so a model
    can claim a severe impact while reporting a comfortable score. This closes that.
    """
    if not isinstance(model, dict):
        return []
    errors: list[tuple[str, str]] = []
    risks = model.get("risks")
    if not isinstance(risks, list):
        return errors
    for index, risk in enumerate(risks):
        if not isinstance(risk, dict):
            continue
        prefix = f"risks[{index}]"
        likelihood = LIKELIHOOD_VALUES.get(risk.get("likelihood"))
        impact = IMPACT_VALUES.get(risk.get("impact"))
        score = risk.get("score")
        level = risk.get("level")
        if likelihood is None or impact is None or not isinstance(score, int):
            continue  # The schema reports the malformed enum or type itself.
        expected = likelihood * impact
        if score != expected:
            errors.append(
                (
                    prefix,
                    f"score {score} is inconsistent with likelihood "
                    f"{risk['likelihood']} x impact {risk['impact']}, which is {expected}",
                )
            )
        expected_band = risk_level_band(score)
        if level != expected_band:
            errors.append(
                (prefix, f"level {level!r} is inconsistent with score {score}, which is {expected_band}")
            )
    return errors


def validate_risk_register(models: list[dict[str, Any]]) -> list[str]:
    """Check threat-model/RISKS.md lists every modeled risk exactly once.

    The register is the join between the models and the implementation, so a risk
    that is not in it has no named owner and will not get built. Asserting coverage
    in prose is not the same as checking it, so it is checked here.
    """
    register = THREAT_MODEL_DIR / "RISKS.md"
    if not register.exists():
        return []
    try:
        text = register.read_text(encoding="utf-8")
    except OSError:
        return []

    # Count only within the register's table rows. The narrative sections below the
    # tables legitimately discuss a risk again — the accepted-residuals paragraph
    # does exactly that — so counting the whole document would be a false positive.
    rows = [line for line in text.splitlines() if line.lstrip().startswith("|")]

    errors: list[str] = []
    for model in models:
        if not isinstance(model, dict):
            continue
        risks = model.get("risks")
        if not isinstance(risks, list):
            continue
        for risk in risks:
            if not isinstance(risk, dict):
                continue
            name = risk.get("symbolic_name")
            if not isinstance(name, str):
                continue
            occurrences = sum(row.count(f"`{name}`") for row in rows)
            if occurrences == 0:
                errors.append(f"RISKS.md does not list risk {name!r}")
            elif occurrences > 1:
                errors.append(
                    f"RISKS.md lists risk {name!r} {occurrences} times; expected exactly once"
                )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quiet", action="store_true", help="only print failures and the summary")
    args = parser.parse_args()

    if not SCHEMA_PATH.exists():
        sys.stderr.write(f"vendored schema not found at {SCHEMA_PATH}\n")
        return 2

    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    validator = build_validator(schema)

    models = sorted(THREAT_MODEL_DIR.rglob(MODEL_GLOB))
    if not models:
        sys.stderr.write(f"no {MODEL_GLOB} files found under {THREAT_MODEL_DIR}\n")
        return 1

    failed = 0
    loaded: list[dict[str, Any]] = []
    for path in models:
        relative = path.relative_to(REPO_ROOT)
        # A per-file verdict is guaranteed for every discovered model: a read or
        # parse failure reports FAIL and continues, so one malformed file cannot
        # hide the verdict of the files that sort after it.
        try:
            model = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            failed += 1
            print(f"FAIL {relative}")
            print(f"  could not read as JSON: {error}")
            continue

        try:
            loaded.append(model)
            schema_errors = validate_schema(model, validator)
            integrity_errors = IntegrityChecker(model).run() + validate_risk_matrix(model)
        except Exception as error:  # noqa: BLE001 - a validator must not abort the run
            failed += 1
            print(f"FAIL {relative}")
            print(f"  validator error: {type(error).__name__}: {error}")
            continue

        if schema_errors or integrity_errors:
            failed += 1
            print(f"FAIL {relative}")
            for message in schema_errors:
                print(f"  schema: {message}")
            for location, message in integrity_errors:
                print(f"  refs:   {location}: {message}")
        elif not args.quiet:
            print(f"PASS {relative}")

    total = len(models)
    register_errors = validate_risk_register(loaded)
    if register_errors:
        failed += len(register_errors)
        print("FAIL threat-model/RISKS.md")
        for message in register_errors:
            print(f"  refs:   {message}")

    if failed:
        print(f"\n{failed} of {total} threat model(s) failed validation.")
        return 1
    print(f"\nAll {total} threat model(s) passed schema and referential-integrity validation.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
