package integration

import (
	"bytes"
	"context"
	"fmt"
	"maps"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
	"time"

	"github.com/joeycumines/ExactMac/internal/integrationfixture"
)

const swiftServerLifecycleTimeout = 5 * time.Second

func TestSwiftServerLifecycle_FatalBindExitsNonzero(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("occupy TCP address: %v", err)
	}
	defer listener.Close()
	port := listener.Addr().(*net.TCPAddr).Port

	cmd, logs := startSwiftLifecycleProcess(t, map[string]string{
		"GRPC_LISTEN_ADDRESS": "127.0.0.1",
		"GRPC_PORT":           strconv.Itoa(port),
		"GRPC_UNIX_SOCKET":    "",
	})
	waitErr, forced := integrationfixture.WaitChild(cmd, swiftServerLifecycleTimeout)
	if forced {
		t.Fatalf("server stayed alive after fatal bind failure; logs=%q", logs.String())
	}
	if waitErr == nil || cmd.ProcessState == nil || cmd.ProcessState.Success() {
		t.Fatalf("fatal bind exit=%v state=%v, want prompt nonzero; logs=%q", waitErr, cmd.ProcessState, logs.String())
	}
}

func TestSwiftServerLifecycle_PreexistingUnixPathIsPreserved(t *testing.T) {
	socketPath := filepath.Join(t.TempDir(), "server.sock")
	marker := []byte("do-not-delete")
	if err := os.WriteFile(socketPath, marker, 0o600); err != nil {
		t.Fatalf("create pre-existing path: %v", err)
	}
	before, err := os.Lstat(socketPath)
	if err != nil {
		t.Fatalf("lstat pre-existing path: %v", err)
	}

	cmd, logs := startSwiftLifecycleProcess(t, map[string]string{
		"GRPC_UNIX_SOCKET": socketPath,
	})
	waitErr, forced := integrationfixture.WaitChild(cmd, swiftServerLifecycleTimeout)
	if forced {
		t.Errorf("server stayed alive after destructive Unix-path admission; logs=%q", logs.String())
	}
	if waitErr == nil || cmd.ProcessState == nil || cmd.ProcessState.Success() {
		t.Errorf("pre-existing Unix path exit=%v state=%v, want prompt nonzero; logs=%q", waitErr, cmd.ProcessState, logs.String())
	}

	after, err := os.Lstat(socketPath)
	if err != nil {
		t.Fatalf("pre-existing path was removed: %v; logs=%q", err, logs.String())
	}
	contents, err := os.ReadFile(socketPath)
	if err != nil {
		t.Fatalf("pre-existing path is no longer a regular file: %v; logs=%q", err, logs.String())
	}
	if !os.SameFile(before, after) || !bytes.Equal(contents, marker) {
		t.Fatalf("pre-existing path changed: before=%v after=%v contents=%q; logs=%q", before, after, contents, logs.String())
	}
}

func TestSwiftServerLifecycle_PreexistingUnixDirectoryAndSymlinkArePreserved(t *testing.T) {
	t.Run("directory", func(t *testing.T) {
		root := t.TempDir()
		socketPath := filepath.Join(root, "server.sock")
		if err := os.Mkdir(socketPath, 0o700); err != nil {
			t.Fatalf("create pre-existing directory: %v", err)
		}
		markerPath := filepath.Join(socketPath, "marker")
		marker := []byte("directory-marker")
		if err := os.WriteFile(markerPath, marker, 0o600); err != nil {
			t.Fatalf("create directory marker: %v", err)
		}
		before, err := os.Lstat(socketPath)
		if err != nil {
			t.Fatalf("lstat pre-existing directory: %v", err)
		}

		assertSwiftServerRefusesPreexistingUnixPath(t, socketPath)

		after, err := os.Lstat(socketPath)
		if err != nil || !os.SameFile(before, after) || !after.IsDir() {
			t.Fatalf("pre-existing directory changed: before=%v after=%v err=%v", before, after, err)
		}
		contents, err := os.ReadFile(markerPath)
		if err != nil || !bytes.Equal(contents, marker) {
			t.Fatalf("pre-existing directory contents changed: contents=%q err=%v", contents, err)
		}
	})

	t.Run("symlink", func(t *testing.T) {
		root := t.TempDir()
		targetPath := filepath.Join(root, "target")
		marker := []byte("symlink-target")
		if err := os.WriteFile(targetPath, marker, 0o600); err != nil {
			t.Fatalf("create symlink target: %v", err)
		}
		socketPath := filepath.Join(root, "server.sock")
		if err := os.Symlink(targetPath, socketPath); err != nil {
			t.Fatalf("create pre-existing symlink: %v", err)
		}

		assertSwiftServerRefusesPreexistingUnixPath(t, socketPath)

		linkTarget, err := os.Readlink(socketPath)
		if err != nil || linkTarget != targetPath {
			t.Fatalf("pre-existing symlink changed: target=%q err=%v", linkTarget, err)
		}
		contents, err := os.ReadFile(targetPath)
		if err != nil || !bytes.Equal(contents, marker) {
			t.Fatalf("symlink target changed: contents=%q err=%v", contents, err)
		}
	})
}

