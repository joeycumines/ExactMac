# make/threat-model.mk: Validation of the OWASP threat models under threat-model/.
#
# This is a tracked make module rather than a config.mk custom target, because the
# validation must be invocable from CI and config.mk is gitignored. See the note in
# threat-model/README.md.

# Python interpreter used to run the validator (overridable).
THREAT_MODEL_PYTHON ?= python3
# Path to the OWASP Threat Model Library schema (v1.0.2) vendored in-tree.
THREAT_MODEL_SCHEMA ?= $(PROJECT_ROOT)/threat-model/schema/threat-model.schema.json
# Directory scanned for *.threat-model.json files.
THREAT_MODEL_DIR ?= $(PROJECT_ROOT)/threat-model
# Extra arguments passed to the validator, e.g. THREAT_MODEL_ARGS=--quiet
THREAT_MODEL_ARGS ?=

##@ Threat Model Targets

.PHONY: threat-model.validate
threat-model.validate: ## Validate threat-model/*.threat-model.json against the vendored OWASP schema
	@test -f "$(THREAT_MODEL_SCHEMA)" || { \
		echo "ERROR: vendored schema not found at $(THREAT_MODEL_SCHEMA)"; exit 1; }
	@cd "$(PROJECT_ROOT)" && $(THREAT_MODEL_PYTHON) threat-model/validate.py $(THREAT_MODEL_ARGS)
