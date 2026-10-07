// Copyright 2025 Joseph Cumines
//
// Production MCP tool registry and model-facing schemas.

package server

const (
	cuaOpaqueInputTargetIDPattern  = `([A-Za-z0-9._~]|[A-Za-z0-9._~-]{2,128})`
	cuaDisplayInputTargetIDPattern = `([1-9][0-9]{0,8}|[1-3][0-9]{9}|4[01][0-9]{8}|42[0-8][0-9]{7}|429[0-3][0-9]{6}|4294[0-8][0-9]{5}|42949[0-5][0-9]{4}|429496[0-6][0-9]{3}|4294967[0-1][0-9]{2}|42949672[0-8][0-9]|429496729[0-5])`
)

// registerTools initializes all MCP tool handlers for the server.
// This registers 29 CUA-aligned tools across categories: core CUA (9),
// application management (3), element interaction (4), window management (4),
// clipboard (1), scripting (1), display (1), macro (6).
func (s *MCPServer) registerTools() {
	requestTimeoutSeconds := 30
	if requestTimeout, err := physicalInputRequestTimeout(s.cfg); err == nil {
		requestTimeoutSeconds = int(requestTimeout.Seconds())
	}
	pointerModifierKeys := []string{
		"ctrl", "control", "alt", "option", "meta", "command", "cmd", "shift", "fn", "function",
	}
	pointerModifierSchema := map[string]any{
		"type":        "array",
		"maxItems":    5,
		"items":       map[string]any{"type": "string", "enum": pointerModifierKeys},
		"description": "Distinct modifier keys held during the pointer action",
	}
	pointerInputTargetSchema := map[string]any{
		"type":      "string",
		"minLength": 1,
		"pattern": `^(desktop|applications/` +
			cuaOpaqueInputTargetIDPattern +
			`(/windows/` +
			cuaOpaqueInputTargetIDPattern +
			`)?|displays/` +
			cuaDisplayInputTargetIDPattern +
			`)$`,
		"description": "Exact input authority: desktop, applications/{application}, applications/{application}/windows/{window}, or displays/{display}",
	}
	keyboardInputTargetSchema := map[string]any{
		"type":      "string",
		"minLength": 1,
		"pattern": `^(desktop|applications/` +
			cuaOpaqueInputTargetIDPattern +
			`(/windows/` +
			cuaOpaqueInputTargetIDPattern +
			`)?)$`,
		"description": "Exact keyboard authority: desktop, applications/{application}, or applications/{application}/windows/{window}",
	}
	// macroActionSchema models the proto MacroAction oneof container as a closed
	// object schema. Each oneof branch (input, wait, conditional, loop, assignment,
	// method_call) wraps a sub-message whose own fields the Swift handler
	// validates via protojson unmarshal; those branch objects are therefore
	// declared additionalProperties:true (an explicit opt-out that
	// closeToolObjectSchemas respects) so valid action payloads pass the MCP
	// schema layer and reach protojson validation. description is a scalar.
	// Declaring the oneof field names keeps the action object genuinely closed:
	// a truly unknown action field (not one of the six branches) is rejected.
	macroActionBranch := map[string]any{"type": "object", "additionalProperties": true}
	macroActionSchema := map[string]any{
		"type": "object",
		"properties": map[string]any{
			"input":       macroActionBranch,
			"wait":        macroActionBranch,
			"conditional": macroActionBranch,
			"loop":        macroActionBranch,
			"assignment":  macroActionBranch,
			"method_call": macroActionBranch,
			"description": map[string]any{"type": "string"},
		},
	}
	s.tools = map[string]*Tool{
		// === CATEGORY 1: CORE CUA (9 tools — OpenAI CUA aligned) ===

		"screenshot": {
			Name:           "screenshot",
			Description:    "Capture screen and return base64-encoded image. If no window/region specified, captures full display.",
			MutationPolicy: mutationPolicyReadOnly,
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"display": map[string]any{
						"type":        "string",
						"pattern":     "^displays/[1-9][0-9]*$",
						"description": "Exact display resource name returned by get_display; omit for the main display or region-based inference",
					},
					"window": map[string]any{
						"type": "string",
						"pattern": `^applications/` + cuaOpaqueInputTargetIDPattern +
							`/windows/` + cuaOpaqueInputTargetIDPattern + `$`,
						"description": "Exact applications/{application}/windows/{window} resource name returned by list_windows",
					},
					"x":           map[string]any{"type": "number", "description": "Region origin X (Global Display Coordinates)"},
					"y":           map[string]any{"type": "number", "description": "Region origin Y (Global Display Coordinates)"},
					"width":       map[string]any{"type": "number", "description": "Region width in logical display points"},
					"height":      map[string]any{"type": "number", "description": "Region height in logical display points"},
					"format":      map[string]any{"type": "string", "description": "png (default), jpeg, tiff", "enum": []string{"png", "jpeg", "tiff"}},
					"quality":     map[string]any{"type": "integer", "minimum": 0, "maximum": 100, "description": "JPEG quality 1-100; zero selects 85 for JPEG and is required for PNG/TIFF"},
					"ocr_enabled": map[string]any{"type": "boolean", "description": "Include OCR text extraction"},
					"shadow_enabled": map[string]any{
						"type":        "boolean",
						"description": "Include the window shadow; valid only with window capture",
					},
				},
			},
			Handler: s.handleScreenshot,
		},
		"click": {
			Name:           "click",
			Description:    "Click at screen coordinates. Uses Global Display Coordinates (top-left origin).",
			MutationPolicy: mutationPolicyExclusive,
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"target":      pointerInputTargetSchema,
					"x":           map[string]any{"type": "number", "description": "X coordinate (Global Display Coordinates, top-left origin)"},
					"y":           map[string]any{"type": "number", "description": "Y coordinate (Global Display Coordinates, top-left origin)"},
					"button":      map[string]any{"type": "string", "description": "left (default), right, middle", "enum": []string{"left", "right", "middle"}, "default": "left"},
					"click_count": map[string]any{"type": "integer", "minimum": 1, "maximum": 10, "default": 1, "description": "1=single (default), 2=double, 3=triple, 4-10=N-tuple"},
					"keys":        pointerModifierSchema,
				},
				"required": []string{"target", "x", "y"},
			},
			Handler: s.cuaHandleClick,
		},
		"double_click": {
			Name:           "double_click",
			Description:    "Double-click at screen coordinates. Uses Global Display Coordinates (top-left origin).",
			MutationPolicy: mutationPolicyExclusive,
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"target": pointerInputTargetSchema,
					"x":      map[string]any{"type": "number", "description": "X coordinate"},
					"y":      map[string]any{"type": "number", "description": "Y coordinate"},
					"button": map[string]any{"type": "string", "description": "left (default), right, middle", "enum": []string{"left", "right", "middle"}, "default": "left"},
					"keys":   pointerModifierSchema,
				},
				"required": []string{"target", "x", "y"},
			},
			Handler: s.handleDoubleClick,
		},
		"type": {
			Name:           "type",
			Description:    "Type text as keyboard input into one exact target.",
			MutationPolicy: mutationPolicyExclusive,
			ValidateInput: func(arguments map[string]any) error {
				return validateCUATypeSchedule(s.cfg, arguments)
			},
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"text":       map[string]any{"type": "string", "minLength": 1, "description": physicalTypeDescription(requestTimeoutSeconds)},
					"char_delay": map[string]any{"type": "number", "minimum": 0, "maximum": 60, "description": "Exact delay between successive character down events in seconds"},
					"target":     keyboardInputTargetSchema,
				},
				"required": []string{"target", "text"},
			},
			Handler: s.handleType,
		},
		"keypress": {
			Name:           "keypress",
			Description:    "Press key combinations. CUA key names: ctrl, alt, meta, shift, enter, esc, backspace, arrowup, etc.",
			MutationPolicy: mutationPolicyExclusive,
			ValidateInput:  validateCUAKeypressInput,
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"target": keyboardInputTargetSchema,
					"keys": map[string]any{
						"type":        "array",
						"minItems":    1,
						"maxItems":    6,
						"items":       map[string]any{"type": "string", "minLength": 1},
						"description": "Exactly one primary key with distinct optional modifiers, e.g. [\"ctrl\",\"c\"] or [\"meta\",\"shift\",\"3\"]",
					},
					"hold_duration": physicalDurationSchema(
						requestTimeoutSeconds,
						3600,
						"Exact down-to-up hold duration in seconds",
					),
				},
				"required": []string{"target", "keys"},
			},
			Handler: s.handleKeypress,
		},
		"scroll": {
			Name:           "scroll",
			Description:    "Scroll at a screen position by delta amounts. Uses Global Display Coordinates (top-left origin).",
			MutationPolicy: mutationPolicyExclusive,
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"target":   pointerInputTargetSchema,
					"x":        map[string]any{"type": "number", "description": "X coordinate to scroll at"},
					"y":        map[string]any{"type": "number", "description": "Y coordinate to scroll at"},
					"scroll_x": map[string]any{"type": "number", "description": "Horizontal scroll delta (positive=right, negative=left)"},
					"scroll_y": map[string]any{"type": "number", "description": "Vertical scroll delta (positive=down, negative=up)"},
					"keys":     pointerModifierSchema,
					"duration": physicalDurationSchema(
						requestTimeoutSeconds,
						60,
						"Exact first-to-last scroll schedule in seconds",
					),
				},
				"required": []string{"target", "x", "y"},
			},
			Handler: s.cuaHandleScroll,
		},
		"drag": {
			Name:           "drag",
			Description:    "Click-and-drag along a sequence of waypoints. Uses Global Display Coordinates (top-left origin).",
			MutationPolicy: mutationPolicyExclusive,
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"target": pointerInputTargetSchema,
					"path": map[string]any{
						"type":        "array",
						"minItems":    2,
						"maxItems":    100,
						"items":       map[string]any{"type": "object", "properties": map[string]any{"x": map[string]any{"type": "number"}, "y": map[string]any{"type": "number"}}, "required": []string{"x", "y"}},
						"description": "Ordered waypoints, minimum 2 points",
					},
					"button": map[string]any{"type": "string", "description": "left (default), right, middle", "enum": []string{"left", "right", "middle"}, "default": "left"},
					"keys":   pointerModifierSchema,
					"duration": physicalDurationSchema(
						requestTimeoutSeconds,
						60,
						"Exact first-down-to-final-up drag duration in seconds",
					),
				},
				"required": []string{"target", "path"},
			},
			Handler: s.cuaHandleDrag,
		},
		"move": {
			Name:           "move",
			Description:    "Move mouse cursor to a position without clicking. Uses Global Display Coordinates (top-left origin).",
			MutationPolicy: mutationPolicyExclusive,
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"target": pointerInputTargetSchema,
					"x":      map[string]any{"type": "number", "description": "Target X coordinate"},
					"y":      map[string]any{"type": "number", "description": "Target Y coordinate"},
					"keys":   pointerModifierSchema,
					"duration": physicalDurationSchema(
						requestTimeoutSeconds,
						60,
						"Exact first-to-last movement schedule in seconds",
					),
				},
				"required": []string{"target", "x", "y"},
			},
			Handler: s.handleMove,
		},
		"wait": {
			Name:           "wait",
			Description:    "Pause for a specified duration.",
			MutationPolicy: mutationPolicyReadOnly,
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"duration": map[string]any{"type": "number", "exclusiveMinimum": 0, "maximum": requestTimeoutSeconds, "default": 1.0, "description": "Duration in seconds (default: 1.0)"},
				},
			},
			Handler: s.handleWait,
		},

		// === CATEGORY 2: APPLICATION MANAGEMENT (3 tools) ===

		"open_app": {
			Name:           "open_app",
			Description:    "Open one exact applicationBundles/* resource or activate one exact applications/* process returned by list_apps.",
			MutationPolicy: mutationPolicyExclusive,
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"app":            map[string]any{"type": "string", "description": "Exact applicationBundles/* or applications/* resource from list_apps"},
					"mode":           map[string]any{"type": "string", "description": "For applicationBundles/* only: launch_or_activate (default) or force_new_instance", "enum": []string{"launch_or_activate", "force_new_instance"}},
					"bring_to_front": map[string]any{"type": "boolean", "description": "For applicationBundles/* only: bring the result to foreground (default: true)"},
				},
				"required":             []string{"app"},
				"additionalProperties": false,
			},
			Handler: s.handleOpenApp,
		},
		"list_apps": {
			Name:           "list_apps",
			Description:    "Discover installed application bundles or list exact currently running application processes without opening anything.",
			MutationPolicy: mutationPolicyReadOnly,
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"kind":       map[string]any{"type": "string", "description": "installed (default) or running", "enum": []string{"installed", "running"}},
					"page_size":  map[string]any{"type": "integer", "description": "Maximum resources to return (0 uses the server default)", "minimum": 0, "maximum": 1000},
					"page_token": map[string]any{"type": "string", "description": "Opaque token from a prior list_apps call with identical query fields"},
					"filter":     map[string]any{"type": "string", "description": "Backend filter expression"},
					"order_by":   map[string]any{"type": "string", "description": "Backend ordering expression"},
					"full":       map[string]any{"type": "boolean", "description": "Include privacy-sensitive full bundle metadata such as file URL"},
				},
				"additionalProperties": false,
			},
			Handler: s.handleListApps,
		},
		"close_app": {
			Name:           "close_app",
			Description:    "Close one exact applications/* process resource returned by list_apps or open_app.",
			MutationPolicy: mutationPolicyExclusive,
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"app":   map[string]any{"type": "string", "description": "Exact applications/* resource"},
					"force": map[string]any{"type": "boolean", "description": "Force quit if app doesn't respond (default: false)"},
				},
				"required":             []string{"app"},
				"additionalProperties": false,
			},
			Handler: s.handleCloseApp,
		},

		// === CATEGORY 3: ELEMENT INTERACTION (4 tools) ===

		"find_elements": {
			Name:           "find_elements",
			Description:    "Find UI elements by criteria. Returns accessibility tree elements with role, text, position, and available actions.",
			MutationPolicy: mutationPolicyReadOnly,
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"parent":       map[string]any{"type": "string", "description": "Exact application or window resource search scope"},
					"selector":     map[string]any{"type": "string", "description": "One selector in key:value form, e.g. role:AXButton, text:Save, text_substring:submit"},
					"cache_bypass": map[string]any{"type": "boolean", "description": "Discard cached data (default: false)"},
					"page_size":    map[string]any{"type": "integer", "description": "Maximum elements to return"},
					"page_token":   map[string]any{"type": "string", "description": "Opaque page token from previous response"},
				},
				"required":             []string{"parent", "selector"},
				"additionalProperties": false,
			},
			Handler: s.cuaHandleFindElements,
		},
		"click_element": {
			Name:           "click_element",
			Description:    "Click a UI element via accessibility APIs. Automatically clicks the element center and acquires focus. Use a find_elements handle for that exact parent-bound AX identity, or a selector that must resolve uniquely; rediscover after the UI or owner changes.",
			MutationPolicy: mutationPolicyExclusive,
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"parent":   map[string]any{"type": "string", "description": "Parent context"},
					"element":  map[string]any{"type": "string", "description": "Parent-bound element handle from find_elements for one exact AX identity"},
					"selector": map[string]any{"type": "string", "description": "One key:value selector that must match exactly one element, e.g. role:AXButton, text:Save, text_substring:submit"},
				},
				"required": []string{"parent"},
			},
			Handler: s.cuaHandleClickElement,
		},
		"type_element": {
			Name:           "type_element",
			Description:    typeElementDescription,
			MutationPolicy: mutationPolicyExclusive,
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"parent":       map[string]any{"type": "string", "description": "Parent context"},
					"element":      map[string]any{"type": "string", "description": "Parent-bound element handle from find_elements for one exact AX identity"},
					"selector":     map[string]any{"type": "string", "description": "One key:value selector that must match exactly one element, e.g. role:AXTextArea, text:hello, text_substring:world"},
					"text":         map[string]any{"type": "string", "description": "Value to write. The current JSON handler treats omission and an explicit empty string as CLEAR; provide non-empty text to write a value."},
					"input_method": map[string]any{"type": "string", "description": "Input delivery method: 'ax' (default) uses direct AX value mutation; 'keystrokes' sends physical keyboard events for web/Electron DOM-event compatibility", "enum": []string{"ax", "keystrokes"}},
				},
				"required": []string{"parent"},
			},
			Handler: s.handleTypeElement,
		},
		"read_element": {
			Name:           "read_element",
			Description:    "Get detailed element info: role, text, bounds, value, available actions, focused/enabled state.",
			MutationPolicy: mutationPolicyReadOnly,
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"parent":  map[string]any{"type": "string", "description": "Exact application or window resource used by find_elements; required when element is a bare handle"},
					"element": map[string]any{"type": "string", "description": "Element resource name or bare element ID from find_elements"},
				},
				"required": []string{"element"},
			},
			Handler: s.handleReadElement,
		},

		// === CATEGORY 4: WINDOW MANAGEMENT (4 tools) ===

		"focus_window": {
			Name:           "focus_window",
			Description:    "Bring a window to the front.",
			MutationPolicy: mutationPolicyExclusive,
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"window": map[string]any{"type": "string", "description": "Window resource name"},
				},
				"required": []string{"window"},
			},
			Handler: s.cuaHandleFocusWindow,
		},
		"move_window": {
			Name:           "move_window",
			Description:    "Move a window to a new position. Uses Global Display Coordinates (top-left origin).",
			MutationPolicy: mutationPolicyExclusive,
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"window": map[string]any{"type": "string", "description": "Window resource name"},
					"x":      map[string]any{"type": "number", "description": "New X position (Global Display Coordinates)"},
					"y":      map[string]any{"type": "number", "description": "New Y position (Global Display Coordinates)"},
				},
				"required": []string{"window", "x", "y"},
			},
			Handler: s.cuaHandleMoveWindow,
		},
		"resize_window": {
			Name:           "resize_window",
			Description:    "Resize a window.",
			MutationPolicy: mutationPolicyExclusive,
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"window": map[string]any{"type": "string", "description": "Window resource name"},
					"width":  map[string]any{"type": "number", "description": "New width in pixels"},
					"height": map[string]any{"type": "number", "description": "New height in pixels"},
				},
				"required": []string{"window", "width", "height"},
			},
			Handler: s.cuaHandleResizeWindow,
		},
		"list_windows": {
			Name:           "list_windows",
			Description:    "List open windows.",
			MutationPolicy: mutationPolicyReadOnly,
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"app":        map[string]any{"type": "string", "description": "Exact parent application resource name"},
					"page_size":  map[string]any{"type": "integer", "description": "Maximum windows to return"},
					"page_token": map[string]any{"type": "string", "description": "Opaque page token from previous response"},
					"filter":     map[string]any{"type": "string", "description": "Exact ListWindows filter expression"},
					"order_by":   map[string]any{"type": "string", "description": "Exact ListWindows ordering expression"},
				},
				"required": []string{"app"},
			},
			Handler: s.cuaHandleListWindows,
		},

		// === CATEGORY 5: UTILITY (3 tools) ===

		"clipboard": {
			Name:           "clipboard",
			Description:    "Unified clipboard operations: get, set, or clear clipboard contents.",
			MutationPolicy: mutationPolicyClipboard,
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"action": map[string]any{"type": "string", "description": "get, set, clear", "enum": []string{"get", "set", "clear"}},
					"text":   map[string]any{"type": "string", "description": "Text content for set; omission is invalid and an empty string deliberately clears to empty text"},
				},
				"required": []string{"action"},
			},
			Handler: s.handleClipboard,
		},
		"run": {
			Name:           "run",
			Description:    "Execute scripts/commands. Type: shell (default), applescript, javascript.",
			MutationPolicy: mutationPolicyExclusive,
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"command": map[string]any{"type": "string", "description": "Command or script to execute"},
					"type":    map[string]any{"type": "string", "description": "shell (default), applescript, javascript", "enum": []string{"shell", "applescript", "javascript"}},
					"timeout": map[string]any{"type": "integer", "description": "Timeout in seconds (default: 30)"},
				},
				"required": []string{"command"},
			},
			Handler: s.handleRun,
		},
		"get_display": {
			Name:           "get_display",
			Description:    "Get display information and cursor position.",
			MutationPolicy: mutationPolicyReadOnly,
			InputSchema: map[string]any{
				"type":                 "object",
				"properties":           map[string]any{},
				"additionalProperties": false,
			},
			Handler: s.cuaHandleGetDisplay,
		},

		// === CATEGORY 6: MACRO MANAGEMENT (6 tools) ===

		"create_macro": {
			Name:           "create_macro",
			Description:    createMacroDescription,
			MutationPolicy: mutationPolicyExclusive,
			ValidateInput:  validateCreateMacroInput,
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"display_name": map[string]any{"type": "string", "minLength": 1, "maxLength": maxMacroDisplayNameLen, "description": "Human-readable macro name"},
					"description":  map[string]any{"type": "string", "maxLength": maxMacroDescriptionLen, "description": "Optional macro description"},
					"actions":      map[string]any{"type": "array", "minItems": 1, "items": macroActionSchema, "description": "Ordered macro actions"},
					"tags":         map[string]any{"type": "array", "maxItems": maxMacroTags, "items": map[string]any{"type": "string", "maxLength": maxMacroTagLen}, "description": "Optional tags"},
					"macro_id":     map[string]any{"type": "string", "description": "Optional user-supplied ID; server generates one if omitted"},
				},
				"required": []string{"display_name", "actions"},
			},
			Handler: s.handleCreateMacro,
		},
		"get_macro": {
			Name:           "get_macro",
			Description:    getMacroDescription,
			MutationPolicy: mutationPolicyReadOnly,
			ValidateInput:  validateMacroResourceInput,
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"macro": map[string]any{"type": "string", "description": "Exact macros/{id} resource name"},
				},
				"required": []string{"macro"},
			},
			Handler: s.handleGetMacro,
		},
		"list_macros": {
			Name:           "list_macros",
			Description:    listMacrosDescription,
			MutationPolicy: mutationPolicyReadOnly,
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"page_size":  map[string]any{"type": "integer", "description": "Maximum macros to return"},
					"page_token": map[string]any{"type": "string", "description": "Opaque page token from previous response"},
				},
			},
			Handler: s.handleListMacros,
		},
		"update_macro": {
			Name:           "update_macro",
			Description:    updateMacroDescription,
			MutationPolicy: mutationPolicyExclusive,
			ValidateInput:  validateUpdateMacroInput,
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"macro":        map[string]any{"type": "string", "description": "Exact macros/{id} resource name"},
					"display_name": map[string]any{"type": "string", "minLength": 1, "maxLength": maxMacroDisplayNameLen, "description": "New display name"},
					"description":  map[string]any{"type": "string", "maxLength": maxMacroDescriptionLen, "description": "New description"},
					"actions":      map[string]any{"type": "array", "minItems": 1, "items": macroActionSchema, "description": "New action list"},
					"tags":         map[string]any{"type": "array", "maxItems": maxMacroTags, "items": map[string]any{"type": "string", "maxLength": maxMacroTagLen}, "description": "New tag list"},
				},
				"required": []string{"macro"},
			},
			Handler: s.handleUpdateMacro,
		},
		"delete_macro": {
			Name:           "delete_macro",
			Description:    deleteMacroDescription,
			MutationPolicy: mutationPolicyExclusive,
			ValidateInput:  validateMacroResourceInput,
			Annotations: map[string]any{
				"readOnlyHint":    false,
				"destructiveHint": true,
				"idempotentHint":  false,
				"openWorldHint":   true,
			},
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"macro": map[string]any{"type": "string", "description": "Exact macros/{id} resource name"},
					"force": map[string]any{"type": "boolean", "description": "Force delete even if running (default: false)"},
				},
				"required": []string{"macro"},
			},
			Handler: s.handleDeleteMacro,
		},
		// === AUTHORIZATION: what is permitted, and asking for more ===

		"list_grants": {
			Name:           "list_grants",
			Description:    "List the permissions currently held, and how much life each has left. Use this BEFORE asking to do something you may already be permitted to do: re-asking costs the operator a prompt they have already answered.",
			MutationPolicy: mutationPolicyReadOnly,
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					// NO `skip` and no `page_size`: this project's rule is that a client
					// does not compute offsets or choose a page, and passes back a token it
					// was given without looking at it.
					"page_token": map[string]any{
						"type":        "string",
						"maxLength":   4096,
						"description": "Token from a previous response. Opaque: pass it back unexamined.",
					},
					"filter": map[string]any{
						"type":        "string",
						"maxLength":   4096,
						"description": "Comma-separated capability ids. Omit for every capability.",
					},
				},
			},
			Handler: s.handleListGrants,
		},
		"preauthorize": {
			Name:           "preauthorize",
			Description:    "Ask the operator to pre-authorize a DECLARED set of capabilities for a bounded time, before you need them. Use this at the START of a long task rather than interrupting the work at every step. The server grants the life it decides, which may be shorter than you asked for, and an envelope can never be global.",
			MutationPolicy: mutationPolicyExclusive,
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"capabilities": map[string]any{
						"type":        "array",
						"minItems":    1,
						"maxItems":    20,
						"items":       map[string]any{"type": "string"},
						"description": "The capability ids you expect to need, such as clipboard.read, observation.ax, input.synthesize. The envelope may NOT cover anything absent from this list, which is what makes it a declaration rather than a blank cheque.",
					},
					"reason": map[string]any{
						"type":        "string",
						"maxLength":   500,
						"description": "Why you need this batch, for the operator. This is what they read before deciding.",
					},
					"scopes": map[string]any{
						"type":        "array",
						"maxItems":    20,
						"items":       map[string]any{"type": "string"},
						"description": "The boundary each capability is wanted for. Omit for every application, which is the broadest answer and the one that costs most.",
					},
					"requested_lifetime": map[string]any{
						"type":        "object",
						"description": "How long you want the batch to live, as a duration in seconds. The server applies its own ceiling regardless, so this is a request and not a decision.",
						"properties": map[string]any{
							"seconds": map[string]any{
								"type":    "integer",
								"minimum": 1,
							},
						},
						"required": []string{"seconds"},
					},
				},
				"required": []string{"capabilities", "requested_lifetime", "reason"},
			},
			Handler: s.handlePreauthorize,
		},
		"execute_macro": {
			Name:           "execute_macro",
			Description:    executeMacroDescription,
			MutationPolicy: mutationPolicyExclusive,
			ValidateInput:  validateMacroResourceInput,
			Annotations: map[string]any{
				"readOnlyHint":    false,
				"destructiveHint": true,
				"idempotentHint":  false,
				"openWorldHint":   true,
			},
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"macro":       map[string]any{"type": "string", "description": "Exact macros/{id} resource name"},
					"application": map[string]any{"type": "string", "description": "Optional applications/{id} target for physical actions"},
					"timeout":     map[string]any{"type": "integer", "description": "Macro timeout in seconds (default: 300)"},
				},
				"required": []string{"macro"},
			},
			Handler: s.handleExecuteMacro,
		},
	}
	// Every tool gains the `reason` property and the consent guidance, applied here rather
	// than written twenty-odd times, because an agent cannot know in advance which of its
	// calls will need consent — the SERVER derives the capability from the request bytes —
	// and a property that appears on only some tools is one an agent learns to omit.
	//
	// The guidance goes on every description rather than only on the tools that obviously
	// reach the desktop, because a clipboard write and an accessibility read are exactly as
	// sensitive to a reader who does not know they are asking.
	for _, tool := range s.tools {
		addAgentReason(tool)
		closeToolObjectSchemas(tool.InputSchema)
	}
}

// addAgentReason adds the `reason` property and appends the consent guidance.
//
// It tolerates a tool whose schema has no `properties` object, because a tool with no
// arguments is a legitimate shape and refusing to give it a reason would be a bug in the
// registry rather than in the tool.
func addAgentReason(tool *Tool) {
	properties, ok := tool.InputSchema["properties"].(map[string]any)
	if !ok {
		properties = map[string]any{}
		tool.InputSchema["properties"] = properties
	}
	if _, alreadyThere := properties["reason"]; !alreadyThere {
		properties["reason"] = agentReasonSchema
	}
	tool.Description += AgentGuidance
}
