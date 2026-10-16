package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/santhosh-tekuri/jsonschema/v5"
)

var (
	likelihoodValues = map[string]int{
		"rare":     1,
		"unlikely": 2,
		"possible": 3,
		"likely":   4,
		"certain":  5,
	}

	impactValues = map[string]int{
		"negligible": 1,
		"minor":      2,
		"moderate":   3,
		"major":      4,
		"severe":     5,
	}

	typeReferenceToCollection = map[string]string{
		"trust-zone":      "trust_zones",
		"trust-boundary":  "trust_boundaries",
		"actor":           "actors",
		"component":       "components",
		"data-store":      "data_stores",
		"data-set":        "data_sets",
		"data-flow":       "data_flows",
		"threat-persona":  "threat_personas",
		"threat":          "threats",
		"control":         "controls",
		"risk":            "risks",
	}

	collectionsWithSymbolicNames = []string{
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
	}
)

func riskLevelBand(score int) string {
	if score <= 2 {
		return "very_low"
	}
	if score <= 4 {
		return "low"
	}
	if score <= 9 {
		return "medium"
	}
	if score <= 12 {
		return "high"
	}
	if score <= 16 {
		return "very_high"
	}
	return "critical"
}

func normalizeTypeReference(ref string) string {
	ref = strings.TrimPrefix(ref, "#/$defs/")
	ref = strings.ReplaceAll(ref, "_", "-")
	return strings.ToLower(ref)
}

func article(name string) string {
	if len(name) > 0 && strings.ContainsRune("aeiou", rune(strings.ToLower(name)[0])) {
		return "an"
	}
	return "a"
}

type ValidationError struct {
	Location string
	Message  string
}

func collectSymbols(model map[string]any) (map[string]map[string]bool, []ValidationError) {
	symbols := make(map[string]map[string]bool)
	for _, col := range collectionsWithSymbolicNames {
		symbols[col] = make(map[string]bool)
	}
	var problems []ValidationError

	for _, col := range append(collectionsWithSymbolicNames, "trust_boundaries") {
		raw, ok := model[col]
		if !ok || raw == nil {
			continue
		}
		list, ok := raw.([]any)
		if !ok {
			problems = append(problems, ValidationError{Location: col, Message: "must be an array"})
			continue
		}
		for i, item := range list {
			loc := fmt.Sprintf("%s[%d]", col, i)
			entry, ok := item.(map[string]any)
			if !ok {
				problems = append(problems, ValidationError{Location: loc, Message: "entry must be an object"})
				continue
			}
			symRaw, hasSym := entry["symbolic_name"]
			if !hasSym || symRaw == nil {
				continue
			}
			name, ok := symRaw.(string)
			if !ok {
				problems = append(problems, ValidationError{Location: loc, Message: "symbolic_name must be a string"})
				continue
			}
			if symbols[col][name] {
				problems = append(problems, ValidationError{
					Location: loc,
					Message:  fmt.Sprintf("duplicate symbolic_name %q in %s; references to it are ambiguous", name, col),
				})
			}
			symbols[col][name] = true
		}
	}

	return symbols, problems
}

type IntegrityChecker struct {
	model      map[string]any
	symbols    map[string]map[string]bool
	allSymbols map[string]bool
	errors     []ValidationError
}

func newIntegrityChecker(model map[string]any) *IntegrityChecker {
	syms, errs := collectSymbols(model)
	all := make(map[string]bool)
	for _, set := range syms {
		for s := range set {
			all[s] = true
		}
	}
	return &IntegrityChecker{
		model:      model,
		symbols:    syms,
		allSymbols: all,
		errors:     errs,
	}
}

func (c *IntegrityChecker) resolveUntyped(names []any, path, field string) {
	for i, name := range names {
		loc := path
		if len(names) > 1 {
			loc = fmt.Sprintf("%s[%d]", path, i)
		}
		str, ok := name.(string)
		if !ok {
			c.errors = append(c.errors, ValidationError{Location: loc, Message: fmt.Sprintf("%s must be a string", field)})
		} else if !c.allSymbols[str] {
			c.errors = append(c.errors, ValidationError{Location: loc, Message: fmt.Sprintf("dangling reference: %q is not defined", str)})
		}
	}
}

