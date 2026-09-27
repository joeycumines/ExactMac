package server

import (
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// A dialer that cannot name its own socket produces a connection the server cannot
// attribute, and an unattributable connection is refused every capability. These tests are
// therefore about the client half of the identity chain, and they are negative-controlled:
// the same socket is inspected twice, once as the server would see it and once as an
// unattributed peer, so a change that quietly stopped naming the socket fails here rather
// than at the first real prompt.

// shortDirectory keeps the client socket name inside `sun_path`, which is 104 bytes on
// Darwin. A name that does not fit addresses a different socket rather than failing.
func shortDirectory(t *testing.T) string {
	t.Helper()
	directory, err := os.MkdirTemp("", "emc-c")
	if err != nil {
		t.Fatalf("create a short temporary directory: %v", err)
	}
	// The name has to be short in absolute terms, and TMPDIR on this machine is long
	// enough to matter, so the directory is replaced by one under the working tree's own
	// short temp when the system one does not leave room.
	if len(directory)+len("/emc-0123456789abcdef.sock") >= 104 {
		alternative := filepath.Join(os.TempDir(), "emc-t")
		if err := os.MkdirAll(alternative, 0o700); err != nil {
			t.Fatalf("create the fallback directory: %v", err)
		}
		directory = alternative
	}
	t.Cleanup(func() { _ = os.RemoveAll(directory) })
	return directory
}

func TestPeerIdentityDialerNamesItsOwnSocket(t *testing.T) {
	directory := shortDirectory(t)
	serverPath := filepath.Join(directory, "s.sock")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: serverPath, Net: "unix"})
	if err != nil {
		t.Fatalf("listen on the test server socket: %v", err)
	}
	defer func() { _ = listener.Close() }()

	identity, err := newPeerIdentityDialer(serverPath)
	if err != nil {
		t.Fatalf("build the peer identity dialer: %v", err)
	}
	connection, err := identity.dial(context.Background(), serverPath)
	if err != nil {
		t.Fatalf("dial the test server: %v", err)
	}
	defer func() { _ = connection.Close() }()

	local, ok := connection.LocalAddr().(*net.UnixAddr)
	if !ok {
		t.Fatalf("the client connection is %T, not a Unix address", connection.LocalAddr())
	}
	if local.Name == serverPath {
		t.Fatal("the client socket took the server's name, which bind(2) does not permit")
	}
	if len(local.Name) >= 104 {
		t.Fatalf("the client socket name is %d bytes, which does not fit in sun_path", len(local.Name))
	}
	info, err := os.Lstat(local.Name)
	if err != nil {
		t.Fatalf("the named client socket does not exist: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("the client socket is mode %#o, want 0600", info.Mode().Perm())
	}
}

// The name is not decoration: it is what the kernel reports for this connection, and the
// server correlates the RPC to the caller through it. Asserted through the kernel's own
// answer rather than through the client's own bookkeeping, so a client that believed it had
// named the socket without having done so would fail here.
func TestNamedClientSocketIsWhatTheKernelReports(t *testing.T) {
	directory := shortDirectory(t)
	serverPath := filepath.Join(directory, "s.sock")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: serverPath, Net: "unix"})
	if err != nil {
		t.Fatalf("listen on the test server socket: %v", err)
	}
	defer func() { _ = listener.Close() }()

	identity, err := newPeerIdentityDialer(serverPath)
	if err != nil {
		t.Fatalf("build the peer identity dialer: %v", err)
	}
	connection, err := identity.dial(context.Background(), serverPath)
	if err != nil {
		t.Fatalf("dial the test server: %v", err)
	}
	defer func() { _ = connection.Close() }()
	client, ok := connection.LocalAddr().(*net.UnixAddr)
	if !ok {
		t.Fatalf("the client connection is %T, not a Unix address", connection.LocalAddr())
	}

	accepted := make(chan *net.UnixConn, 1)
	go func() {
		serverSide, acceptErr := listener.AcceptUnix()
		if acceptErr == nil {
			accepted <- serverSide
		}
	}()
	var serverSide *net.UnixConn
	select {
	case serverSide = <-accepted:
	case <-time.After(10 * time.Second):
		t.Fatal("the server never accepted the connection")
	}
	defer func() { _ = serverSide.Close() }()

	peer, err := serverSide.SyscallConn()
	if err != nil {
		t.Fatalf("read the accepted socket's peer credentials: %v", err)
	}
	var peerCredentials struct {
		Pid int32
		Uid uint32
	}
	var credentialErr error
	if err := peer.Control(func(fd uintptr) {
		credentialErr = localPeerCredentials(int(fd), &peerCredentials.Pid, &peerCredentials.Uid)
	}); err != nil {
		t.Fatalf("control the accepted socket: %v", err)
	}
	if credentialErr != nil {
		t.Fatalf("read LOCAL_PEERPID and LOCAL_PEERCRED: %v", credentialErr)
	}
	if int(peerCredentials.Pid) != os.Getpid() {
		t.Fatalf("the kernel named pid %d, want this process %d", peerCredentials.Pid, os.Getpid())
	}
	if peerCredentials.Uid != uint32(os.Geteuid()) {
		t.Fatalf("the kernel named uid %d, want %d", peerCredentials.Uid, os.Geteuid())
	}

	peerName, err := peerSocketName(serverSide)
	if err != nil {
		t.Fatalf("read the accepted socket's peer name: %v", err)
	}
	if peerName != client.Name {
		t.Fatalf("the kernel reports peer name %q, want the client's own %q", peerName, client.Name)
	}
}

