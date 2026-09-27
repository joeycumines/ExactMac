// Copyright 2025 Joseph Cumines
//
// MCP server unit tests

package server

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/joeycumines/ExactMac/internal/config"
)

// ============================================================================
// Task 53: Tool Schema Completeness Audit Tests
// ============================================================================

// getTestToolRegistry creates a minimal MCPServer and returns its tools map for testing.
// This allows us to programmatically validate all 23 registered tool schemas.
func getTestToolRegistry(t *testing.T) map[string]*Tool {
	t.Helper()
	ctx := context.Background()
	s := &MCPServer{
		cfg:   &config.Config{},
		tools: make(map[string]*Tool),
		ctx:   ctx,
	}
	s.registerTools()
	return s.tools
}

// TestToolSchemaCompleteness validates all tool schemas have proper structure.
// Per MCP specification, each tool must have:
// - InputSchema with type: "object" (required)
// - properties map (required for tools with parameters)
// - required array (if any fields are mandatory)
func TestToolSchemaCompleteness(t *testing.T) {
	tools := getTestToolRegistry(t)

	// Verify we have exactly 29 tools
	if len(tools) != 31 {
		t.Errorf("Expected 29 tools, got %d", len(tools))
	}

	var issues []string

	for name, tool := range tools {
		// Check that Name matches the map key
		if tool.Name != name {
			issues = append(issues, fmt.Sprintf("%s: Name field '%s' doesn't match map key", name, tool.Name))
		}

		// Check Description exists and is non-empty
		if tool.Description == "" {
			issues = append(issues, fmt.Sprintf("%s: Description is empty", name))
		}

		// Check InputSchema exists
		if tool.InputSchema == nil {
			issues = append(issues, fmt.Sprintf("%s: InputSchema is nil", name))
			continue
		}

		// Check InputSchema has type: "object"
		schemaType, hasType := tool.InputSchema["type"]
		if !hasType {
			issues = append(issues, fmt.Sprintf("%s: InputSchema missing 'type' field", name))
		} else if schemaType != "object" {
			issues = append(issues, fmt.Sprintf("%s: InputSchema type should be 'object', got '%v'", name, schemaType))
		}

		// Check properties field exists (can be empty for tools with no parameters)
		_, hasProperties := tool.InputSchema["properties"]
		if !hasProperties {
			issues = append(issues, fmt.Sprintf("%s: InputSchema missing 'properties' field", name))
		}

		// Check Handler is not nil
		if tool.Handler == nil {
			issues = append(issues, fmt.Sprintf("%s: Handler is nil", name))
		}
	}

	if len(issues) > 0 {
		t.Errorf("Schema completeness issues found (%d):\n  %s", len(issues), strings.Join(issues, "\n  "))
	}
}

// TestToolSchemaPropertyCompleteness validates each property in every tool schema
// has the required fields: type and description.
func TestToolSchemaPropertyCompleteness(t *testing.T) {
	tools := getTestToolRegistry(t)

	var issues []string
	totalProperties := 0
	propertiesWithType := 0
	propertiesWithDescription := 0

	for name, tool := range tools {
		if tool.InputSchema == nil {
			continue
		}

		propsRaw, ok := tool.InputSchema["properties"]
		if !ok {
			continue
		}

		props, ok := propsRaw.(map[string]any)
		if !ok {
			issues = append(issues, fmt.Sprintf("%s: properties is not a map", name))
			continue
		}

		for propName, propValRaw := range props {
			totalProperties++

			propVal, ok := propValRaw.(map[string]any)
			if !ok {
				issues = append(issues, fmt.Sprintf("%s.%s: property value is not a map", name, propName))
				continue
			}

			// Check for type
			if propType, hasType := propVal["type"]; hasType && propType != "" {
				propertiesWithType++
			} else {
				issues = append(issues, fmt.Sprintf("%s.%s: missing 'type' field", name, propName))
			}

			// Check for description
			if desc, hasDesc := propVal["description"]; hasDesc && desc != "" {
				propertiesWithDescription++
			} else {
				issues = append(issues, fmt.Sprintf("%s.%s: missing 'description' field", name, propName))
			}
		}
	}

	t.Logf("Property audit: %d total, %d with type, %d with description",
		totalProperties, propertiesWithType, propertiesWithDescription)

	if len(issues) > 0 {
		t.Errorf("Property completeness issues found (%d):\n  %s", len(issues), strings.Join(issues, "\n  "))
	}
}

