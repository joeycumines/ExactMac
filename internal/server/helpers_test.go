// Copyright 2025 Joseph Cumines

package server

import (
	"errors"
	"strconv"
	"strings"
	"testing"

	_type "github.com/joeycumines/ExactMac/gen/go/exactmac/type"
	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"github.com/joeycumines/ExactMac/internal/config"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestErrorResult(t *testing.T) {
	result := errorResult("test error")
	if !result.IsError {
		t.Error("expected IsError to be true")
	}
	if len(result.Content) != 1 {
		t.Fatalf("expected 1 content item, got %d", len(result.Content))
	}
	if result.Content[0].Type != "text" {
		t.Errorf("expected type 'text', got %q", result.Content[0].Type)
	}
	if result.Content[0].Text != "test error" {
		t.Errorf("expected text 'test error', got %q", result.Content[0].Text)
	}
}

func TestErrorResultf(t *testing.T) {
	result := errorResultf("error %d: %s", 42, "details")
	if !result.IsError {
		t.Error("expected IsError to be true")
	}
	if result.Content[0].Text != "error 42: details" {
		t.Errorf("expected 'error 42: details', got %q", result.Content[0].Text)
	}
}

func TestTextResult(t *testing.T) {
	result := textResult("success message")
	if result.IsError {
		t.Error("expected IsError to be false")
	}
	if len(result.Content) != 1 {
		t.Fatalf("expected 1 content item, got %d", len(result.Content))
	}
	if result.Content[0].Text != "success message" {
		t.Errorf("expected 'success message', got %q", result.Content[0].Text)
	}
}

func TestTextResultf(t *testing.T) {
	result := textResultf("count: %d", 99)
	if result.IsError {
		t.Error("expected IsError to be false")
	}
	if result.Content[0].Text != "count: 99" {
		t.Errorf("expected 'count: 99', got %q", result.Content[0].Text)
	}
}

func TestBoundsString(t *testing.T) {
	tests := []struct {
		name     string
		bounds   *pb.Bounds
		expected string
	}{
		{
			name:     "nil bounds",
			bounds:   nil,
			expected: "(unknown position and size)",
		},
		{
			name:     "origin bounds",
			bounds:   &pb.Bounds{X: 0, Y: 0, Width: 100, Height: 100},
			expected: "(0, 0) 100x100",
		},
		{
			name:     "positioned bounds",
			bounds:   &pb.Bounds{X: 100.5, Y: 200.7, Width: 800, Height: 600},
			expected: "(100.5, 200.7) 800x600",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := boundsString(tt.bounds)
			if got != tt.expected {
				t.Errorf("boundsString(%v) = %q, want %q", tt.bounds, got, tt.expected)
			}
		})
	}
}

func TestBoundsPosition(t *testing.T) {
	tests := []struct {
		name     string
		bounds   *pb.Bounds
		expected string
	}{
		{
			name:     "nil bounds",
			bounds:   nil,
			expected: "(unknown)",
		},
		{
			name:     "origin",
			bounds:   &pb.Bounds{X: 0, Y: 0},
			expected: "(0, 0)",
		},
		{
			name:     "positioned",
			bounds:   &pb.Bounds{X: 100, Y: 200},
			expected: "(100, 200)",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := boundsPosition(tt.bounds)
			if got != tt.expected {
				t.Errorf("boundsPosition(%v) = %q, want %q", tt.bounds, got, tt.expected)
			}
		})
	}
}

func TestBoundsSize(t *testing.T) {
	tests := []struct {
		name     string
		bounds   *pb.Bounds
		expected string
	}{
		{
			name:     "nil bounds",
			bounds:   nil,
			expected: "(unknown)",
		},
		{
			name:     "zero size",
			bounds:   &pb.Bounds{Width: 0, Height: 0},
			expected: "0x0",
		},
		{
			name:     "sized",
			bounds:   &pb.Bounds{Width: 1920, Height: 1080},
			expected: "1920x1080",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := boundsSize(tt.bounds)
			if got != tt.expected {
				t.Errorf("boundsSize(%v) = %q, want %q", tt.bounds, got, tt.expected)
			}
		})
	}
}