// The server binds its OWN Unix socket. It has to: reading the caller's pid is the only
// way it can know who is calling, that read happens at accept, and SwiftNIO can only accept
// from a socket it bound itself. So a manual run with GRPC_UNIX_SOCKET set and no launchd
// serves, and the node it creates is owner-only with a lock node beside it — which is what
// the launchd-owned socket used to guarantee for free.
func TestSwiftServerLifecycle_UnixSocketBindsItsOwnOwnerOnlyNode(t *testing.T) {
	socketPath := newShortSwiftSocketPath(t)
	cmd, logs := startSwiftLifecycleProcess(t, map[string]string{
		"GRPC_UNIX_SOCKET": socketPath,
	})
	waitForSwiftUnixSocket(t, socketPath, logs)

	if err := assertOwnerOnlySocketNode(socketPath); err != nil {
		t.Fatalf("bound socket node: %v; logs=%q", err, logs.String())
	}
	lockPath := socketPath + ".owner"
	info, err := os.Lstat(lockPath)
	if err != nil {
		t.Fatalf("the pathname claim node is missing: %v; logs=%q", err, logs.String())
	}
	if !info.Mode().IsRegular() {
		t.Fatalf("the claim node is not a regular file: mode=%v", info.Mode())
	}
	if info.Mode().Perm()&0o077 != 0 {
		t.Fatalf("the claim node is mode %#o; owner-only is required", info.Mode().Perm())
	}

	// A clean SIGTERM removes both nodes: the socket outlives its descriptor, and a node with
	// no listener behind it is what the next start has to reclaim. SIGTERM, not a kill:
	// integrationfixture.StopChild SIGKILLs, and a process that cannot run its own shutdown
	// is the crash case, which the next test covers.
	if err := integrationfixture.StopChildGracefully(cmd, swiftServerLifecycleTimeout); err != nil {
		t.Fatalf("stop the server with SIGTERM: %v; logs=%q", err, logs.String())
	}
	assertPathAbsentAfterExit(t, socketPath)
	assertPathAbsentAfterExit(t, lockPath)
}

// A server that is KILLED cannot remove anything, so both nodes survive. What must not
// survive is the lock: the kernel releases it with the process, so the next start reclaims
// the pathname with no operator clearing it by hand. That is the whole reason the claim is
// an advisory lock rather than a live probe.
func TestSwiftServerLifecycle_KilledServerLeavesNodesTheNextStartReclaims(t *testing.T) {
	socketPath := newShortSwiftSocketPath(t)
	killed, killedLogs := startSwiftLifecycleProcess(t, map[string]string{
		"GRPC_UNIX_SOCKET": socketPath,
	})
	waitForSwiftUnixSocket(t, socketPath, killedLogs)
	stopSwiftLifecycleProcess(t, killed) // SIGKILL

	if _, err := os.Lstat(socketPath); err != nil {
		t.Fatalf("a killed server's socket node should survive: %v", err)
	}
	if _, err := os.Lstat(socketPath + ".owner"); err != nil {
		t.Fatalf("a killed server's claim node should survive: %v", err)
	}

	nodeBefore, err := os.Lstat(socketPath)
	if err != nil {
		t.Fatalf("stat the killed server's node: %v", err)
	}
	restarted, restartedLogs := startSwiftLifecycleProcess(t, map[string]string{
		"GRPC_UNIX_SOCKET": socketPath,
	})
	// The node is ALREADY there, because the killed server could not remove it, so waiting
	// for it to exist would prove nothing. Waiting for it to be REPLACED is what proves the
	// new server reclaimed the pathname.
	waitForSwiftUnixNodeToBeReplaced(t, socketPath, nodeBefore, restartedLogs)
	if err := integrationfixture.StopChildGracefully(restarted, swiftServerLifecycleTimeout); err != nil {
		t.Fatalf("stop the restarted server: %v; logs=%q", err, restartedLogs.String())
	}
	assertPathAbsentAfterExit(t, socketPath)
	assertPathAbsentAfterExit(t, socketPath+".owner")
}

