// Copyright 2025 Joseph Cumines
//
// Audit logger unit tests

package server

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestNewAuditLogger_Disabled(t *testing.T) {
	logger, err := NewAuditLogger("")
	if err != nil {
		t.Fatalf("NewAuditLogger('') error = %v", err)
	}
	if logger.IsEnabled() {
		t.Error("Expected logger to be disabled when no file path provided")
	}
}

func TestNewAuditLogger_Enabled(t *testing.T) {
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "audit.log")

	logger, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}
	defer logger.Close()

	if !logger.IsEnabled() {
		t.Error("Expected logger to be enabled")
	}
}

func TestAuditLogger_NonContentMetadataOnly(t *testing.T) {
	logPath := filepath.Join(t.TempDir(), "audit.log")
	logger, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}

	const privateMarker = "FUNC-002-AUDIT-PRIVATE-CONTENT-7b83d1"
	logger.LogToolCall(
		"type",
		json.RawMessage(`{"text":"`+privateMarker+`","parent":"applications/123"}`),
		"success",
		50*time.Millisecond,
	)
	if err := logger.Close(); err != nil {
		t.Fatalf("Close error = %v", err)
	}

	content, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("ReadFile error = %v", err)
	}
	if strings.Contains(string(content), privateMarker) {
		t.Fatalf("audit log persisted private tool content: %s", content)
	}
	var entry map[string]any
	if err := json.Unmarshal(content, &entry); err != nil {
		t.Fatalf("decode audit entry: %v", err)
	}
	if _, exists := entry["arguments"]; exists {
		t.Fatalf("audit entry contains forbidden arguments field: %v", entry)
	}
	for _, field := range []string{"tool", "status", "duration_seconds", "timestamp"} {
		if _, exists := entry[field]; !exists {
			t.Errorf("audit metadata omitted %q: %v", field, entry)
		}
	}
}

func TestNewAuditLogger_CreatesOwnerPrivateRegularFile(t *testing.T) {
	logPath := filepath.Join(t.TempDir(), "audit.log")
	logger, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}
	defer logger.Close()

	info, err := os.Lstat(logPath)
	if err != nil {
		t.Fatalf("Lstat audit log: %v", err)
	}
	if !info.Mode().IsRegular() {
		t.Fatalf("audit log mode=%v, want regular file", info.Mode())
	}
	if got := info.Mode().Perm(); got != 0600 {
		t.Fatalf("audit log permissions=%#o, want 0600", got)
	}
}

func TestNewAuditLogger_RejectsSymlinkWithoutTouchingTarget(t *testing.T) {
	tmpDir := t.TempDir()
	targetPath := filepath.Join(tmpDir, "target")
	const sentinel = "do-not-touch"
	if err := os.WriteFile(targetPath, []byte(sentinel), 0600); err != nil {
		t.Fatalf("write target: %v", err)
	}
	logPath := filepath.Join(tmpDir, "audit.log")
	if err := os.Symlink(targetPath, logPath); err != nil {
		t.Fatalf("create symlink: %v", err)
	}

	logger, err := NewAuditLogger(logPath)
	if logger != nil {
		_ = logger.Close()
	}
	if err == nil {
		t.Fatal("NewAuditLogger accepted symlink path")
	}
	content, readErr := os.ReadFile(targetPath)
	if readErr != nil {
		t.Fatalf("read target: %v", readErr)
	}
	if string(content) != sentinel {
		t.Fatalf("symlink target changed: %q", content)
	}
}

func TestNewAuditLogger_RejectsHardLinkedFile(t *testing.T) {
	tmpDir := t.TempDir()
	targetPath := filepath.Join(tmpDir, "target")
	if err := os.WriteFile(targetPath, []byte("sentinel"), 0600); err != nil {
		t.Fatalf("write target: %v", err)
	}
	logPath := filepath.Join(tmpDir, "audit.log")
	if err := os.Link(targetPath, logPath); err != nil {
		t.Fatalf("create hard link: %v", err)
	}

	logger, err := NewAuditLogger(logPath)
	if logger != nil {
		_ = logger.Close()
	}
	if err == nil {
		t.Fatal("NewAuditLogger accepted multiply linked file")
	}
}