func TestFrameString(t *testing.T) {
	tests := []struct {
		name     string
		frame    *_type.Region
		expected string
	}{
		{
			name:     "nil frame",
			frame:    nil,
			expected: "(unknown frame)",
		},
		{
			name:     "origin frame",
			frame:    &_type.Region{X: 0, Y: 0, Width: 1920, Height: 1080},
			expected: "1920x1080 @ (0, 0)",
		},
		{
			name:     "offset frame",
			frame:    &_type.Region{X: -1920, Y: 0, Width: 1920, Height: 1080},
			expected: "1920x1080 @ (-1920, 0)",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := frameString(tt.frame)
			if got != tt.expected {
				t.Errorf("frameString(%v) = %q, want %q", tt.frame, got, tt.expected)
			}
		})
	}
}

func TestTruncateText(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{
			name:     "short text unchanged",
			input:    "hello",
			expected: "hello",
		},
		{
			name:     "exactly at limit",
			input:    "12345678901234567890123456789012345678901234567890", // 50 chars
			expected: "12345678901234567890123456789012345678901234567890",
		},
		{
			name:     "over limit truncated",
			input:    "123456789012345678901234567890123456789012345678901", // 51 chars
			expected: "12345678901234567890123456789012345678901234567890...",
		},
		{
			name:     "empty string",
			input:    "",
			expected: "",
		},
		{
			name:     "long text truncated",
			input:    "This is a very long text that exceeds the maximum display length and should be truncated with an ellipsis at the end",
			expected: "This is a very long text that exceeds the maximum ...",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := truncateText(tt.input)
			if got != tt.expected {
				t.Errorf("truncateText(%q) = %q, want %q", tt.input, got, tt.expected)
			}
		})
	}
}

func TestMaxDisplayTextLen(t *testing.T) {
	// Verify the constant has the expected value
	if maxDisplayTextLen != 50 {
		t.Errorf("maxDisplayTextLen = %d, want 50", maxDisplayTextLen)
	}
}

func TestFormatGRPCError_NilError(t *testing.T) {
	result := formatGRPCError(nil, "test_tool")
	if result != "" {
		t.Errorf("formatGRPCError(nil) = %q, want empty string", result)
	}
}

func TestFormatGRPCError_NonGRPCError(t *testing.T) {
	err := errors.New("standard error message")
	result := formatGRPCError(err, "test_tool")

	expected := "Error in test_tool: standard error message"
	if result != expected {
		t.Errorf("formatGRPCError() = %q, want %q", result, expected)
	}
}