func (c *IntegrityChecker) resolveBare(names []any, collection, pathPrefix, field string) {
	known := c.symbols[collection]
	for i, name := range names {
		loc := pathPrefix
		if len(names) > 1 {
			loc = fmt.Sprintf("%s[%d]", pathPrefix, i)
		}
		str, ok := name.(string)
		if !ok {
			c.errors = append(c.errors, ValidationError{Location: loc, Message: fmt.Sprintf("%s must be a string", field)})
		} else if !known[str] {
			c.errors = append(c.errors, ValidationError{Location: loc, Message: fmt.Sprintf("dangling reference: %q is not in %s", str, collection)})
		}
	}
}

func (c *IntegrityChecker) resolve(ref any, path string) {
	refMap, ok := ref.(map[string]any)
	if !ok {
		c.errors = append(c.errors, ValidationError{Location: path, Message: "reference must be an object"})
		return
	}
	objName, _ := refMap["object"].(string)
	rawType, _ := refMap["type"].(string)
	if objName == "" {
		c.errors = append(c.errors, ValidationError{Location: path, Message: "reference has no usable 'object' symbolic name"})
		return
	}
	if rawType == "" {
		c.errors = append(c.errors, ValidationError{Location: path, Message: fmt.Sprintf("reference %q has no 'type'", objName)})
		return
	}
	typeName := normalizeTypeReference(rawType)
	col, knownCol := typeReferenceToCollection[typeName]
	if !knownCol {
		var knownList []string
		for k := range typeReferenceToCollection {
			knownList = append(knownList, k)
		}
		sort.Strings(knownList)
		c.errors = append(c.errors, ValidationError{
			Location: path,
			Message:  fmt.Sprintf("type reference %q is not a known kind; expected one of %s", rawType, strings.Join(knownList, ", ")),
		})
		return
	}

	if c.symbols[col][objName] {
		return
	}

	var elsewhere []string
	for other, names := range c.symbols {
		if names[objName] {
			elsewhere = append(elsewhere, other)
		}
	}
	sort.Strings(elsewhere)
	if len(elsewhere) > 0 {
		c.errors = append(c.errors, ValidationError{
			Location: path,
			Message:  fmt.Sprintf("%q is defined as %s but referenced as %s %s", objName, strings.Join(elsewhere, ", "), article(typeName), typeName),
		})
	} else {
		c.errors = append(c.errors, ValidationError{
			Location: path,
			Message:  fmt.Sprintf("dangling reference: %q is not defined as %s %s", objName, article(typeName), typeName),
		})
	}
}

func (c *IntegrityChecker) getItems(col string) []any {
	raw, ok := c.model[col]
	if !ok {
		return nil
	}
	list, _ := raw.([]any)
	return list
}