func TestNewAuditLogger_RejectsExistingNonPrivateFile(t *testing.T) {
	logPath := filepath.Join(t.TempDir(), "audit.log")
	if err := os.WriteFile(logPath, []byte("existing"), 0644); err != nil {
		t.Fatalf("write existing log: %v", err)
	}
	if err := os.Chmod(logPath, 0644); err != nil {
		t.Fatalf("chmod existing log: %v", err)
	}

	logger, err := NewAuditLogger(logPath)
	if logger != nil {
		_ = logger.Close()
	}
	if err == nil {
		t.Fatal("NewAuditLogger accepted group/world-readable file")
	}
}

func TestNewAuditLogger_RejectsDevice(t *testing.T) {
	logger, err := NewAuditLogger("/dev/null")
	if logger != nil {
		_ = logger.Close()
	}
	if err == nil {
		t.Fatal("NewAuditLogger accepted character device")
	}
}

func TestNewAuditLogger_InvalidPath(t *testing.T) {
	// Try to create log in non-existent directory without creating it
	_, err := NewAuditLogger("/nonexistent/directory/that/doesnt/exist/audit.log")
	if err == nil {
		t.Error("Expected error for invalid path")
	}
}

func TestAuditLogger_LogToolCall(t *testing.T) {
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "audit.log")

	logger, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}
	defer logger.Close()

	// Log a tool call
	args := json.RawMessage(`{"x": 100, "y": 200}`)
	logger.LogToolCall("click", args, "success", 50*time.Millisecond)

	// Close to flush
	logger.Close()

	// Read the log file
	content, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("ReadFile error = %v", err)
	}

	logStr := string(content)
	if !strings.Contains(logStr, `"tool":"click"`) {
		t.Errorf("Log should contain tool name, got: %s", logStr)
	}
	if !strings.Contains(logStr, `"status":"success"`) {
		t.Errorf("Log should contain status, got: %s", logStr)
	}
	if !strings.Contains(logStr, `"msg":"tool_invocation"`) {
		t.Errorf("Log should contain message type, got: %s", logStr)
	}
}

func TestAuditLogger_LogToolCall_Disabled(t *testing.T) {
	logger, err := NewAuditLogger("")
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}

	// Should not panic when disabled
	args := json.RawMessage(`{"x": 100}`)
	logger.LogToolCall("click", args, "success", 50*time.Millisecond)
}

func TestAuditLogger_NilLogger(t *testing.T) {
	var logger *AuditLogger = nil

	if logger.IsEnabled() {
		t.Error("Nil logger should not be enabled")
	}

	// Should not panic
	args := json.RawMessage(`{}`)
	logger.LogToolCall("click", args, "success", 50*time.Millisecond)
}

func TestAuditLogger_ArgumentShapesNeverPersisted(t *testing.T) {
	logPath := filepath.Join(t.TempDir(), "audit.log")
	logger, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}
	markers := []string{
		"AUDIT-SAFE-VISIBLE-ARGUMENT",
		"AUDIT-SAFE-NESTED-SECRET",
		"AUDIT-SAFE-MALFORMED",
	}
	arguments := []json.RawMessage{
		json.RawMessage(`{"text":"` + markers[0] + `"}`),
		json.RawMessage(`{"nested":{"password":"` + markers[1] + `"}}`),
		json.RawMessage(`{` + markers[2]),
	}
	for _, args := range arguments {
		logger.LogToolCall("type", args, "success", time.Millisecond)
	}
	if err := logger.Close(); err != nil {
		t.Fatalf("Close error = %v", err)
	}
	content, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("ReadFile error = %v", err)
	}
	for _, marker := range markers {
		if strings.Contains(string(content), marker) {
			t.Errorf("audit log persisted argument marker %q", marker)
		}
	}
	if strings.Contains(string(content), `"arguments"`) {
		t.Fatalf("audit log persisted forbidden arguments field: %s", content)
	}
}