func TestFormatGRPCError_GRPCStatusCodes(t *testing.T) {
	tests := []struct {
		name           string
		code           codes.Code
		message        string
		toolName       string
		wantCode       string
		wantSuggestion string
	}{
		{
			name:           "PermissionDenied",
			code:           codes.PermissionDenied,
			message:        "accessibility access denied",
			toolName:       "click",
			wantCode:       "PermissionDenied",
			wantSuggestion: "Ensure accessibility permissions are granted",
		},
		{
			name:           "NotFound",
			code:           codes.NotFound,
			message:        "window not found",
			toolName:       "get_window",
			wantCode:       "NotFound",
			wantSuggestion: "Verify the resource exists",
		},
		{
			name:           "InvalidArgument",
			code:           codes.InvalidArgument,
			message:        "invalid selector",
			toolName:       "find_elements",
			wantCode:       "InvalidArgument",
			wantSuggestion: "Check the request parameters",
		},
		{
			name:           "Unavailable",
			code:           codes.Unavailable,
			message:        "connection refused",
			toolName:       "screenshot",
			wantCode:       "Unavailable",
			wantSuggestion: "The gRPC server may be down",
		},
		{
			name:           "DeadlineExceeded",
			code:           codes.DeadlineExceeded,
			message:        "operation timed out",
			toolName:       "wait_element",
			wantCode:       "DeadlineExceeded",
			wantSuggestion: "consent prompt was likely unanswered",
		},
		{
			name:           "Internal",
			code:           codes.Internal,
			message:        "internal server error",
			toolName:       "traverse_accessibility",
			wantCode:       "Internal",
			wantSuggestion: "An internal server error occurred",
		},
		{
			name:           "FailedPrecondition",
			code:           codes.FailedPrecondition,
			message:        "app not running",
			toolName:       "open_application",
			wantCode:       "FailedPrecondition",
			wantSuggestion: "precondition not being met",
		},
		{
			name:           "AlreadyExists",
			code:           codes.AlreadyExists,
			message:        "session already exists",
			toolName:       "create_session",
			wantCode:       "AlreadyExists",
			wantSuggestion: "A resource with this identifier already exists",
		},
		{
			name:           "ResourceExhausted",
			code:           codes.ResourceExhausted,
			message:        "rate limit exceeded",
			toolName:       "list_windows",
			wantCode:       "ResourceExhausted",
			wantSuggestion: "Rate limit exceeded",
		},
		{
			name:           "Unimplemented",
			code:           codes.Unimplemented,
			message:        "not implemented",
			toolName:       "drag_files",
			wantCode:       "Unimplemented",
			wantSuggestion: "not implemented or supported",
		},
		{
			name:           "UnknownCode_NoSuggestion",
			code:           codes.Unknown,
			message:        "unknown error",
			toolName:       "test_tool",
			wantCode:       "Unknown",
			wantSuggestion: "", // No suggestion for Unknown code
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := status.Error(tt.code, tt.message)
			result := formatGRPCError(err, tt.toolName)

			// Check tool name is included
			if !strings.Contains(result, tt.toolName) {
				t.Errorf("result should contain tool name %q: %s", tt.toolName, result)
			}

			// Check code is included
			if !strings.Contains(result, tt.wantCode) {
				t.Errorf("result should contain code %q: %s", tt.wantCode, result)
			}

			// Check message is included
			if !strings.Contains(result, tt.message) {
				t.Errorf("result should contain message %q: %s", tt.message, result)
			}

			// Check suggestion is included (if expected)
			if tt.wantSuggestion != "" {
				if !strings.Contains(result, "Suggestion:") {
					t.Errorf("result should contain 'Suggestion:': %s", result)
				}
				if !strings.Contains(result, tt.wantSuggestion) {
					t.Errorf("result should contain suggestion %q: %s", tt.wantSuggestion, result)
				}
			} else {
				// For Unknown code, verify no suggestion line
				if strings.Contains(result, "Suggestion:") {
					t.Errorf("result should NOT contain 'Suggestion:' for code %s: %s", tt.wantCode, result)
				}
			}
		})
	}
}

// The deadline error QUOTES THE NUMBERS THE CALLER IS ACTUALLY WORKING WITH: this
// client's own request timeout and the server's consent bound. Asserting both numbers
// by their constants — not by literals in this file — is what makes the error's
// arithmetic checked rather than decorated: if either constant moves and the suggestion
// stops naming the values that produced the timeout, this fails.
func TestFormatGRPCError_DeadlineExceededNamesTheConsentCause(t *testing.T) {
	err := status.Error(codes.DeadlineExceeded, "context deadline exceeded")
	result := formatGRPCError(err, "get_display")

	if !strings.Contains(result, strconv.Itoa(requestTimeoutSeconds)) {
		t.Errorf("deadline error should quote the client's own timeout %d: %s",
			requestTimeoutSeconds, result)
	}
	if !strings.Contains(result, strconv.Itoa(config.ServerConsentTimeoutSeconds)) {
		t.Errorf("deadline error should quote the server's consent bound %d: %s",
			config.ServerConsentTimeoutSeconds, result)
	}
	if !strings.Contains(result, "EXACTMAC_CONSENT_TIMEOUT_SECONDS") {
		t.Errorf("deadline error should name the server setting that governs the wait: %s", result)
	}
}

