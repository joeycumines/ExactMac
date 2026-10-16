package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCollectSymbolsAndIntegrity(t *testing.T) {
	model := map[string]any{
		"trust_zones": []any{
			map[string]any{"symbolic_name": "zone-a"},
			map[string]any{"symbolic_name": "zone-b"},
		},
		"trust_boundaries": []any{
			map[string]any{"trust_zone_a": "zone-a", "trust_zone_b": "zone-b"},
		},
		"actors": []any{
			map[string]any{"symbolic_name": "actor-1", "trust_zone": "zone-a"},
		},
		"components": []any{
			map[string]any{"symbolic_name": "comp-root", "trust_zone": "zone-a"},
			map[string]any{"symbolic_name": "comp-child", "trust_zone": "zone-a", "parent_component": "comp-root"},
		},
		"threat_personas": []any{
			map[string]any{"symbolic_name": "persona-1"},
		},
		"threats": []any{
			map[string]any{
				"symbolic_name":       "threat-1",
				"threat_persona":      "persona-1",
				"components_affected": []any{"comp-child"},
			},
		},
		"controls": []any{
			map[string]any{
				"symbolic_name": "ctrl-1",
				"threats":       []any{"threat-1"},
			},
		},
		"risks": []any{
			map[string]any{
				"symbolic_name": "risk-1",
				"threats":       []any{"threat-1"},
				"likelihood":    "possible",
				"impact":        "moderate",
				"score":         float64(9),
				"level":         "medium",
			},
		},
	}

	checker := newIntegrityChecker(model)
	errs := checker.Run()
	if len(errs) != 0 {
		t.Fatalf("expected 0 integrity errors, got %d: %v", len(errs), errs)
	}

	riskErrs := validateRiskMatrix(model)
	if len(riskErrs) != 0 {
		t.Fatalf("expected 0 risk matrix errors, got %d: %v", len(riskErrs), riskErrs)
	}
}

func TestComponentCycleDetection(t *testing.T) {
	model := map[string]any{
		"trust_zones": []any{
			map[string]any{"symbolic_name": "zone-a"},
		},
		"components": []any{
			map[string]any{"symbolic_name": "a", "trust_zone": "zone-a", "parent_component": "b"},
			map[string]any{"symbolic_name": "b", "trust_zone": "zone-a", "parent_component": "a"},
		},
	}

	checker := newIntegrityChecker(model)
	errs := checker.Run()
	foundCycle := false
	for _, err := range errs {
		if err.Message == `parent chain forms a cycle at "b"` || err.Message == `parent chain forms a cycle at "a"` {
			foundCycle = true
			break
		}
	}
	if !foundCycle {
		t.Fatalf("expected cycle error, got: %v", errs)
	}
}

func TestRiskMatrixValidation(t *testing.T) {
	// Score mismatch
	modelScoreMismatch := map[string]any{
		"risks": []any{
			map[string]any{
				"symbolic_name": "risk-bad-score",
				"likelihood":    "likely",    // 4
				"impact":        "major",     // 4
				"score":         float64(10), // expected 16
				"level":         "high",      // band for 10 is high, but score 10 != 4*4
			},
		},
	}
	errs := validateRiskMatrix(modelScoreMismatch)
	if len(errs) != 1 {
		t.Fatalf("expected 1 error for score mismatch, got: %v", errs)
	}

	// Level mismatch
	modelLevelMismatch := map[string]any{
		"risks": []any{
			map[string]any{
				"symbolic_name": "risk-bad-level",
				"likelihood":    "likely",    // 4
				"impact":        "major",     // 4
				"score":         float64(16), // 4*4 = 16
				"level":         "low",       // band for 16 is very_high, not low
			},
		},
	}
	errs = validateRiskMatrix(modelLevelMismatch)
	if len(errs) != 1 {
		t.Fatalf("expected 1 error for level mismatch, got: %v", errs)
	}
}

func TestRiskRegisterValidation(t *testing.T) {
	tmpDir := t.TempDir()
	risksFile := filepath.Join(tmpDir, "RISKS.md")
	content := "# Risk Register\n\n| ID | Risk |\n|---|---|\n| R1 | `risk-1` |\n"
	if err := os.WriteFile(risksFile, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}

	models := []map[string]any{
		{
			"risks": []any{
				map[string]any{"symbolic_name": "risk-1"},
			},
		},
	}
	errs := validateRiskRegister(models, risksFile)
	if len(errs) != 0 {
		t.Fatalf("expected 0 register errors, got: %v", errs)
	}

	// Missing risk
	missingModel := []map[string]any{
		{
			"risks": []any{
				map[string]any{"symbolic_name": "risk-missing"},
			},
		},
	}
	errs = validateRiskRegister(missingModel, risksFile)
	if len(errs) != 1 {
		t.Fatalf("expected 1 missing error, got: %v", errs)
	}
}
