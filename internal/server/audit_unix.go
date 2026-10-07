//go:build !windows

package server

import (
	"fmt"
	"os"

	"golang.org/x/sys/unix"
)

func openAuditFile(filePath string) (*os.File, error) {
	flags := unix.O_APPEND | unix.O_CLOEXEC | unix.O_CREAT | unix.O_NOFOLLOW | unix.O_NONBLOCK | unix.O_WRONLY
	fd, err := unix.Open(filePath, flags, 0600)
	if err != nil {
		return nil, fmt.Errorf("open audit log %q: %w", filePath, err)
	}
	file := os.NewFile(uintptr(fd), filePath)
	if file == nil {
		_ = unix.Close(fd)
		return nil, fmt.Errorf("open audit log %q: invalid file descriptor", filePath)
	}

	var stat unix.Stat_t
	if err := unix.Fstat(fd, &stat); err != nil {
		_ = file.Close()
		return nil, fmt.Errorf("inspect audit log %q: %w", filePath, err)
	}
	if stat.Mode&unix.S_IFMT != unix.S_IFREG {
		_ = file.Close()
		return nil, fmt.Errorf("audit log %q is not a regular file", filePath)
	}
	if stat.Nlink != 1 {
		_ = file.Close()
		return nil, fmt.Errorf("audit log %q has %d hard links; want exactly one", filePath, stat.Nlink)
	}
	if stat.Uid != uint32(os.Geteuid()) {
		_ = file.Close()
		return nil, fmt.Errorf("audit log %q is owned by uid %d; want %d", filePath, stat.Uid, os.Geteuid())
	}
	if permissions := os.FileMode(stat.Mode & 0777); permissions != 0600 {
		_ = file.Close()
		return nil, fmt.Errorf("audit log %q permissions are %#o; want 0600", filePath, permissions)
	}

	return file, nil
}