// TestAuditLogger_ConcurrentWrites verifies that multiple goroutines can write
// to the audit logger concurrently without causing data corruption or races.
func TestAuditLogger_ConcurrentWrites(t *testing.T) {
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "concurrent_audit.log")

	logger, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}

	const numGoroutines = 10
	const writesPerGoroutine = 50

	var wg sync.WaitGroup
	wg.Add(numGoroutines)

	for i := range numGoroutines {
		go func(goroutineID int) {
			defer wg.Done()
			for j := range writesPerGoroutine {
				args := json.RawMessage(`{"goroutine":` + string(rune('0'+goroutineID%10)) + `}`)
				logger.LogToolCall("concurrent_test", args, "success", time.Duration(j)*time.Millisecond)
			}
		}(i)
	}

	wg.Wait()

	if err := logger.Close(); err != nil {
		t.Fatalf("Close error = %v", err)
	}

	// Verify all lines are valid JSON and count them
	file, err := os.Open(logPath)
	if err != nil {
		t.Fatalf("Open error = %v", err)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	lineCount := 0
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		lineCount++

		var entry map[string]any
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Errorf("Line %d is not valid JSON: %v\nContent: %s", lineCount, err, line)
		}
	}

	if err := scanner.Err(); err != nil {
		t.Fatalf("Scanner error = %v", err)
	}

	expectedLines := numGoroutines * writesPerGoroutine
	if lineCount != expectedLines {
		t.Errorf("Expected %d log lines, got %d", expectedLines, lineCount)
	}
}

// TestAuditLogger_JSONFormatValidation verifies that each line in the audit log
// is valid JSON and can be parsed.
func TestAuditLogger_JSONFormatValidation(t *testing.T) {
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "json_audit.log")

	logger, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}

	// Write various tool calls with different argument structures
	testCases := []struct {
		tool   string
		args   string
		status string
	}{
		{"click", `{"x": 100, "y": 200}`, "success"},
		{"type", `{"text": "hello world"}`, "success"},
		{"screenshot", `{}`, "error"},
		{"move_window", `{"window_id": 123, "x": 0, "y": 0}`, "success"},
		{"complex_args", `{"nested": {"a": 1, "b": [1,2,3]}, "array": ["x","y"]}`, "success"},
	}

	for _, tc := range testCases {
		logger.LogToolCall(tc.tool, json.RawMessage(tc.args), tc.status, 100*time.Millisecond)
	}

	if err := logger.Close(); err != nil {
		t.Fatalf("Close error = %v", err)
	}

	// Read and validate each line
	content, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("ReadFile error = %v", err)
	}

	lines := strings.Split(strings.TrimSpace(string(content)), "\n")
	if len(lines) != len(testCases) {
		t.Fatalf("Expected %d log lines, got %d", len(testCases), len(lines))
	}

	for i, line := range lines {
		var entry map[string]any
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Errorf("Line %d is not valid JSON: %v\nContent: %s", i+1, err, line)
			continue
		}

		// Verify it has the expected tool name
		if tool, ok := entry["tool"].(string); !ok || tool != testCases[i].tool {
			t.Errorf("Line %d: expected tool=%q, got %v", i+1, testCases[i].tool, entry["tool"])
		}
	}
}

// TestAuditLogger_CloseIdempotency verifies that repeated Close calls preserve
// successful cleanup and disable future writes.
func TestAuditLogger_CloseIdempotency(t *testing.T) {
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "idempotent_audit.log")

	logger, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}

	// Write something
	args := json.RawMessage(`{"test": true}`)
	logger.LogToolCall("test_tool", args, "success", 10*time.Millisecond)

	// First close should succeed
	err1 := logger.Close()
	if err1 != nil {
		t.Errorf("First Close() error = %v", err1)
	}

	if err := logger.Close(); err != nil {
		t.Errorf("Second Close() error = %v", err)
	}
	if err := logger.Close(); err != nil {
		t.Errorf("Third Close() error = %v", err)
	}
	if logger.IsEnabled() {
		t.Error("logger remains enabled after Close")
	}

	// Verify file content is intact
	content, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("ReadFile error = %v", err)
	}
	if !strings.Contains(string(content), "test_tool") {
		t.Error("Log file should contain test_tool entry")
	}
}

