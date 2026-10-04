// Copyright 2025 Joseph Cumines
//
// Helper functions for tool handlers

package server

import (
	"fmt"
	"strconv"
	"strings"
	"time"

	_type "github.com/joeycumines/ExactMac/gen/go/exactmac/type"
	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"github.com/joeycumines/ExactMac/internal/config"
	"google.golang.org/grpc/codes"
	grpcstatus "google.golang.org/grpc/status"
)

// requestTimeoutSeconds is the per-request deadline this client applies, in seconds.
//
// IT IS THE CONFIG'S OWN VALUE, restated here so the deadline error can quote the number
// the caller was actually given. formatGRPCError is a package function with no Config in
// reach, and threading the whole config through 36 call sites to quote one number in one
// error branch is not worth the churn; the config validates at startup that this value is
// longer than the server's consent wait, so the error's arithmetic is checked once where
// the value is born rather than re-derived at every failure.
var requestTimeoutSeconds = config.DefaultRequestTimeoutSeconds

// maxDisplayTextLen is the maximum length for text shown in result summaries.
// Longer text is truncated with "..." suffix.
const maxDisplayTextLen = 50

// maxInputTextLen is the maximum allowed length for text/script input parameters.
// Prevents memory exhaustion from unbounded user input.
const maxInputTextLen = 1 << 20 // 1 MiB

// maxPathLen is the maximum allowed length for file path parameters.
const maxPathLen = 4096

// defaultApplicationParent is the parent pattern for inputs targeting any/active application.
const defaultApplicationParent = "applications/-"

// defaultScriptTimeout is the default timeout for script execution in seconds.
const defaultScriptTimeout = 30

// validateInputLen returns an error result if the input exceeds maxLen.
func validateInputLen(input string, maxLen int, paramName string) *ToolResult {
	if len(input) > maxLen {
		return errorResultf("%s exceeds maximum length of %d bytes (got %d)", paramName, maxLen, len(input))
	}
	return nil
}

// truncateText truncates text to maxDisplayTextLen Unicode code points with an
// ASCII ellipsis suffix. The cut always lands on a UTF-8 boundary.
func truncateText(s string) string {
	runeCount := 0
	for byteIndex := range s {
		if runeCount == maxDisplayTextLen {
			return s[:byteIndex] + "..."
		}
		runeCount++
	}
	return s
}

// errorResult creates a ToolResult with IsError=true and the given message.
// This reduces boilerplate for error responses across handlers.
func errorResult(msg string) *ToolResult {
	return &ToolResult{
		IsError: true,
		Content: []Content{{Type: "text", Text: msg}},
	}
}

// errorResultf creates a ToolResult with IsError=true and a formatted message.
// This is the sprintf version of errorResult.
func errorResultf(format string, args ...any) *ToolResult {
	return errorResult(fmt.Sprintf(format, args...))
}

// textResult creates a ToolResult with a single text content.
// This reduces boilerplate for simple text responses.
func textResult(text string) *ToolResult {
	return &ToolResult{
		Content: []Content{{Type: "text", Text: text}},
	}
}

// textResultf creates a ToolResult with a formatted text content.
func textResultf(format string, args ...any) *ToolResult {
	return textResult(fmt.Sprintf(format, args...))
}

// boundsString returns a formatted string representation of window bounds,
// safely handling nil bounds with a fallback value.
func boundsString(b *pb.Bounds) string {
	if b == nil {
		return "(unknown position and size)"
	}
	return fmt.Sprintf(
		"(%s, %s) %sx%s",
		strconv.FormatFloat(b.X, 'g', -1, 64),
		strconv.FormatFloat(b.Y, 'g', -1, 64),
		strconv.FormatFloat(b.Width, 'g', -1, 64),
		strconv.FormatFloat(b.Height, 'g', -1, 64),
	)
}

// boundsPosition returns a formatted position string from window bounds,
// safely handling nil bounds.
func boundsPosition(b *pb.Bounds) string {
	if b == nil {
		return "(unknown)"
	}
	return fmt.Sprintf(
		"(%s, %s)",
		strconv.FormatFloat(b.X, 'g', -1, 64),
		strconv.FormatFloat(b.Y, 'g', -1, 64),
	)
}

// boundsSize returns a formatted size string from window bounds,
// safely handling nil bounds.
func boundsSize(b *pb.Bounds) string {
	if b == nil {
		return "(unknown)"
	}
	return fmt.Sprintf(
		"%sx%s",
		strconv.FormatFloat(b.Width, 'g', -1, 64),
		strconv.FormatFloat(b.Height, 'g', -1, 64),
	)
}

