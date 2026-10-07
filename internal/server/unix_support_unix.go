//go:build !windows

package server

import (
	"fmt"
	"os"
	"sync"
	"syscall"
)

var bindUmaskMu sync.Mutex

func checkUnixSocketOwnershipAndPermissions(info os.FileInfo, path string) error {
	if info.Mode().Perm() != 0600 {
		return fmt.Errorf("unix socket path must have mode 0600: %q has %04o", path, info.Mode().Perm())
	}
	status, ok := info.Sys().(*syscall.Stat_t)
	if !ok || status.Uid != uint32(os.Geteuid()) {
		return fmt.Errorf("unix socket path is not owned by the current user: %q", path)
	}
	return nil
}

func checkDirectoryOwnership(info os.FileInfo, directory string) error {
	if status, ok := info.Sys().(*syscall.Stat_t); ok {
		if status.Uid != uint32(os.Geteuid()) {
			return fmt.Errorf("the server socket's directory is not owned by the current user: %q", directory)
		}
	}
	return nil
}

func bindUnixSocketName(fd int, name string) error {
	address, err := unixSocketAddress(name)
	if err != nil {
		return err
	}
	bindUmaskMu.Lock()
	oldMask := syscall.Umask(0o077)
	bindErr := syscall.Bind(fd, address)
	syscall.Umask(oldMask)
	bindUmaskMu.Unlock()
	if bindErr != nil {
		return fmt.Errorf("bind the client socket to %q: %w", name, bindErr)
	}
	if err := syscall.Chmod(name, 0o600); err != nil {
		return fmt.Errorf("restrict the client socket %q: %w", name, err)
	}
	return nil
}

func unixSocketAddress(name string) (*syscall.SockaddrUnix, error) {
	if len(name) >= 104 {
		return nil, fmt.Errorf("the client socket name is too long: %q is %d bytes", name, len(name))
	}
	return &syscall.SockaddrUnix{Name: name}, nil
}
