//go:build !windows

package server

import (
	"path/filepath"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func TestNewAuditLogger_RejectsFIFOWithoutBlocking(t *testing.T) {
	logPath := filepath.Join(t.TempDir(), "audit.fifo")
	if err := unix.Mkfifo(logPath, 0600); err != nil {
		t.Fatalf("create FIFO: %v", err)
	}
	type openResult struct {
		logger *AuditLogger
		err    error
	}
	result := make(chan openResult, 1)
	go func() {
		logger, err := NewAuditLogger(logPath)
		result <- openResult{logger: logger, err: err}
	}()

	select {
	case opened := <-result:
		if opened.logger != nil {
			_ = opened.logger.Close()
		}
		if opened.err == nil {
			t.Fatal("NewAuditLogger accepted FIFO")
		}
	case <-time.After(250 * time.Millisecond):
		// Unblock an implementation that accidentally used a blocking writer
		// open so the test cannot leak its diagnostic goroutine.
		readerFD, readerErr := unix.Open(logPath, unix.O_NONBLOCK|unix.O_RDONLY, 0)
		if readerErr == nil {
			defer unix.Close(readerFD)
		}
		select {
		case opened := <-result:
			if opened.logger != nil {
				_ = opened.logger.Close()
			}
		case <-time.After(time.Second):
		}
		t.Fatal("NewAuditLogger blocked while opening FIFO")
	}
}
