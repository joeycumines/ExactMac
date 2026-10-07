//go:build !windows

package transport

import (
	"errors"
	"fmt"
	"net"
	"os"

	"golang.org/x/sys/unix"
)

func (t *HTTPTransport) listenUnixSocket() (net.Listener, error) {
	path := t.config.SocketPath
	var existing unix.Stat_t
	if err := unix.Lstat(path, &existing); err == nil {
		return nil, fmt.Errorf("refusing Unix socket path %q: path already exists", path)
	} else if !errors.Is(err, unix.ENOENT) {
		return nil, fmt.Errorf("inspect Unix socket path %q: %w", path, err)
	}

	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		return nil, fmt.Errorf("failed to listen on socket %s: %w", path, err)
	}
	// Go otherwise unlinks the configured pathname blindly when the listener
	// closes, which can delete a file swapped into place after bind.
	listener.SetUnlinkOnClose(false)

	identity, _, err := inspectUnixSocketPath(path)
	if err != nil {
		_ = listener.Close()
		return nil, fmt.Errorf("inspect created Unix socket %q: %w", path, err)
	}
	if err := chmodUnixSocketPath(path, 0600); err != nil {
		_ = listener.Close()
		_ = removeUnixSocketIfIdentity(path, identity)
		return nil, fmt.Errorf("set Unix socket %q owner-private: %w", path, err)
	}
	verified, permissions, err := inspectUnixSocketPath(path)
	if err != nil || verified != identity {
		_ = listener.Close()
		return nil, fmt.Errorf("unix socket path %q changed during admission", path)
	}
	if permissions != 0600 {
		_ = listener.Close()
		_ = removeUnixSocketIfIdentity(path, identity)
		return nil, fmt.Errorf("unix socket %q permissions are %#o; want 0600", path, permissions)
	}

	t.socketMu.Lock()
	t.socketIdentity = identity
	t.socketOwned = true
	t.socketMu.Unlock()
	return listener, nil
}

func chmodUnixSocketPath(path string, mode uint32) error {
	// Darwin rejects fchmod(2) on an AF_UNIX listener descriptor with EINVAL.
	// Operate on the bound pathname without following a replacement symlink,
	// then verify the socket identity again before admitting the listener.
	return unix.Fchmodat(unix.AT_FDCWD, path, mode, unix.AT_SYMLINK_NOFOLLOW)
}

func inspectUnixSocketPath(path string) (unixSocketIdentity, os.FileMode, error) {
	var stat unix.Stat_t
	if err := unix.Lstat(path, &stat); err != nil {
		return unixSocketIdentity{}, 0, err
	}
	if stat.Mode&unix.S_IFMT != unix.S_IFSOCK {
		return unixSocketIdentity{}, 0, fmt.Errorf("path is not a socket")
	}
	if stat.Uid != uint32(os.Geteuid()) {
		return unixSocketIdentity{}, 0, fmt.Errorf("socket is owned by uid %d; want %d", stat.Uid, os.Geteuid())
	}
	if stat.Nlink != 1 {
		return unixSocketIdentity{}, 0, fmt.Errorf("socket has %d links; want exactly one", stat.Nlink)
	}
	return unixSocketIdentity{
		device: uint64(stat.Dev),
		inode:  uint64(stat.Ino),
	}, os.FileMode(stat.Mode & 0777), nil
}

func removeUnixSocketIfIdentity(path string, expected unixSocketIdentity) error {
	actual, _, err := inspectUnixSocketPath(path)
	if errors.Is(err, unix.ENOENT) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("unix socket path changed; refusing removal: %w", err)
	}
	if actual != expected {
		return fmt.Errorf("unix socket path changed; refusing removal")
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("remove Unix socket %q: %w", path, err)
	}
	return nil
}