func TestClosingTheConnectionRemovesItsName(t *testing.T) {
	directory := shortDirectory(t)
	serverPath := filepath.Join(directory, "s.sock")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: serverPath, Net: "unix"})
	if err != nil {
		t.Fatalf("listen on the test server socket: %v", err)
	}
	defer func() { _ = listener.Close() }()

	identity, err := newPeerIdentityDialer(serverPath)
	if err != nil {
		t.Fatalf("build the peer identity dialer: %v", err)
	}
	connection, err := identity.dial(context.Background(), serverPath)
	if err != nil {
		t.Fatalf("dial the test server: %v", err)
	}
	local, ok := connection.LocalAddr().(*net.UnixAddr)
	if !ok {
		t.Fatalf("the client connection is %T, not a Unix address", connection.LocalAddr())
	}
	name := local.Name

	if err := connection.Close(); err != nil {
		t.Fatalf("close the client connection: %v", err)
	}
	if _, err := os.Lstat(name); !os.IsNotExist(err) {
		t.Fatalf("the client socket name survived the connection: %v", err)
	}
	// Closing twice is a normal thing for a caller to do and must not remove a name a
	// LATER connection now owns.
	other, err := identity.dial(context.Background(), serverPath)
	if err != nil {
		t.Fatalf("dial the test server a second time: %v", err)
	}
	defer func() { _ = other.Close() }()
	otherLocal, ok := other.LocalAddr().(*net.UnixAddr)
	if !ok {
		t.Fatalf("the second client connection is %T, not a Unix address", other.LocalAddr())
	}
	if otherLocal.Name == name {
		t.Fatal("two live connections shared one socket name, which bind(2) does not permit")
	}
	if err := connection.Close(); err != nil && !errors.Is(err, net.ErrClosed) {
		t.Fatalf("the second close reported an unexpected error: %v", err)
	}
	if _, err := os.Lstat(otherLocal.Name); err != nil {
		t.Fatalf("closing an already-closed connection removed a live connection's name: %v", err)
	}
}

func TestATCPAddressIsDialledWithoutNaming(t *testing.T) {
	directory := shortDirectory(t)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen on the test TCP server: %v", err)
	}
	defer func() { _ = listener.Close() }()

	identity, err := newPeerIdentityDialer(filepath.Join(directory, "s.sock"))
	if err != nil {
		t.Fatalf("build the peer identity dialer: %v", err)
	}
	connection, err := identity.dial(context.Background(), listener.Addr().String())
	if err != nil {
		t.Fatalf("dial the test TCP server: %v", err)
	}
	defer func() { _ = connection.Close() }()
	if _, ok := connection.LocalAddr().(*net.TCPAddr); !ok {
		t.Fatalf("a TCP address produced %T, which this dialer must not name", connection.LocalAddr())
	}
	entries, err := os.ReadDir(directory)
	if err != nil {
		t.Fatalf("read the socket directory: %v", err)
	}
	for _, entry := range entries {
		if filepath.Ext(entry.Name()) == ".sock" {
			t.Fatalf("a TCP dial created the socket name %q", entry.Name())
		}
	}
}

func TestAClientSocketNameIsRefusedWhenItCannotFit(t *testing.T) {
	directory := "/tmp/" + strings.Repeat("d", 120)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Skipf("cannot create the long directory: %v", err)
	}
	defer func() { _ = os.RemoveAll(directory) }()
	identity, err := newPeerIdentityDialer(directory + "/s.sock")
	if err != nil {
		t.Fatalf("build the peer identity dialer: %v", err)
	}
	if _, err := identity.reserveName(); err == nil {
		t.Fatal("a name that cannot fit in sun_path was accepted, and it would address another socket")
	}
}

// localPeerCredentials reads the kernel's answer about the process on the other end of an
// accepted socket: the pid from LOCAL_PEERPID and the effective uid from LOCAL_PEERCRED.
// The same two options the server reads, through the same descriptors, so a test that
// disagreed with the server about them would be a test of a fiction.
func localPeerCredentials(fd int, pid *int32, uid *uint32) error {
	processIdentifier, err := unix.GetsockoptInt(fd, unix.SOL_LOCAL, unix.LOCAL_PEERPID)
	if err != nil {
		return err
	}
	credentials, err := unix.GetsockoptXucred(fd, unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
	if err != nil {
		return err
	}
	*pid = int32(processIdentifier)
	*uid = credentials.Uid
	return nil
}

// peerSocketName is the pathname the peer bound before connecting, which is the value the
// server correlates an RPC with.
func peerSocketName(connection *net.UnixConn) (string, error) {
	raw, err := connection.SyscallConn()
	if err != nil {
		return "", err
	}
	var name string
	var readErr error
	if err := raw.Control(func(fd uintptr) {
		address, nameErr := unix.Getpeername(int(fd))
		if nameErr != nil {
			readErr = nameErr
			return
		}
		unixAddress, ok := address.(*unix.SockaddrUnix)
		if !ok {
			readErr = errors.New("the accepted socket's peer is not a Unix address")
			return
		}
		name = unixAddress.Name
	}); err != nil {
		return "", err
	}
	if readErr != nil {
		return "", readErr
	}
	return name, nil
}