// frameString returns a formatted string representation of a display frame,
// safely handling nil frames.
func frameString(f *_type.Region) string {
	if f == nil {
		return "(unknown frame)"
	}
	return fmt.Sprintf(
		"%sx%s @ (%s, %s)",
		strconv.FormatFloat(f.Width, 'g', -1, 64),
		strconv.FormatFloat(f.Height, 'g', -1, 64),
		strconv.FormatFloat(f.X, 'g', -1, 64),
		strconv.FormatFloat(f.Y, 'g', -1, 64),
	)
}

// formatGRPCError formats a gRPC error with context for MCP tool responses.
// It extracts the gRPC status code and message, and provides actionable suggestions
// for common error scenarios.
func formatGRPCError(err error, toolName string) string {
	if err == nil {
		return ""
	}

	st, ok := grpcstatus.FromError(err)
	if !ok {
		// Not a gRPC error, return as-is
		return fmt.Sprintf("Error in %s: %s", toolName, err.Error())
	}

	code := st.Code()
	msg := st.Message()
	suggestion := ""

	switch code {
	case codes.PermissionDenied:
		suggestion = "Ensure accessibility permissions are granted in System Preferences > Privacy & Security > Accessibility"
	case codes.NotFound:
		suggestion = "Verify the resource exists and the name/ID is correct"
	case codes.InvalidArgument:
		suggestion = "Check the request parameters for invalid or missing values"
	case codes.Unavailable:
		suggestion = "The gRPC server may be down or unreachable. Check server status"
	case codes.DeadlineExceeded:
		// THE DEADLINE NAMES ITS CAUSE, because "Operation timed out. Try increasing
		// timeout" sent operators to debug their network, their agent host and their
		// permissions when the actual mechanism was the server's consent wait: the
		// request was held for a person to answer and nobody answered in time. This
		// client's own deadline is validated at startup to be longer than that wait
		// (internal/config: validate() refuses a shorter one), so reaching here with the
		// derived deadline almost always means the consent bound expired unanswered.
		// The remedy is on the server — EXACTMAC_CONSENT_TIMEOUT_SECONDS — and naming
		// it is what makes the error actionable instead of misleading.
		suggestion = fmt.Sprintf(
			"The request was not answered within %d seconds. If this call needs the operator's "+
				"approval, the consent prompt was likely unanswered or expired before anyone saw it. "+
				"Pass a reason so the request is worth approving, and if this deadline is genuinely "+
				"too short, raise EXACTMAC_REQUEST_TIMEOUT here and the server's "+
				"EXACTMAC_CONSENT_TIMEOUT_SECONDS (currently %d) to match",
			requestTimeoutSeconds,
			config.ServerConsentTimeoutSeconds,
		)
	case codes.Internal:
		suggestion = "An internal server error occurred. Check server logs for details"
	case codes.FailedPrecondition:
		suggestion = "The operation failed due to a precondition not being met. Check if the resource is in the correct state"
	case codes.AlreadyExists:
		suggestion = "A resource with this identifier already exists"
	case codes.ResourceExhausted:
		suggestion = "Rate limit exceeded or quota exhausted. Try again later"
	case codes.Unimplemented:
		suggestion = "This operation is not implemented or supported"
	}

	result := fmt.Sprintf("Error in %s: %s - %s", toolName, code.String(), msg)
	if suggestion != "" {
		result += fmt.Sprintf("\nSuggestion: %s", suggestion)
	}
	return result
}

// grpcErrorResult creates a ToolResult with IsError=true and a formatted gRPC error message.
// This is a convenience wrapper combining formatGRPCError and errorResult.
func grpcErrorResult(err error, toolName string) *ToolResult {
	return errorResult(formatGRPCError(err, toolName))
}

// grpcErrorResultWithTimeout creates a ToolResult with IsError=true and a formatted
// gRPC error message, adding timeout context when a deadline was exceeded.
// This is used by the scripting handlers to distinguish script vs request timeouts (M6).
func grpcErrorResultWithTimeout(err error, toolName string, effectiveTimeout time.Duration) *ToolResult {
	msg := formatGRPCError(err, toolName)
	if effectiveTimeout > 0 && err != nil {
		if strings.Contains(strings.ToLower(err.Error()), "deadline") || strings.Contains(strings.ToLower(err.Error()), "context") {
			msg = fmt.Sprintf("%s (timed out after %v — script-level timeout enforcement)", msg, effectiveTimeout)
		}
	}
	return errorResult(msg)
}