func TestFormatGRPCError_DeadlineExceededWithCustomRequestTimeout(t *testing.T) {
	old := requestTimeoutSeconds
	defer func() { requestTimeoutSeconds = old }()

	cfg := &config.Config{
		ServerAddr:                     "127.0.0.1:50051",
		RequestTimeout:                 180,
		MaxConcurrentRequests:          10,
		MaxConcurrentRequestsPerClient: 5,
	}
	_, errServer := NewMCPServer(cfg)
	if errServer != nil {
		t.Logf("NewMCPServer error: %v", errServer)
	}

	err := status.Error(codes.DeadlineExceeded, "context deadline exceeded")
	result := formatGRPCError(err, "get_display")

	if !strings.Contains(result, "180 seconds") {
		t.Errorf("deadline error should quote custom timeout 180: %s", result)
	}
}

func TestFormatGRPCError_OutputFormat(t *testing.T) {
	err := status.Error(codes.NotFound, "window not found")
	result := formatGRPCError(err, "get_window")

	// Verify the output format matches expected structure
	expected := "Error in get_window: NotFound - window not found\nSuggestion: Verify the resource exists and the name/ID is correct"
	if result != expected {
		t.Errorf("formatGRPCError() format mismatch:\ngot:  %q\nwant: %q", result, expected)
	}
}

func TestGRPCErrorResult(t *testing.T) {
	err := status.Error(codes.PermissionDenied, "screen capture denied")
	result := grpcErrorResult(err, "screenshot")

	// Verify it returns a ToolResult with IsError=true
	if !result.IsError {
		t.Error("expected IsError to be true")
	}

	// Verify content is set
	if len(result.Content) != 1 {
		t.Fatalf("expected 1 content item, got %d", len(result.Content))
	}

	// Verify content type
	if result.Content[0].Type != "text" {
		t.Errorf("expected type 'text', got %q", result.Content[0].Type)
	}

	// Verify the text contains expected parts
	text := result.Content[0].Text
	if !strings.Contains(text, "screenshot") {
		t.Errorf("result should contain tool name: %s", text)
	}
	if !strings.Contains(text, "PermissionDenied") {
		t.Errorf("result should contain error code: %s", text)
	}
	if !strings.Contains(text, "screen capture denied") {
		t.Errorf("result should contain error message: %s", text)
	}
	if !strings.Contains(text, "Suggestion:") {
		t.Errorf("result should contain suggestion: %s", text)
	}
}

func TestGRPCErrorResult_NonGRPCError(t *testing.T) {
	err := errors.New("plain error")
	result := grpcErrorResult(err, "test_tool")

	if !result.IsError {
		t.Error("expected IsError to be true")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Error in test_tool: plain error") {
		t.Errorf("result should contain formatted message: %s", text)
	}
}

// resultIsError checks whether a ToolResult represents an error.
func resultIsError(r *ToolResult) bool {
	return r != nil && r.IsError
}

// resultText returns the concatenated text content of a ToolResult.
func resultText(r *ToolResult) string {
	if r == nil {
		return ""
	}
	var parts []string
	for _, c := range r.Content {
		if c.Type == "text" {
			parts = append(parts, c.Text)
		}
	}
	return strings.Join(parts, "\n")
}

// resultContains checks whether the ToolResult text contains the given substring.
func resultContains(r *ToolResult, substr string) bool {
	return strings.Contains(resultText(r), substr)
}

func TestCUATruncateText(t *testing.T) {
	tests := []struct {
		name string
		text string
		want string
	}{
		{"short text passes through", "hello", "hello"},
		{"exactly max length", strings.Repeat("a", maxDisplayTextLen), strings.Repeat("a", maxDisplayTextLen)},
		{"over max length truncated", strings.Repeat("a", maxDisplayTextLen+10), strings.Repeat("a", maxDisplayTextLen) + "..."},
		{"empty string", "", ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := truncateText(tt.text)
			if got != tt.want {
				t.Errorf("truncateText() = %q, want %q", got, tt.want)
			}
		})
	}
}