func (c *IntegrityChecker) Run() []ValidationError {
	// 1. Trust boundaries
	for i, item := range c.getItems("trust_boundaries") {
		prefix := fmt.Sprintf("trust_boundaries[%d]", i)
		boundary, ok := item.(map[string]any)
		if !ok {
			c.errors = append(c.errors, ValidationError{Location: prefix, Message: "entry must be an object"})
			continue
		}
		tza, _ := boundary["trust_zone_a"].(string)
		tzb, _ := boundary["trust_zone_b"].(string)
		if tza != "" && tza == tzb {
			c.errors = append(c.errors, ValidationError{
				Location: prefix,
				Message:  "a trust boundary must separate two distinct zones, not bound a zone to itself",
			})
		}
		if tza != "" {
			c.resolveBare([]any{tza}, "trust_zones", prefix+".trust_zone_a", "trust_zone_a")
		}
		if tzb != "" {
			c.resolveBare([]any{tzb}, "trust_zones", prefix+".trust_zone_b", "trust_zone_b")
		}
	}

	// 2. Data flows
	for i, item := range c.getItems("data_flows") {
		prefix := fmt.Sprintf("data_flows[%d]", i)
		flow, ok := item.(map[string]any)
		if !ok {
			c.errors = append(c.errors, ValidationError{Location: prefix, Message: "entry must be an object"})
			continue
		}
		if src, ok := flow["source"]; ok {
			c.resolve(src, prefix+".source")
		}
		if dst, ok := flow["destination"]; ok {
			c.resolve(dst, prefix+".destination")
		}
	}

	// 3. Actors
	for i, item := range c.getItems("actors") {
		prefix := fmt.Sprintf("actors[%d]", i)
		actor, ok := item.(map[string]any)
		if ok && actor["trust_zone"] != nil {
			c.resolveBare([]any{actor["trust_zone"]}, "trust_zones", prefix+".trust_zone", "trust_zone")
		}
	}

	// 4. Components
	parentOf := make(map[string]string)
	for i, item := range c.getItems("components") {
		prefix := fmt.Sprintf("components[%d]", i)
		comp, ok := item.(map[string]any)
		if !ok {
			continue
		}
		if comp["trust_zone"] != nil {
			c.resolveBare([]any{comp["trust_zone"]}, "trust_zones", prefix+".trust_zone", "trust_zone")
		}
		name, _ := comp["symbolic_name"].(string)
		parent, _ := comp["parent_component"].(string)
		if comp["parent_component"] != nil {
			if parent == name {
				c.errors = append(c.errors, ValidationError{
					Location: prefix + ".parent_component",
					Message:  "a component cannot be its own parent",
				})
			}
			c.resolveBare([]any{parent}, "components", prefix+".parent_component", "parent_component")
		}
		if name != "" && parent != "" {
			parentOf[name] = parent
		}
	}

	// Acyclic component hierarchy check
	for name := range parentOf {
		seen := []string{name}
		cursor := parentOf[name]
		for cursor != "" {
			if contains(seen, cursor) {
				c.errors = append(c.errors, ValidationError{
					Location: fmt.Sprintf("components[%s].parent_component", name),
					Message:  fmt.Sprintf("parent chain forms a cycle at %q", cursor),
				})
				break
			}
			seen = append(seen, cursor)
			cursor = parentOf[cursor]
		}
	}

	// 5. Data stores
	for i, item := range c.getItems("data_stores") {
		prefix := fmt.Sprintf("data_stores[%d]", i)
		ds, ok := item.(map[string]any)
		if ok && ds["trust_zone"] != nil {
			c.resolveBare([]any{ds["trust_zone"]}, "trust_zones", prefix+".trust_zone", "trust_zone")
		}
	}

	// 6. Data sets
	for i, item := range c.getItems("data_sets") {
		prefix := fmt.Sprintf("data_sets[%d]", i)
		ds, ok := item.(map[string]any)
		if !ok {
			continue
		}
		placements, ok := ds["placements"].([]any)
		if !ok {
			c.errors = append(c.errors, ValidationError{Location: prefix + ".placements", Message: "must be an array"})
			continue
		}
		for pi, p := range placements {
			placement, ok := p.(map[string]any)
			if ok && placement["data_store"] != nil {
				c.resolveBare([]any{placement["data_store"]}, "data_stores", fmt.Sprintf("%s.placements[%d].data_store", prefix, pi), "data_store")
			}
		}
	}

	// 7. Assumptions
	for i, item := range c.getItems("assumptions") {
		asmp, ok := item.(map[string]any)
		if !ok {
			continue
		}
		if topics, ok := asmp["topics"].([]any); ok {
			c.resolveUntyped(topics, fmt.Sprintf("assumptions[%d].topics", i), "topics")
		}
	}

	// 8. Threats
	for i, item := range c.getItems("threats") {
		prefix := fmt.Sprintf("threats[%d]", i)
		threat, ok := item.(map[string]any)
		if !ok {
			continue
		}
		if threat["threat_persona"] != nil {
			c.resolveBare([]any{threat["threat_persona"]}, "threat_personas", prefix+".threat_persona", "threat_persona")
		}
		if comps, ok := threat["components_affected"].([]any); ok {
			c.resolveBare(comps, "components", prefix+".components_affected", "components_affected")
		}
	}

	// 9. Controls
	for i, item := range c.getItems("controls") {
		prefix := fmt.Sprintf("controls[%d]", i)
		ctrl, ok := item.(map[string]any)
		if !ok {
			continue
		}
		if threats, ok := ctrl["threats"].([]any); ok {
			c.resolveBare(threats, "threats", prefix+".threats", "threats")
		}
		if boundary, ok := ctrl["trust_boundary"].(map[string]any); ok {
			if tza := boundary["trust_zone_a"]; tza != nil {
				c.resolveBare([]any{tza}, "trust_zones", prefix+".trust_boundary.trust_zone_a", "trust_zone_a")
			}
			if tzb := boundary["trust_zone_b"]; tzb != nil {
				c.resolveBare([]any{tzb}, "trust_zones", prefix+".trust_boundary.trust_zone_b", "trust_zone_b")
			}
		}
	}

	// 10. Risks
	for i, item := range c.getItems("risks") {
		prefix := fmt.Sprintf("risks[%d]", i)
		risk, ok := item.(map[string]any)
		if !ok {
			continue
		}
		if threats, ok := risk["threats"].([]any); ok {
			c.resolveBare(threats, "threats", prefix+".threats", "threats")
		}
	}

	return c.errors
}

