package server

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
)

// The peer a gRPC connection arrives from is identified by the kernel from the socket NAME
// the caller bound before connecting. That name is the only per-connection value a gRPC
// server can correlate an RPC with, and it is a kernel-attested fact about the caller rather
// than something the caller can claim, because `bind(2)` on a Unix pathname is exclusive
// among live sockets: to present a name, a process must BE the socket the kernel bound to
// it. A client that connects without binding one is unattributable, and the server refuses
// every capability on such a connection.
//
// So this client binds one. The name lives beside the server's socket so the two agree on
// one place rather than inventing separate ones, carries nothing about the caller beyond a
// random suffix, and is removed when the connection closes. A process that dies without
// closing leaves an empty node behind: nothing is listening on it, it is in the operator's
// own cache directory, and the next connection uses a different random name, so nothing
// ever trusts it.

// peerIdentityDialer dials Unix-socket servers through a socket this process has named.
//
// A TYPE rather than a bare dial function because the name has to survive from the moment
// the socket is created to the moment the connection closes.
type peerIdentityDialer struct {
	fallback *net.Dialer
	// directory holds the caller's own socket names: the directory holding the server's
	// socket.
	directory string
}

func newPeerIdentityDialer(serverSocketPath string) (*peerIdentityDialer, error) {
	directory := filepath.Dir(serverSocketPath)
	info, err := os.Lstat(directory)
	if err != nil {
		return nil, fmt.Errorf("stat the directory holding the server socket: %w", err)
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("the server socket's directory is not a directory: %q", directory)
	}
	return &peerIdentityDialer{
		fallback:  &net.Dialer{},
		directory: directory,
	}, nil
}

// dial is the shape gRPC's context dialer takes, which is an address and not a network.
//
// A PATH is the Unix case and the only one this dialer can name; anything else is TCP, and
// a TCP server has no authenticating principal at all, so there is nothing to name and
// nothing this dialer could add. The server's reduced posture denies every
// consent-requiring capability on that listener regardless.
func (d *peerIdentityDialer) dial(ctx context.Context, address string) (net.Conn, error) {
	if !strings.HasPrefix(address, "/") {
		return d.fallback.DialContext(ctx, "tcp", address)
	}

	// `Control` runs after the runtime has created the socket and before it connects, which
	// is the one moment this process owns an unconnected socket that can still be named.
	// It runs on the calling goroutine, so the name it writes is visible once
	// `DialContext` returns.
	var name string
	dialer := *d.fallback
	dialer.Control = func(_, _ string, raw syscall.RawConn) error {
		reserved, err := d.reserveName()
		if err != nil {
			return err
		}
		var bindErr error
		if err := raw.Control(func(fd uintptr) {
			bindErr = bindUnixSocketName(int(fd), reserved)
		}); err != nil {
			d.remove(reserved)
			return err
		}
		if bindErr != nil {
			d.remove(reserved)
			return bindErr
		}
		name = reserved
		return nil
	}

	connection, err := dialer.DialContext(ctx, "unix", address)
	if err != nil {
		if name != "" {
			// The name was created before the connect was attempted, so it has to go when
			// the connect fails. Leaving it would accumulate dead nodes for a failure that
			// is about to be reported and retried.
			d.remove(name)
		}
		return nil, err
	}
	if name == "" {
		// Unreachable unless the runtime skipped the control hook, and a connection the
		// server cannot identify is a connection that can do nothing, so it is closed
		// rather than handed on as a mystery.
		_ = connection.Close()
		return nil, fmt.Errorf("the client socket was created without a name, so the server cannot identify this caller")
	}
	return &namedConn{Conn: connection, name: name, remove: d.remove}, nil
}

// reserveName picks a name nothing else can be holding, because binding is exclusive: a
// collision is not a correctness problem, it is a retry.
func (d *peerIdentityDialer) reserveName() (string, error) {
	for attempt := 0; attempt < 8; attempt++ {
		suffix := make([]byte, 8)
		if _, err := rand.Read(suffix); err != nil {
			return "", fmt.Errorf("generate a client socket name: %w", err)
		}
		name := filepath.Join(d.directory, "emc-"+hex.EncodeToString(suffix)+".sock")
		// `sun_path` is 104 bytes on Darwin, and a name that does not fit addresses a
		// DIFFERENT socket rather than failing, which is why the shipped server socket lives
		// in ~/Library/Caches: it leaves room for a client name beside it.
		if len(name) >= 104 {
			return "", fmt.Errorf(
				"the server socket's directory leaves no room for a client socket name: %q is %d bytes",
				name, len(name),
			)
		}
		return name, nil
	}
	return "", fmt.Errorf("could not find an unused client socket name")
}

func (d *peerIdentityDialer) remove(name string) {
	_ = os.Remove(name)
}

// namedConn removes its socket's name when the connection closes, because the name is what
// makes this process identifiable and a name left on a dead socket is a name a later process
// could be handed.
type namedConn struct {
	net.Conn
	name   string
	remove func(string)
	once   sync.Once
}

func (c *namedConn) Close() error {
	c.once.Do(func() { c.remove(c.name) })
	return c.Conn.Close()
}

// bindUnixSocketName gives a not-yet-connected socket a pathname of its own.
//
// THE BIND, NOT A CLAIM. Once this returns, the kernel records the name against this exact
// socket and refuses to record it against another while this one lives, which is what makes
// the name usable as the server's correlation key.
func bindUnixSocketName(fd int, name string) error {
	address, err := unixSocketAddress(name)
	if err != nil {
		return err
	}
	if err := syscall.Bind(fd, address); err != nil {
		return fmt.Errorf("bind the client socket to %q: %w", name, err)
	}
	// 0600, because the caller's own socket is as much a boundary as the server's: a node
	// anybody can connect to is a name this process cannot be confident it still owns.
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