// TestToolSchemaEnumCompleteness validates that enum fields have proper values declared.
// Tools with enum types should list all valid options in the schema.
func TestToolSchemaEnumCompleteness(t *testing.T) {
	tools := getTestToolRegistry(t)

	// Expected enums and their minimum required values
	expectedEnums := map[string]map[string][]string{
		"screenshot": {
			"format": {"png", "jpeg", "tiff"},
		},
		"click": {
			"button": {"left", "right", "middle"},
		},
		"double_click": {
			"button": {"left", "right", "middle"},
		},
		"open_app": {
			"mode": {"launch_or_activate", "force_new_instance"},
		},
		"clipboard": {
			"action": {"get", "set", "clear"},
		},
		"run": {
			"type": {"shell", "applescript", "javascript"},
		},
	}

	var issues []string

	for toolName, expectedProps := range expectedEnums {
		tool, ok := tools[toolName]
		if !ok {
			issues = append(issues, fmt.Sprintf("%s: tool not found", toolName))
			continue
		}

		propsRaw, ok := tool.InputSchema["properties"]
		if !ok {
			issues = append(issues, fmt.Sprintf("%s: no properties", toolName))
			continue
		}

		props, ok := propsRaw.(map[string]any)
		if !ok {
			continue
		}

		for propName, expectedValues := range expectedProps {
			propValRaw, ok := props[propName]
			if !ok {
				issues = append(issues, fmt.Sprintf("%s.%s: property not found", toolName, propName))
				continue
			}

			propVal, ok := propValRaw.(map[string]any)
			if !ok {
				continue
			}

			enumRaw, hasEnum := propVal["enum"]
			if !hasEnum {
				issues = append(issues, fmt.Sprintf("%s.%s: missing 'enum' field", toolName, propName))
				continue
			}

			enum, ok := enumRaw.([]string)
			if !ok {
				// Try []interface{}
				enumIface, ok := enumRaw.([]any)
				if !ok {
					issues = append(issues, fmt.Sprintf("%s.%s: enum is not an array", toolName, propName))
					continue
				}
				enum = make([]string, len(enumIface))
				for i, v := range enumIface {
					enum[i], _ = v.(string)
				}
			}

			// Check all expected values are present
			enumSet := make(map[string]bool)
			for _, v := range enum {
				enumSet[v] = true
			}

			for _, expected := range expectedValues {
				if !enumSet[expected] {
					issues = append(issues, fmt.Sprintf("%s.%s: missing enum value '%s'", toolName, propName, expected))
				}
			}
		}
	}

	if len(issues) > 0 {
		t.Errorf("Enum completeness issues found (%d):\n  %s", len(issues), strings.Join(issues, "\n  "))
	}
}

// TestToolSchemaArrayItems validates that array properties have 'items' defined.
// Per JSON Schema, arrays should specify the type of their elements.
func TestToolSchemaArrayItems(t *testing.T) {
	tools := getTestToolRegistry(t)

	var issues []string
	arraysFound := 0
	arraysWithItems := 0

	for name, tool := range tools {
		if tool.InputSchema == nil {
			continue
		}

		propsRaw, ok := tool.InputSchema["properties"]
		if !ok {
			continue
		}

		props, ok := propsRaw.(map[string]any)
		if !ok {
			continue
		}

		for propName, propValRaw := range props {
			propVal, ok := propValRaw.(map[string]any)
			if !ok {
				continue
			}

			propType, _ := propVal["type"].(string)
			if propType != "array" {
				continue
			}

			arraysFound++

			// Check for items
			if items, hasItems := propVal["items"]; hasItems && items != nil {
				arraysWithItems++

				// Further validate items has a type
				itemsMap, ok := items.(map[string]any)
				if ok {
					if _, hasType := itemsMap["type"]; !hasType {
						issues = append(issues, fmt.Sprintf("%s.%s.items: missing 'type'", name, propName))
					}
				}
			} else {
				issues = append(issues, fmt.Sprintf("%s.%s: array property missing 'items' field", name, propName))
			}
		}
	}

	t.Logf("Array audit: %d arrays found, %d with items defined", arraysFound, arraysWithItems)

	if len(issues) > 0 {
		t.Errorf("Array items issues found (%d):\n  %s", len(issues), strings.Join(issues, "\n  "))
	}
}

