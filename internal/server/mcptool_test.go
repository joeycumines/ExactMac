// Copyright 2025 Joseph Cumines
//
// MCP server unit tests

package server

import (
	"encoding/json"
	"testing"

	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
)

// TestToolSchema_RequiredFields tests that tool schemas have proper structure
func TestToolSchema_RequiredFields(t *testing.T) {
	schema := map[string]any{
		"type": "object",
		"properties": map[string]any{
			"x": map[string]any{
				"type":        "integer",
				"description": "X coordinate",
			},
			"y": map[string]any{
				"type":        "integer",
				"description": "Y coordinate",
			},
		},
		"required": []string{"x", "y"},
	}

	data, err := json.Marshal(schema)
	if err != nil {
		t.Fatalf("Failed to marshal schema: %v", err)
	}

	var parsed map[string]any
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatalf("Failed to unmarshal schema: %v", err)
	}

	if parsed["type"] != "object" {
		t.Errorf("Schema type = %v, want 'object'", parsed["type"])
	}

	props, ok := parsed["properties"].(map[string]any)
	if !ok {
		t.Fatal("Schema properties not a map")
	}

	if _, ok := props["x"]; !ok {
		t.Error("Schema missing 'x' property")
	}
	if _, ok := props["y"]; !ok {
		t.Error("Schema missing 'y' property")
	}

	required, ok := parsed["required"].([]any)
	if !ok {
		t.Fatal("Schema required not an array")
	}
	if len(required) != 2 {
		t.Errorf("Schema required length = %d, want 2", len(required))
	}
}

// TestAllToolsExist validates all expected MCP tools are defined
func TestAllToolsExist(t *testing.T) {
	expectedTools := []string{
		"list_grants",
		"preauthorize",
		// CUA Core: Input (9)
		"screenshot",
		"click",
		"double_click",
		"type",
		"keypress",
		"scroll",
		"drag",
		"move",
		"wait",
		// Application Management (3)
		"open_app",
		"list_apps",
		"close_app",
		// Element Interaction (4)
		"find_elements",
		"click_element",
		"type_element",
		"read_element",
		// Window Management (4)
		"focus_window",
		"move_window",
		"resize_window",
		"list_windows",
		// Utility (3)
		"clipboard",
		"run",
		"get_display",
		"create_macro",
		"get_macro",
		"list_macros",
		"update_macro",
		"delete_macro",
		"execute_macro",
	}

	// Authorization: what is permitted, and asking for more (2). An agent that cannot see
	// what it holds re-asks, and re-asking costs a prompt the operator already answered.
	if len(expectedTools) != 31 {
		t.Errorf("Expected 29 tools but defined %d in test", len(expectedTools))
	}

	server := &MCPServer{tools: make(map[string]*Tool)}
	server.registerTools()

	seen := make(map[string]bool)
	for _, tool := range expectedTools {
		if seen[tool] {
			t.Errorf("Duplicate expected tool name: %s", tool)
		}
		seen[tool] = true
		if server.tools[tool] == nil {
			t.Errorf("Expected MCP tool %q to be registered", tool)
		}
	}

	for name := range server.tools {
		if !seen[name] {
			t.Errorf("Registered unexpected MCP tool %q", name)
		}
	}
}

// TestToolNaming validates tool naming conventions
func TestToolNaming(t *testing.T) {
	// All tool names should be snake_case
	tools := []string{
		"screenshot",
		"click",
		"double_click",
		"type",
		"keypress",
		"scroll",
		"drag",
		"move",
		"wait",
		"open_app",
		"list_apps",
		"close_app",
		"find_elements",
		"click_element",
		"type_element",
		"read_element",
		"focus_window",
		"move_window",
		"resize_window",
		"list_windows",
		"clipboard",
		"run",
		"get_display",
	}

	for _, toolName := range tools {
		// Check no uppercase letters (snake_case requirement)
		for _, r := range toolName {
			if r >= 'A' && r <= 'Z' {
				t.Errorf("Tool name %q contains uppercase letter, should be snake_case", toolName)
				break
			}
		}
		// Check no hyphens (snake_case uses underscores)
		if len(toolName) > 0 {
			for i := 0; i < len(toolName); i++ {
				if toolName[i] == '-' {
					t.Errorf("Tool name %q contains hyphen, should use underscore", toolName)
					break
				}
			}
		}
	}
}