// TestAuditLogger_CloseIdempotency_Disabled verifies Close() on disabled logger is safe.
func TestAuditLogger_CloseIdempotency_Disabled(t *testing.T) {
	logger, err := NewAuditLogger("")
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}

	// Close on disabled logger should be safe
	if err := logger.Close(); err != nil {
		t.Errorf("Close on disabled logger error = %v", err)
	}

	// Multiple closes should be safe
	if err := logger.Close(); err != nil {
		t.Errorf("Second Close on disabled logger error = %v", err)
	}
}

// TestAuditLogger_LogEntryFields verifies that each log entry contains all required fields.
func TestAuditLogger_LogEntryFields(t *testing.T) {
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "fields_audit.log")

	logger, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}

	args := json.RawMessage(`{"x": 100, "y": 200}`)
	logger.LogToolCall("click", args, "success", 150*time.Millisecond)

	if err := logger.Close(); err != nil {
		t.Fatalf("Close error = %v", err)
	}

	content, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("ReadFile error = %v", err)
	}

	var entry map[string]any
	if err := json.Unmarshal(content, &entry); err != nil {
		t.Fatalf("JSON unmarshal error = %v", err)
	}

	// Required fields per slog.JSONHandler output
	requiredFields := []string{
		"time",             // slog adds this automatically
		"level",            // slog adds this automatically
		"msg",              // the message ("tool_invocation")
		"tool",             // tool name
		"status",           // success/error
		"duration_seconds", // duration in seconds
		"timestamp",        // explicit timestamp we add
	}

	for _, field := range requiredFields {
		if _, exists := entry[field]; !exists {
			t.Errorf("Missing required field: %s\nEntry: %v", field, entry)
		}
	}

	// Verify specific field values
	if msg, ok := entry["msg"].(string); !ok || msg != "tool_invocation" {
		t.Errorf("Expected msg='tool_invocation', got %v", entry["msg"])
	}

	if tool, ok := entry["tool"].(string); !ok || tool != "click" {
		t.Errorf("Expected tool='click', got %v", entry["tool"])
	}

	if status, ok := entry["status"].(string); !ok || status != "success" {
		t.Errorf("Expected status='success', got %v", entry["status"])
	}

	// Verify duration is approximately correct (0.15 seconds)
	if dur, ok := entry["duration_seconds"].(float64); !ok || dur < 0.14 || dur > 0.16 {
		t.Errorf("Expected duration_seconds ~0.15, got %v", entry["duration_seconds"])
	}

	if _, exists := entry["arguments"]; exists {
		t.Errorf("forbidden arguments field present: %v", entry["arguments"])
	}
}

// TestAuditLogger_WriteAfterClose verifies behavior when writing after close.
func TestAuditLogger_WriteAfterClose(t *testing.T) {
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "write_after_close.log")

	logger, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}

	// Write before close
	args := json.RawMessage(`{"before": true}`)
	logger.LogToolCall("before", args, "success", 10*time.Millisecond)

	if err := logger.Close(); err != nil {
		t.Fatalf("Close error = %v", err)
	}

	// Write after close is an idempotent no-op.
	args2 := json.RawMessage(`{"after": true}`)
	if err := logger.LogToolCall("after", args2, "success", 10*time.Millisecond); err != nil {
		t.Fatalf("LogToolCall after close error = %v", err)
	}

	// Verify file exists and has the "before" entry
	content, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("ReadFile error = %v", err)
	}

	if !strings.Contains(string(content), "before") {
		t.Error("Log should contain 'before' entry")
	}
	if strings.Contains(string(content), `"tool":"after"`) {
		t.Error("Log contains entry written after Close")
	}
}

func TestAuditLogger_WriteFailureIsReturned(t *testing.T) {
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "failed_audit.log")

	logger, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}
	args := json.RawMessage(`{"first": true}`)
	if err := logger.LogToolCall("first", args, "success", 10*time.Millisecond); err != nil {
		t.Fatalf("initial LogToolCall error = %v", err)
	}
	if err := logger.file.Close(); err != nil {
		t.Fatalf("close underlying file: %v", err)
	}
	args2 := json.RawMessage(`{"second": true}`)
	if err := logger.LogToolCall("second", args2, "success", 10*time.Millisecond); err == nil {
		t.Fatal("LogToolCall swallowed underlying write failure")
	}
}