// A pathname a LIVE server is already serving is refused, and refusing is non-destructive:
// the second server must leave both nodes in place, because they belong to the first.
func TestSwiftServerLifecycle_LiveUnixSocketIsRefusedNonDestructively(t *testing.T) {
	socketPath := newShortSwiftSocketPath(t)
	first, firstLogs := startSwiftLifecycleProcess(t, map[string]string{
		"GRPC_UNIX_SOCKET": socketPath,
	})
	waitForSwiftUnixSocket(t, socketPath, firstLogs)
	if err := assertOwnerOnlySocketNode(socketPath); err != nil {
		t.Fatalf("first server's node: %v", err)
	}
	// Identity, not contents: a socket node cannot be read, and what matters is that the
	// refused server did not replace the node it was refused.
	nodeBefore, err := os.Lstat(socketPath)
	if err != nil {
		t.Fatalf("stat the first server's node before the second starts: %v", err)
	}
	lockBefore, err := os.Lstat(socketPath + ".owner")
	if err != nil {
		t.Fatalf("stat the first server's claim node: %v", err)
	}

	second, secondLogs := startSwiftLifecycleProcess(t, map[string]string{
		"GRPC_UNIX_SOCKET": socketPath,
	})
	waitErr, forced := integrationfixture.WaitChild(second, swiftServerLifecycleTimeout)
	if forced || waitErr == nil || second.ProcessState == nil || second.ProcessState.Success() {
		t.Fatalf("second server exit=%v forced=%t state=%v, want prompt nonzero; logs=%q",
			waitErr, forced, second.ProcessState, secondLogs.String())
	}
	// The REASON is asserted where it is directly reachable, in the unit suite for
	// UnixSocketNodeError; os.Logger writes to the unified log rather than to the process's
	// stderr, so a subprocess test cannot read the sentence and asserting on an empty buffer
	// would prove nothing. What is asserted here is the behaviour the reason describes: a
	// prompt nonzero exit, with both nodes still belonging to the first server.
	nodeAfter, err := os.Lstat(socketPath)
	if err != nil {
		t.Fatalf("the refused server removed the live server's node: %v", err)
	}
	if !os.SameFile(nodeBefore, nodeAfter) {
		t.Fatalf("the refused server replaced the live server's node")
	}
	lockAfter, err := os.Lstat(socketPath + ".owner")
	if err != nil {
		t.Fatalf("the refused server removed the live server's claim node: %v", err)
	}
	if !os.SameFile(lockBefore, lockAfter) {
		t.Fatalf("the refused server replaced the live server's claim node")
	}
	// And the first server is still serving it.
	stopSwiftLifecycleProcess(t, first)
}

