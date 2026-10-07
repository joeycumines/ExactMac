//go:build windows

package server

import (
	"fmt"
	"os"
)

func openAuditFile(filePath string) (*os.File, error) {
	// Open with standard secure permissions on Windows
	file, err := os.OpenFile(filePath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return nil, fmt.Errorf("open audit log %q: %w", filePath, err)
	}
	stat, err := file.Stat()
	if err != nil {
		_ = file.Close()
		return nil, fmt.Errorf("inspect audit log %q: %w", filePath, err)
	}
	if !stat.Mode().IsRegular() {
		_ = file.Close()
		return nil, fmt.Errorf("audit log %q is not a regular file", filePath)
	}
	return file, nil
}