// TestAuditLogger_InvalidPath_PermissionDenied tests error handling for permission denied.
func TestAuditLogger_InvalidPath_PermissionDenied(t *testing.T) {
	// Skip on systems where we can't create restricted directories
	tmpDir := t.TempDir()
	restrictedDir := filepath.Join(tmpDir, "restricted")

	if err := os.Mkdir(restrictedDir, 0000); err != nil {
		t.Fatalf("Mkdir error = %v", err)
	}
	defer os.Chmod(restrictedDir, 0755) // Restore for cleanup

	logPath := filepath.Join(restrictedDir, "audit.log")
	_, err := NewAuditLogger(logPath)
	if err == nil {
		t.Error("Expected permission denied error")
	}
}

// TestAuditLogger_LargeArgumentsAreNeverPersisted proves the non-content policy
// does not degrade into size-limited or key-name-based redaction.
func TestAuditLogger_LargeArgumentsAreNeverPersisted(t *testing.T) {
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "large_args.log")

	logger, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}
	defer logger.Close()

	// Create a large argument with private data in both ordinary and
	// secret-looking fields. Neither class may enter the audit log.
	largeData := make(map[string]any)
	for i := range 100 {
		largeData[string(rune('a'+i%26))+string(rune('0'+i/26))] = i
	}
	largeData["deeply_nested_password"] = "super_secret_value"
	largeData["normal_field"] = strings.Repeat("x", 1000)

	argsBytes, _ := json.Marshal(largeData)
	logger.LogToolCall("large_tool", json.RawMessage(argsBytes), "success", 100*time.Millisecond)

	if err := logger.Close(); err != nil {
		t.Fatalf("Close error = %v", err)
	}

	content, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("ReadFile error = %v", err)
	}

	logStr := string(content)

	if strings.Contains(logStr, "super_secret_value") {
		t.Error("Log should NOT contain 'super_secret_value'")
	}
	if strings.Contains(logStr, strings.Repeat("x", 100)) {
		t.Error("Log should NOT contain ordinary argument content")
	}
	if strings.Contains(logStr, `"arguments"`) {
		t.Error("Log should NOT contain an arguments field")
	}
}

// TestAuditLogger_EmptyToolName tests handling of empty tool names.
func TestAuditLogger_EmptyToolName(t *testing.T) {
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "empty_tool.log")

	logger, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}
	defer logger.Close()

	// Empty tool name should still work
	args := json.RawMessage(`{}`)
	logger.LogToolCall("", args, "success", 10*time.Millisecond)

	if err := logger.Close(); err != nil {
		t.Fatalf("Close error = %v", err)
	}

	content, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("ReadFile error = %v", err)
	}

	var entry map[string]any
	if err := json.Unmarshal(content, &entry); err != nil {
		t.Fatalf("JSON unmarshal error = %v", err)
	}

	if entry["tool"] != "" {
		t.Errorf("Expected empty tool name, got %v", entry["tool"])
	}
}

// TestAuditLogger_SpecialCharactersInArguments tests JSON escaping of special characters.
func TestAuditLogger_SpecialCharactersInArguments(t *testing.T) {
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "special_chars.log")

	logger, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}

	// Arguments with special characters that need JSON escaping
	args := json.RawMessage(`{"text": "line1\nline2\ttab", "quote": "say \"hello\"", "unicode": "日本語"}`)
	logger.LogToolCall("special", args, "success", 10*time.Millisecond)

	if err := logger.Close(); err != nil {
		t.Fatalf("Close error = %v", err)
	}

	content, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("ReadFile error = %v", err)
	}

	// Should be valid JSON
	var entry map[string]any
	if err := json.Unmarshal(content, &entry); err != nil {
		t.Fatalf("JSON unmarshal error = %v\nContent: %s", err, content)
	}

	// Verify tool was logged
	if entry["tool"] != "special" {
		t.Errorf("Expected tool='special', got %v", entry["tool"])
	}
}