func validateRiskMatrix(model map[string]any) []ValidationError {
	var errors []ValidationError
	risks, ok := model["risks"].([]any)
	if !ok {
		return nil
	}
	for i, r := range risks {
		risk, ok := r.(map[string]any)
		if !ok {
			continue
		}
		prefix := fmt.Sprintf("risks[%d]", i)
		lhStr, _ := risk["likelihood"].(string)
		impStr, _ := risk["impact"].(string)
		scoreNum, hasScore := risk["score"].(float64)
		level, _ := risk["level"].(string)

		likelihood, hasLh := likelihoodValues[lhStr]
		impact, hasImp := impactValues[impStr]
		if !hasLh || !hasImp || !hasScore {
			continue
		}
		score := int(scoreNum)
		expectedScore := likelihood * impact
		if score != expectedScore {
			errors = append(errors, ValidationError{
				Location: prefix,
				Message:  fmt.Sprintf("score %d is inconsistent with likelihood %s x impact %s, which is %d", score, lhStr, impStr, expectedScore),
			})
		}
		expectedBand := riskLevelBand(score)
		if level != expectedBand {
			errors = append(errors, ValidationError{
				Location: prefix,
				Message:  fmt.Sprintf("level %q is inconsistent with score %d, which is %s", level, score, expectedBand),
			})
		}
	}
	return errors
}

func validateRiskRegister(models []map[string]any, registerPath string) []string {
	data, err := os.ReadFile(registerPath)
	if err != nil {
		return []string{fmt.Sprintf("RISKS.md could not be read: %v", err)}
	}
	lines := strings.Split(string(data), "\n")
	var tableRows []string
	for _, l := range lines {
		if strings.HasPrefix(strings.TrimSpace(l), "|") {
			tableRows = append(tableRows, l)
		}
	}

	var errors []string
	for _, model := range models {
		risks, ok := model["risks"].([]any)
		if !ok {
			continue
		}
		for _, r := range risks {
			risk, ok := r.(map[string]any)
			if !ok {
				continue
			}
			name, ok := risk["symbolic_name"].(string)
			if !ok || name == "" {
				continue
			}
			pattern := "`" + name + "`"
			occurrences := 0
			for _, row := range tableRows {
				occurrences += strings.Count(row, pattern)
			}
			if occurrences == 0 {
				errors = append(errors, fmt.Sprintf("RISKS.md does not list risk %q", name))
			} else if occurrences > 1 {
				errors = append(errors, fmt.Sprintf("RISKS.md lists risk %q %d times; expected exactly once", name, occurrences))
			}
		}
	}
	return errors
}

func contains(slice []string, val string) bool {
	for _, s := range slice {
		if s == val {
			return true
		}
	}
	return false
}