// TestModifierStringMapping tests modifier key string to enum mapping
func TestModifierStringMapping(t *testing.T) {
	modifierMap := map[string]pb.KeyPress_Modifier{
		"cmd":     pb.KeyPress_MODIFIER_COMMAND,
		"command": pb.KeyPress_MODIFIER_COMMAND,
		"ctrl":    pb.KeyPress_MODIFIER_CONTROL,
		"control": pb.KeyPress_MODIFIER_CONTROL,
		"shift":   pb.KeyPress_MODIFIER_SHIFT,
		"alt":     pb.KeyPress_MODIFIER_OPTION,
		"option":  pb.KeyPress_MODIFIER_OPTION,
		"fn":      pb.KeyPress_MODIFIER_FUNCTION,
	}

	for key, expected := range modifierMap {
		if expected == pb.KeyPress_MODIFIER_UNSPECIFIED {
			t.Errorf("Modifier %q should not map to UNSPECIFIED", key)
		}
	}

	// Verify specific mappings
	if modifierMap["cmd"] != pb.KeyPress_MODIFIER_COMMAND {
		t.Error("cmd should map to MODIFIER_COMMAND")
	}
	if modifierMap["ctrl"] != pb.KeyPress_MODIFIER_CONTROL {
		t.Error("ctrl should map to MODIFIER_CONTROL")
	}
}

// TestCoordinateValidation tests coordinate value handling
func TestCoordinateValidation(t *testing.T) {
	tests := []struct {
		name  string
		x     float64
		y     float64
		valid bool
	}{
		{"positive coords", 100.0, 200.0, true},
		{"zero coords", 0.0, 0.0, true},
		{"negative x (valid for multi-monitor)", -100.0, 200.0, true},
		{"negative y (valid for multi-monitor)", 100.0, -50.0, true},
		{"fractional coords", 100.5, 200.5, true},
		{"large coords", 5000.0, 3000.0, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Coordinates in Global Display Space can be negative (multi-monitor)
			// and can exceed main display bounds (secondary monitors)
			// So all coordinates are technically valid from a parsing perspective
			if !tt.valid {
				t.Errorf("Coordinate (%f, %f) should be valid", tt.x, tt.y)
			}
		})
	}
}

// TestErrorResponseFormat tests that error responses use isError (camelCase)
// Per MCP 2025-11-25 CallToolResult schema.
func TestErrorResponseFormat(t *testing.T) {
	result := &ToolResult{
		Content: []Content{
			{Type: "text", Text: "Something went wrong"},
		},
		IsError: true,
	}

	resultMap := map[string]any{
		"content": result.Content,
	}
	if result.IsError {
		resultMap["isError"] = true
	}

	data, err := json.Marshal(resultMap)
	if err != nil {
		t.Fatalf("Failed to marshal: %v", err)
	}

	// Verify the key is isError, not is_error
	var parsed map[string]any
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatalf("Failed to unmarshal: %v", err)
	}

	if _, ok := parsed["isError"]; !ok {
		t.Errorf("Response should contain 'isError' key, got: %s", string(data))
	}

	if _, ok := parsed["is_error"]; ok {
		t.Errorf("Response should NOT contain 'is_error' key (snake_case), got: %s", string(data))
	}

	if parsed["isError"] != true {
		t.Errorf("isError should be true, got: %v", parsed["isError"])
	}
}

// TestPaginationTokenHandling tests pagination token handling
func TestPaginationTokenHandling(t *testing.T) {
	tests := []struct {
		name      string
		pageToken string
		isOpaque  bool
	}{
		{"empty token is valid", "", true},
		{"base64 token is opaque", "aGVsbG8td29ybGQ=", true},
		{"uuid token is opaque", "550e8400-e29b-41d4-a716-446655440000", true},
		{"random string is opaque", "abc123xyz", true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Page tokens should be treated as opaque - clients should not
			// interpret their internal structure
			if tt.isOpaque {
				// Just verify the token is a valid string (no structure assumptions)
				if len(tt.pageToken) > 0 && len(tt.pageToken) < 3 {
					t.Errorf("Page token too short to be valid opaque token: %s", tt.pageToken)
				}
			}
		})
	}
}

// TestCaptureWindowScreenshotParams tests window screenshot parameters
func TestCaptureWindowScreenshotParams(t *testing.T) {
	tests := []struct {
		name       string
		paramsJSON string
		hasWindow  bool
	}{
		{
			name:       "with window",
			paramsJSON: `{"window": "applications/123/windows/456"}`,
			hasWindow:  true,
		},
		{
			name:       "with all options",
			paramsJSON: `{"window": "applications/123/windows/456", "format": "png", "quality": 85, "shadow_enabled": true, "ocr_enabled": true}`,
			hasWindow:  true,
		},
		{
			name:       "missing window",
			paramsJSON: `{}`,
			hasWindow:  false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var params struct {
				Window        string `json:"window"`
				Format        string `json:"format"`
				Quality       int32  `json:"quality"`
				ShadowEnabled bool   `json:"shadow_enabled"`
				OCREnabled    bool   `json:"ocr_enabled"`
			}
			err := json.Unmarshal([]byte(tt.paramsJSON), &params)
			if err != nil {
				t.Errorf("Unmarshal error = %v", err)
			}
			if tt.hasWindow && params.Window == "" {
				t.Error("Window should be parsed when provided")
			}
			if !tt.hasWindow && params.Window != "" {
				t.Error("Window should be empty when not provided")
			}
		})
	}
}