// TestAuditLogger_DurationEdgeCases tests logging with various duration values.
func TestAuditLogger_DurationEdgeCases(t *testing.T) {
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "duration_edge.log")

	logger, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}

	testCases := []struct {
		name     string
		duration time.Duration
	}{
		{"zero", 0},
		{"nanosecond", time.Nanosecond},
		{"microsecond", time.Microsecond},
		{"millisecond", time.Millisecond},
		{"second", time.Second},
		{"minute", time.Minute},
		{"large", 24 * time.Hour},
	}

	for _, tc := range testCases {
		args := json.RawMessage(`{}`)
		logger.LogToolCall(tc.name, args, "success", tc.duration)
	}

	if err := logger.Close(); err != nil {
		t.Fatalf("Close error = %v", err)
	}

	content, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("ReadFile error = %v", err)
	}

	lines := strings.Split(strings.TrimSpace(string(content)), "\n")
	if len(lines) != len(testCases) {
		t.Fatalf("Expected %d lines, got %d", len(testCases), len(lines))
	}

	for i, line := range lines {
		var entry map[string]any
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Errorf("Line %d (%s) is not valid JSON: %v", i+1, testCases[i].name, err)
			continue
		}

		dur, ok := entry["duration_seconds"].(float64)
		if !ok {
			t.Errorf("Line %d (%s): duration_seconds not a float64", i+1, testCases[i].name)
			continue
		}

		expectedDur := testCases[i].duration.Seconds()
		if dur != expectedDur {
			t.Errorf("Line %d (%s): expected duration_seconds=%v, got %v", i+1, testCases[i].name, expectedDur, dur)
		}
	}
}

// TestAuditLogger_StatusValues tests various status string values.
func TestAuditLogger_StatusValues(t *testing.T) {
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "status_values.log")

	logger, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}

	statuses := []string{"success", "error", "timeout", "cancelled", "", "UNKNOWN", "partial_success"}

	for _, status := range statuses {
		args := json.RawMessage(`{}`)
		logger.LogToolCall("status_test", args, status, 10*time.Millisecond)
	}

	if err := logger.Close(); err != nil {
		t.Fatalf("Close error = %v", err)
	}

	content, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("ReadFile error = %v", err)
	}

	lines := strings.Split(strings.TrimSpace(string(content)), "\n")
	if len(lines) != len(statuses) {
		t.Fatalf("Expected %d lines, got %d", len(statuses), len(lines))
	}

	for i, line := range lines {
		var entry map[string]any
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Errorf("Line %d is not valid JSON: %v", i+1, err)
			continue
		}

		if entry["status"] != statuses[i] {
			t.Errorf("Line %d: expected status=%q, got %v", i+1, statuses[i], entry["status"])
		}
	}
}

// TestAuditLogger_FileAppendBehavior verifies that logs are appended, not overwritten.
func TestAuditLogger_FileAppendBehavior(t *testing.T) {
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "append_test.log")

	// First logger session
	logger1, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger (1) error = %v", err)
	}

	args := json.RawMessage(`{}`)
	logger1.LogToolCall("session1", args, "success", 10*time.Millisecond)

	if err := logger1.Close(); err != nil {
		t.Fatalf("Close (1) error = %v", err)
	}

	// Second logger session
	logger2, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger (2) error = %v", err)
	}

	logger2.LogToolCall("session2", args, "success", 10*time.Millisecond)

	if err := logger2.Close(); err != nil {
		t.Fatalf("Close (2) error = %v", err)
	}

	// Verify both entries exist
	content, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("ReadFile error = %v", err)
	}

	lines := strings.Split(strings.TrimSpace(string(content)), "\n")
	if len(lines) != 2 {
		t.Fatalf("Expected 2 lines (append behavior), got %d", len(lines))
	}

	if !strings.Contains(lines[0], "session1") {
		t.Error("First line should contain 'session1'")
	}
	if !strings.Contains(lines[1], "session2") {
		t.Error("Second line should contain 'session2'")
	}
}