func main() {
	quiet := flag.Bool("quiet", false, "only print failures and the summary")
	schemaPath := flag.String("schema", "threat-model/schema/threat-model.schema.json", "path to OWASP JSON schema")
	modelDir := flag.String("dir", "threat-model", "directory containing threat model JSON files")
	registerPath := flag.String("risks", "threat-model/RISKS.md", "path to RISKS.md")
	flag.Parse()

	// Register custom date-time format if needed or let jsonschema use its built-in formats
	// The Python validator used a permissive regex for date-time:
	dateTimeRegex := regexp.MustCompile(`^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})?$`)
	jsonschema.Formats["date-time"] = func(v any) bool {
		str, ok := v.(string)
		if !ok {
			return true
		}
		return dateTimeRegex.MatchString(str)
	}

	absSchema, err := filepath.Abs(*schemaPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to resolve schema path %s: %v\n", *schemaPath, err)
		os.Exit(2)
	}
	compiler := jsonschema.NewCompiler()
	compiler.Draft = jsonschema.Draft2020
	compiler.AssertFormat = true
	schemaURL := "file://" + filepath.ToSlash(absSchema)
	schema, err := compiler.Compile(schemaURL)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to compile schema %s: %v\n", *schemaPath, err)
		os.Exit(2)
	}

	var modelFiles []string
	err = filepath.Walk(*modelDir, func(path string, info os.FileInfo, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if !info.IsDir() && strings.HasSuffix(info.Name(), ".threat-model.json") {
			modelFiles = append(modelFiles, path)
		}
		return nil
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to search models in %s: %v\n", *modelDir, err)
		os.Exit(1)
	}
	sort.Strings(modelFiles)

	if len(modelFiles) == 0 {
		fmt.Fprintf(os.Stderr, "no *.threat-model.json files found under %s\n", *modelDir)
		os.Exit(1)
	}

	var loadedModels []map[string]any
	failed := 0

	for _, file := range modelFiles {
		bytes, readErr := os.ReadFile(file)
		if readErr != nil {
			failed++
			fmt.Printf("FAIL %s\n  could not read file: %v\n", file, readErr)
			continue
		}

		var rawDoc any
		if jsonErr := json.Unmarshal(bytes, &rawDoc); jsonErr != nil {
			failed++
			fmt.Printf("FAIL %s\n  invalid JSON: %v\n", file, jsonErr)
			continue
		}

		modelMap, isMap := rawDoc.(map[string]any)
		if !isMap {
			failed++
			fmt.Printf("FAIL %s\n  root is not a JSON object\n", file)
			continue
		}
		loadedModels = append(loadedModels, modelMap)

		var schemaErrors []string
		if valErr := schema.Validate(rawDoc); valErr != nil {
			if rootErr, ok := valErr.(*jsonschema.ValidationError); ok {
				var collectSchemaErrs func(*jsonschema.ValidationError)
				collectSchemaErrs = func(e *jsonschema.ValidationError) {
					if len(e.Causes) == 0 {
						loc := e.InstanceLocation
						if loc == "" {
							loc = "<root>"
						}
						schemaErrors = append(schemaErrors, fmt.Sprintf("%s: %s", loc, e.Message))
					} else {
						for _, cause := range e.Causes {
							collectSchemaErrs(cause)
						}
					}
				}
				collectSchemaErrs(rootErr)
			} else {
				schemaErrors = append(schemaErrors, valErr.Error())
			}
		}

		checker := newIntegrityChecker(modelMap)
		integrityErrors := append(checker.Run(), validateRiskMatrix(modelMap)...)

		if len(schemaErrors) > 0 || len(integrityErrors) > 0 {
			failed++
			fmt.Printf("FAIL %s\n", file)
			for _, se := range schemaErrors {
				fmt.Printf("  schema: %s\n", se)
			}
			for _, ie := range integrityErrors {
				fmt.Printf("  refs:   %s: %s\n", ie.Location, ie.Message)
			}
		} else if !*quiet {
			fmt.Printf("PASS %s\n", file)
		}
	}

	regErrors := validateRiskRegister(loadedModels, *registerPath)
	if len(regErrors) > 0 {
		failed += len(regErrors)
		fmt.Printf("FAIL %s\n", *registerPath)
		for _, re := range regErrors {
			fmt.Printf("  refs:   %s\n", re)
		}
	}

	total := len(modelFiles)
	if failed > 0 {
		fmt.Printf("\n%d of %d threat model(s) failed validation.\n", failed, total)
		os.Exit(1)
	}

	fmt.Printf("\nAll %d threat model(s) passed schema and referential-integrity validation.\n", total)
}
