package server

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net"
	"os"
	"path/filepath"
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

// peerIdentityDialer dials one Unix-socket server through a socket this process has named.
//
// IT IS UNIX-ONLY AND KNOWS ITS OWN ENDPOINT, and both are consequences of a measured
// failure. The first version decided the network from the address string gRPC handed it,
// falling back to TCP for anything not starting with "/". gRPC does not pass a bare path to
// a custom context dialer — it passes a string that begins with the network, so the check
// never matched, the TCP branch ran, and the dial resolved the socket path as a HOSTNAME.
// The symptom was `dial tcp: lookup tcp////Users/.../exactmac.sock: unknown port` on a
// socket that was present, connectable, and serving. A dialer built for one configured
// endpoint has no reason to guess at the network, and guessing here made a working server
// look unreachable.
//
// A TYPE rather than a bare dial function because the name has to survive from the moment
// the socket is created to the moment the connection closes.
type peerIdentityDialer struct {
	fallback *net.Dialer
	// socketPath is the server's endpoint. Held rather than read from the dial argument,
	// because the dial argument is not the path.
	socketPath string
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
		fallback:   &net.Dialer{},
		socketPath: serverSocketPath,
		directory:  directory,
	}, nil
}

// dial is the shape gRPC's context dialer takes: an address and not a network.
//
// THE ADDRESS IS IGNORED, deliberately. gRPC passes a string that begins with the network
// rather than the bare socket path, so the first version's check for a leading "/" never
// matched, its TCP branch ran, and the dial resolved the socket path as a HOSTNAME. The
// symptom was `dial tcp: lookup tcp////Users/.../exactmac.sock: unknown port` against a
// socket that was present, connectable and serving. This dialer is only ever installed for a
// configured Unix socket — `grpcClientDialOptions` does not install it otherwise — so the
// network is already known and the path is held rather than guessed at.
func (d *peerIdentityDialer) dial(ctx context.Context, _ string) (net.Conn, error) {
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

	connection, err := dialer.DialContext(ctx, "unix", d.socketPath)
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
	return &namedConn{
		Conn:   connection,
		forget: func() { d.remove(name) },
	}, nil
}

// reserveName picks a name this socket can take. A name that is already in use is not a
// correctness problem — the bind fails with EADDRINUSE and the dial fails, which is what
// should happen when another process holds a name — so there is nothing to retry here.
func (d *peerIdentityDialer) reserveName() (string, error) {
	suffix := make([]byte, 8)
	if _, err := rand.Read(suffix); err != nil {
		return "", fmt.Errorf("generate a client socket name: %w", err)
	}
	name := filepath.Join(d.directory, "emc-"+hex.EncodeToString(suffix)+".sock")
	// `sun_path` is 104 bytes on Darwin, and a name that does not fit addresses a DIFFERENT
	// socket rather than failing, which is why the shipped server socket lives in
	// ~/Library/Caches: it leaves room for a client name beside it.
	if len(name) >= 104 {
		return "", fmt.Errorf(
			"the server socket's directory leaves no room for a client socket name: %q is %d bytes",
			name, len(name),
		)
	}
	return name, nil
}

func (d *peerIdentityDialer) remove(name string) {
	_ = os.Remove(name)
}

// namedConn removes its socket's name when the connection closes, because the name is what
// makes this process identifiable and a name left on a dead socket is a name a later process
// could be handed.
//
// CLOSE FIRST, THEN REMOVE, and the order is load-bearing. The exclusivity the whole scheme
// rests on belongs to the SOCKET, not to the directory entry: the kernel keeps refusing to
// bind the name to a second socket while this one lives, but it stops the instant this
// process unlinks the entry while the socket is still open. Removing first therefore lets a
// second socket take the name and connect while this connection is still live, and the
// server would then see two live connections presenting one token and attribute the first's
// calls to the second's identity. A blocking connect is not an option either — the token has
// to disappear before Close returns, and the socket has to be closed first for that to hold.
// forget removes THIS connection's socket name, once and only once. It is a closure rather
// than a stored name and a remover because the name has no other reader, and the struct
// carries one pointer-bearing field fewer for it.
type namedConn struct {
	// ORDERED FOR GC SCAN WORK, NOT FOR READING. The pointer-bearing fields are adjacent and
	// the pointer-free one trails, which is what `go.betteralign` measures; reordering this
	// is a lint failure, so do not "tidy" it.
	forget func()
	net.Conn
	once sync.Once
}

func (c *namedConn) Close() error {
	err := c.Conn.Close()
	c.once.Do(c.forget)
	return err
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