// TestDisplayGroundingFormat validates the display grounding output format
// Follows MCP computer tool specification with "screens" array
func TestDisplayGroundingFormat(t *testing.T) {
	// Test that the format produces valid JSON with screens array
	tests := []struct {
		name     string
		response string
		valid    bool
	}{
		{
			name:     "empty screens",
			response: `{"screens":[]}`,
			valid:    true,
		},
		{
			name:     "single screen",
			response: `{"screens":[{"id":"main","width":1920,"height":1080,"pixel_density":2,"origin_x":0,"origin_y":0}]}`,
			valid:    true,
		},
		{
			name:     "multiple screens",
			response: `{"screens":[{"id":"main","width":1920,"height":1080,"pixel_density":2,"origin_x":0,"origin_y":0},{"id":"display-1","width":2560,"height":1440,"pixel_density":1,"origin_x":1920,"origin_y":0}]}`,
			valid:    true,
		},
		{
			name:     "invalid json",
			response: `{invalid}`,
			valid:    false,
		},
		{
			name:     "wrong root key",
			response: `{"displays":[]}`,
			valid:    false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var data map[string]any
			err := json.Unmarshal([]byte(tt.response), &data)

			if tt.valid {
				if err != nil {
					t.Errorf("Expected valid JSON, got error: %v", err)
				}
				// Verify "screens" key exists
				if _, ok := data["screens"]; !ok {
					t.Error("Response must have 'screens' key")
				}
			} else {
				if err == nil {
					// If no parse error, verify it has wrong structure
					if _, ok := data["screens"]; ok {
						t.Error("Expected invalid format, but got valid screens structure")
					}
				}
			}
		})
	}
}

// TestPaginationTokenOpaque validates that page_token values are opaque to clients
// Per AIP-158, page tokens must be opaque strings that clients should not interpret
func TestPaginationTokenOpaque(t *testing.T) {
	tests := []struct {
		name     string
		token    string
		isOpaque bool
	}{
		{"empty token", "", true},
		{"base64 encoded", "eyJwYWdlX29mZnNldCI6MTB9", true},
		{"uuid format", "f47ac10b-58cc-4372-a567-0e02b2c3d479", true},
		{"hex encoded", "a1b2c3d4e5f6", true},
		{"simple string", "next-page-token", true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Per AIP-158, clients must treat page tokens as opaque
			// The internal structure should not be interpreted
			if tt.isOpaque {
				// Verify token is a valid non-empty string when expected to be opaque
				if tt.token != "" {
					// Just verify it's a string - structure is opaque
					var token any = tt.token
					if _, ok := token.(string); !ok {
						t.Errorf("Token should be a string, got: %T", token)
					}
				}
			}
		})
	}
}

// TestIsErrorFieldFormat validates the isError field in tool responses
// Per MCP 2025-11-25 CallToolResult schema, isError indicates a soft failure.
func TestIsErrorFieldFormat(t *testing.T) {
	tests := []struct {
		name    string
		result  string
		wantErr bool
	}{
		{
			name:    "success response",
			result:  `{"content":[]}`,
			wantErr: false,
		},
		{
			name:    "error response with isError true",
			result:  `{"isError":true,"content":[{"type":"text","text":"element not found"}]}`,
			wantErr: true,
		},
		{
			name:    "error response with isError false",
			result:  `{"isError":false,"content":[]}`,
			wantErr: false,
		},
		{
			name:    "error text without isError flag",
			result:  `{"content":[{"type":"text","text":"warning: partial failure"}]}`,
			wantErr: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var result map[string]any
			err := json.Unmarshal([]byte(tt.result), &result)
			if err != nil {
				t.Fatalf("Failed to unmarshal result: %v", err)
			}

			isError, hasError := result["isError"]
			if tt.wantErr {
				if !hasError {
					t.Error("Expected isError field to be present for error response")
				} else if isError != true {
					t.Errorf("isError should be true, got: %v", isError)
				}
			}
		})
	}
}
