// Copyright 2025 Joseph Cumines
//
// Audit logging for MCP tool invocations

package server

import (
	"encoding/json"
	"fmt"
	"os"
	"sync"
	"time"
)

// AuditLogger provides structured audit logging for tool invocations.
// It logs only non-content metadata: tool name, result status, and duration.
type AuditLogger struct {
	file    *os.File
	enabled bool
	mu      sync.RWMutex
}

type auditEntry struct {
	Time            time.Time `json:"time"`
	Timestamp       time.Time `json:"timestamp"`
	Level           string    `json:"level"`
	Message         string    `json:"msg"`
	Tool            string    `json:"tool"`
	Status          string    `json:"status"`
	DurationSeconds float64   `json:"duration_seconds"`
}

// NewAuditLogger creates a new audit logger that writes to the specified file.
// If filePath is empty, audit logging is disabled. Returns an error if the
// path is not an owner-private, singly linked regular file.
func NewAuditLogger(filePath string) (*AuditLogger, error) {
	if filePath == "" {
		return &AuditLogger{enabled: false}, nil
	}

	file, err := openAuditFile(filePath)
	if err != nil {
		return nil, err
	}

	return &AuditLogger{
		file:    file,
		enabled: true,
	}, nil
}

// Close closes the audit log file if it is open.
// Safe to call multiple times. Returns any error from closing the file.
func (a *AuditLogger) Close() error {
	a.mu.Lock()
	defer a.mu.Unlock()

	if a.file != nil {
		err := a.file.Close()
		a.file = nil
		a.enabled = false
		return err
	}
	return nil
}

// IsEnabled returns true if audit logging is enabled (file path was provided).
func (a *AuditLogger) IsEnabled() bool {
	if a == nil {
		return false
	}
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.enabled
}

// LogToolCall logs only non-content invocation metadata. Arguments are accepted
// for call-site compatibility but are deliberately never parsed or persisted.
func (a *AuditLogger) LogToolCall(tool string, _ json.RawMessage, status string, duration time.Duration) error {
	if a == nil {
		return nil
	}

	a.mu.Lock()
	defer a.mu.Unlock()
	if !a.enabled || a.file == nil {
		return nil
	}

	now := time.Now().UTC()
	if err := json.NewEncoder(a.file).Encode(auditEntry{
		Time:            now,
		Level:           "INFO",
		Message:         "tool_invocation",
		Tool:            tool,
		Status:          status,
		DurationSeconds: duration.Seconds(),
		Timestamp:       now,
	}); err != nil {
		return fmt.Errorf("write audit metadata: %w", err)
	}
	return nil
}