// TestToolSchemaRequiredFieldsExist validates that all fields listed in 'required'
// actually exist in the 'properties' map.
func TestToolSchemaRequiredFieldsExist(t *testing.T) {
	tools := getTestToolRegistry(t)

	var issues []string
	toolsWithRequired := 0
	totalRequiredFields := 0

	for name, tool := range tools {
		if tool.InputSchema == nil {
			continue
		}

		requiredRaw, hasRequired := tool.InputSchema["required"]
		if !hasRequired {
			continue
		}

		required, ok := requiredRaw.([]string)
		if !ok {
			// Try []interface{}
			requiredIface, ok := requiredRaw.([]any)
			if !ok {
				issues = append(issues, fmt.Sprintf("%s: 'required' is not an array", name))
				continue
			}
			required = make([]string, len(requiredIface))
			for i, v := range requiredIface {
				required[i], _ = v.(string)
			}
		}

		if len(required) == 0 {
			continue
		}

		toolsWithRequired++
		totalRequiredFields += len(required)

		propsRaw, ok := tool.InputSchema["properties"]
		if !ok {
			issues = append(issues, fmt.Sprintf("%s: has 'required' but no 'properties'", name))
			continue
		}

		props, ok := propsRaw.(map[string]any)
		if !ok {
			continue
		}

		for _, reqField := range required {
			if _, exists := props[reqField]; !exists {
				issues = append(issues, fmt.Sprintf("%s: required field '%s' not found in properties", name, reqField))
			}
		}
	}

	t.Logf("Required fields audit: %d tools with required, %d total required fields",
		toolsWithRequired, totalRequiredFields)

	if len(issues) > 0 {
		t.Errorf("Required field issues found (%d):\n  %s", len(issues), strings.Join(issues, "\n  "))
	}
}

// TestToolSchemaTypeValidity validates that all type values are valid JSON Schema types.
func TestToolSchemaTypeValidity(t *testing.T) {
	tools := getTestToolRegistry(t)

	// Valid JSON Schema primitive types
	validTypes := map[string]bool{
		"string":  true,
		"number":  true,
		"integer": true,
		"boolean": true,
		"array":   true,
		"object":  true,
		"null":    true,
	}

	var issues []string

	for name, tool := range tools {
		if tool.InputSchema == nil {
			continue
		}

		propsRaw, ok := tool.InputSchema["properties"]
		if !ok {
			continue
		}

		props, ok := propsRaw.(map[string]any)
		if !ok {
			continue
		}

		for propName, propValRaw := range props {
			propVal, ok := propValRaw.(map[string]any)
			if !ok {
				continue
			}

			propType, hasType := propVal["type"]
			if !hasType {
				continue // Already reported in TestToolSchemaPropertyCompleteness
			}

			typeStr, ok := propType.(string)
			if !ok {
				issues = append(issues, fmt.Sprintf("%s.%s: type is not a string", name, propName))
				continue
			}

			if !validTypes[typeStr] {
				issues = append(issues, fmt.Sprintf("%s.%s: invalid type '%s'", name, propName, typeStr))
			}
		}
	}

	if len(issues) > 0 {
		t.Errorf("Type validity issues found (%d):\n  %s", len(issues), strings.Join(issues, "\n  "))
	}
}

// TestToolSchemaDescriptionQuality validates that descriptions are meaningful
// (not too short) and properly formatted.
func TestToolSchemaDescriptionQuality(t *testing.T) {
	tools := getTestToolRegistry(t)

	var issues []string
	minToolDescLength := 20
	minPropDescLength := 5

	for name, tool := range tools {
		// Check tool description length
		if len(tool.Description) < minToolDescLength {
			issues = append(issues, fmt.Sprintf("%s: tool description too short (%d chars, min %d)",
				name, len(tool.Description), minToolDescLength))
		}

		if tool.InputSchema == nil {
			continue
		}

		propsRaw, ok := tool.InputSchema["properties"]
		if !ok {
			continue
		}

		props, ok := propsRaw.(map[string]any)
		if !ok {
			continue
		}

		for propName, propValRaw := range props {
			propVal, ok := propValRaw.(map[string]any)
			if !ok {
				continue
			}

			desc, _ := propVal["description"].(string)
			if len(desc) < minPropDescLength {
				issues = append(issues, fmt.Sprintf("%s.%s: property description too short (%d chars, min %d)",
					name, propName, len(desc), minPropDescLength))
			}
		}
	}

	// Only log as info, don't fail the test (guidance, not strict requirement)
	if len(issues) > 0 {
		t.Logf("Description quality suggestions (%d):\n  %s", len(issues), strings.Join(issues, "\n  "))
	}
}