func waitForSwiftUnixSocket(t *testing.T, path string, logs *bytes.Buffer) {
	t.Helper()
	deadline := time.Now().Add(swiftServerLifecycleTimeout)
	for time.Now().Before(deadline) {
		if _, err := os.Lstat(path); err == nil {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("the server never bound %q; logs=%q", path, logs.String())
}

// assertOwnerOnlySocketNode asserts the bound node is a socket this user owns, and that only
// the owner can connect to it — the property launchd's SockPathMode used to provide.
func assertOwnerOnlySocketNode(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSocket == 0 {
		return fmt.Errorf("not a socket: mode=%v", info.Mode())
	}
	if info.Mode().Perm() != 0o600 {
		return fmt.Errorf("mode is %#o, want 0600", info.Mode().Perm())
	}
	if info.Sys().(*syscall.Stat_t).Uid != uint32(os.Geteuid()) {
		return fmt.Errorf("owned by uid %d, want %d", info.Sys().(*syscall.Stat_t).Uid, os.Geteuid())
	}
	return nil
}

func waitForSwiftUnixNodeToBeReplaced(t *testing.T, path string, before os.FileInfo, logs *bytes.Buffer) {
	t.Helper()
	deadline := time.Now().Add(swiftServerLifecycleTimeout)
	for time.Now().Before(deadline) {
		if current, err := os.Lstat(path); err == nil && !os.SameFile(before, current) {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("the restarted server never replaced the stale node at %q; logs=%q", path, logs.String())
}

func assertPathAbsentAfterExit(t *testing.T, path string) {
	t.Helper()
	deadline := time.Now().Add(swiftServerLifecycleTimeout)
	for time.Now().Before(deadline) {
		if _, err := os.Lstat(path); os.IsNotExist(err) {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("%q survived the server's exit", path)
}

func TestSwiftServerLifecycle_SIGTERMDrainsAndExitsZero(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve TCP address: %v", err)
	}
	address := listener.Addr().String()
	port := listener.Addr().(*net.TCPAddr).Port
	if err := listener.Close(); err != nil {
		t.Fatalf("release TCP address: %v", err)
	}

	cmd, logs := startSwiftLifecycleProcess(t, map[string]string{
		"GRPC_LISTEN_ADDRESS": "127.0.0.1",
		"GRPC_PORT":           strconv.Itoa(port),
		"GRPC_UNIX_SOCKET":    "",
	})
	readyCtx, cancelReady := context.WithTimeout(context.Background(), swiftServerLifecycleTimeout)
	defer cancelReady()
	if err := PollUntilContext(readyCtx, 20*time.Millisecond, func() (bool, error) {
		connection, err := net.DialTimeout("tcp", address, 100*time.Millisecond)
		if err != nil {
			return false, nil
		}
		return true, connection.Close()
	}); err != nil {
		stopSwiftLifecycleProcess(t, cmd)
		t.Fatalf("server did not become ready: %v; logs=%q", err, logs.String())
	}

	if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
		stopSwiftLifecycleProcess(t, cmd)
		t.Fatalf("signal server: %v", err)
	}
	waitErr, forced := integrationfixture.WaitChild(cmd, swiftServerLifecycleTimeout)
	if forced {
		t.Fatalf("SIGTERM did not drain server before deadline; logs=%q", logs.String())
	}
	if waitErr != nil || cmd.ProcessState == nil || !cmd.ProcessState.Success() {
		t.Fatalf("SIGTERM exit=%v state=%v, want zero after drain; logs=%q", waitErr, cmd.ProcessState, logs.String())
	}

	releaseCtx, cancelRelease := context.WithTimeout(context.Background(), time.Second)
	defer cancelRelease()
	if err := waitForPortAvailable(t, releaseCtx, address); err != nil {
		t.Fatalf("server address was not released after SIGTERM: %v", err)
	}
}

func startSwiftLifecycleProcess(t *testing.T, overrides map[string]string) (*exec.Cmd, *bytes.Buffer) {
	t.Helper()
	defaults := map[string]string{
		"GRPC_LISTEN_ADDRESS": "127.0.0.1",
		"GRPC_PORT":           "0",
		"GRPC_UNIX_SOCKET":    "",
	}
	maps.Copy(defaults, overrides)
	logs := &bytes.Buffer{}
	cmd := integrationfixture.NewSwiftServerCommand(testEnvironment(defaults), os.Stdout, logs)
	if err := cmd.Start(); err != nil {
		t.Fatalf("start release Swift server: %v", err)
	}
	t.Cleanup(func() {
		stopSwiftLifecycleProcess(t, cmd)
	})
	return cmd, logs
}

func assertSwiftServerRefusesPreexistingUnixPath(t *testing.T, socketPath string) {
	t.Helper()
	cmd, logs := startSwiftLifecycleProcess(t, map[string]string{
		"GRPC_UNIX_SOCKET": socketPath,
	})
	waitErr, forced := integrationfixture.WaitChild(cmd, swiftServerLifecycleTimeout)
	if forced || waitErr == nil || cmd.ProcessState == nil || cmd.ProcessState.Success() {
		t.Fatalf("pre-existing Unix path exit=%v forced=%t state=%v, want prompt nonzero; logs=%q", waitErr, forced, cmd.ProcessState, logs.String())
	}
}

func newShortSwiftSocketPath(t *testing.T) string {
	t.Helper()
	directory, err := os.MkdirTemp("/tmp", "exactmac-lifecycle-")
	if err != nil {
		t.Fatalf("create short Unix-socket directory: %v", err)
	}
	t.Cleanup(func() {
		if err := os.RemoveAll(directory); err != nil {
			t.Errorf("remove short Unix-socket directory: %v", err)
		}
	})
	return filepath.Join(directory, "server.sock")
}

func stopSwiftLifecycleProcess(t *testing.T, cmd *exec.Cmd) {
	t.Helper()
	if cmd == nil || cmd.ProcessState != nil {
		return
	}
	if err := integrationfixture.StopChild(cmd); err != nil {
		t.Errorf("stop exact Swift server child: %v", err)
	}
}