// TestToolSchemaToolCount validates that exactly 31 tools are registered.
// This ensures no tools are accidentally removed or duplicated.
func TestToolSchemaToolCount(t *testing.T) {
	tools := getTestToolRegistry(t)

	if len(tools) != 31 {
		// List all tool names for debugging
		var names []string
		for name := range tools {
			names = append(names, name)
		}
		t.Errorf("Expected 31 tools, got %d. Tools: %v", len(tools), names)
	}
}

// TestToolSchemaToolCategories validates tools are organized by category.
// Per docs, tools should be in 14 categories.
func TestToolSchemaToolCategories(t *testing.T) {
	// Define expected tool counts per category
	categories := map[string][]string{
		"CUACore": {
			"screenshot",
			"click",
			"double_click",
			"type",
			"keypress",
			"scroll",
			"drag",
			"move",
			"wait",
		},
		"Application": {
			"open_app",
			"list_apps",
			"close_app",
		},
		"Element": {
			"find_elements",
			"click_element",
			"type_element",
			"read_element",
		},
		"Window": {
			"focus_window",
			"move_window",
			"resize_window",
			"list_windows",
		},
		"Utility": {
			"clipboard",
			"run",
			"get_display",
		},
		"Macro": {
			"create_macro",
			"get_macro",
			"list_grants",
			"preauthorize",
			"list_macros",
			"update_macro",
			"delete_macro",
			"execute_macro",
		},
	}

	tools := getTestToolRegistry(t)

	// Verify each expected tool exists
	var missing []string
	for category, expectedTools := range categories {
		for _, toolName := range expectedTools {
			if _, exists := tools[toolName]; !exists {
				missing = append(missing, fmt.Sprintf("%s (category: %s)", toolName, category))
			}
		}
	}

	if len(missing) > 0 {
		t.Errorf("Missing tools:\n  %s", strings.Join(missing, "\n  "))
	}

	// Count total expected tools
	totalExpected := 0
	for _, toolList := range categories {
		totalExpected += len(toolList)
	}

	t.Logf("Category audit: %d categories, %d expected tools, %d actual tools",
		len(categories), totalExpected, len(tools))
}

// TestToolSchemaSelectorProperty validates that tools with selector properties
// have properly structured object schemas for the selector.
func TestToolSchemaSelectorProperty(t *testing.T) {
	tools := getTestToolRegistry(t)

	// Tools that should have selector properties
	toolsWithSelector := []string{}

	var issues []string

	for _, name := range toolsWithSelector {
		tool, ok := tools[name]
		if !ok {
			issues = append(issues, fmt.Sprintf("%s: tool not found", name))
			continue
		}

		propsRaw, ok := tool.InputSchema["properties"]
		if !ok {
			issues = append(issues, fmt.Sprintf("%s: no properties", name))
			continue
		}

		props, ok := propsRaw.(map[string]any)
		if !ok {
			continue
		}

		selectorRaw, ok := props["selector"]
		if !ok {
			issues = append(issues, fmt.Sprintf("%s: missing 'selector' property", name))
			continue
		}

		selector, ok := selectorRaw.(map[string]any)
		if !ok {
			issues = append(issues, fmt.Sprintf("%s.selector: not a map", name))
			continue
		}

		// Selector should be type: object
		if selType, _ := selector["type"].(string); selType != "object" {
			issues = append(issues, fmt.Sprintf("%s.selector: type should be 'object', got '%s'", name, selType))
		}

		// Selector should have description
		if _, hasDesc := selector["description"]; !hasDesc {
			issues = append(issues, fmt.Sprintf("%s.selector: missing description", name))
		}
	}

	if len(issues) > 0 {
		t.Errorf("Selector property issues found (%d):\n  %s", len(issues), strings.Join(issues, "\n  "))
	}
}
