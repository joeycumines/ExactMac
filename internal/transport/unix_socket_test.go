//go:build !windows

package transport

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestHTTPTransportUnixSocket_RefusesRegularFileWithoutRemoval(t *testing.T) {
	path := filepath.Join(shortUnixSocketDir(t), "mcp.sock")
	const sentinel = "regular-file-must-survive"
	if err := os.WriteFile(path, []byte(sentinel), 0600); err != nil {
		t.Fatalf("write sentinel: %v", err)
	}
	transport := NewHTTPTransport(&HTTPTransportConfig{SocketPath: path})
	serveResult := make(chan error, 1)
	go func() { serveResult <- transport.Serve(echoTransportMessage) }()

	select {
	case err := <-serveResult:
		if err == nil {
			t.Fatal("Serve accepted regular socket path")
		}
	case <-time.After(100 * time.Millisecond):
		_ = transport.Close()
		<-serveResult
		t.Error("Serve deleted regular file and started a listener")
	}
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("regular file did not survive: %v", err)
	}
	if string(content) != sentinel {
		t.Fatalf("regular file content changed: %q", content)
	}
}

func TestHTTPTransportUnixSocket_RefusesSymlinkWithoutReplacement(t *testing.T) {
	tmpDir := shortUnixSocketDir(t)
	target := filepath.Join(tmpDir, "target")
	if err := os.WriteFile(target, []byte("target"), 0600); err != nil {
		t.Fatalf("write target: %v", err)
	}
	path := filepath.Join(tmpDir, "mcp.sock")
	if err := os.Symlink(target, path); err != nil {
		t.Fatalf("create symlink: %v", err)
	}
	transport := NewHTTPTransport(&HTTPTransportConfig{SocketPath: path})
	serveResult := make(chan error, 1)
	go func() { serveResult <- transport.Serve(echoTransportMessage) }()

	select {
	case err := <-serveResult:
		if err == nil {
			t.Fatal("Serve accepted symlink socket path")
		}
	case <-time.After(100 * time.Millisecond):
		_ = transport.Close()
		<-serveResult
		t.Error("Serve replaced symlink with a listener")
	}
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatalf("symlink did not survive: %v", err)
	}
	if info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("socket path mode=%v, want original symlink", info.Mode())
	}
}

func TestHTTPTransportUnixSocket_RefusesDirectoryWithoutRemoval(t *testing.T) {
	path := filepath.Join(shortUnixSocketDir(t), "mcp.sock")
	if err := os.Mkdir(path, 0700); err != nil {
		t.Fatalf("create existing directory: %v", err)
	}
	transport := NewHTTPTransport(&HTTPTransportConfig{SocketPath: path})
	serveResult := make(chan error, 1)
	go func() { serveResult <- transport.Serve(echoTransportMessage) }()

	select {
	case err := <-serveResult:
		if err == nil {
			t.Fatal("Serve accepted directory socket path")
		}
	case <-time.After(100 * time.Millisecond):
		_ = transport.Close()
		<-serveResult
		t.Error("Serve deleted directory and started a listener")
	}
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatalf("directory did not survive: %v", err)
	}
	if !info.IsDir() {
		t.Fatalf("socket path mode=%v, want original directory", info.Mode())
	}
}

func TestHTTPTransportUnixSocket_RefusesExistingSocket(t *testing.T) {
	path := filepath.Join(shortUnixSocketDir(t), "mcp.sock")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatalf("create existing socket: %v", err)
	}
	listener.SetUnlinkOnClose(false)
	if err := listener.Close(); err != nil {
		t.Fatalf("close existing socket: %v", err)
	}

	transport := NewHTTPTransport(&HTTPTransportConfig{SocketPath: path})
	serveResult := make(chan error, 1)
	go func() { serveResult <- transport.Serve(echoTransportMessage) }()
	select {
	case err := <-serveResult:
		if err == nil {
			t.Fatal("Serve accepted existing socket path")
		}
	case <-time.After(100 * time.Millisecond):
		_ = transport.Close()
		<-serveResult
		t.Error("Serve deleted existing socket and started a listener")
	}
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatalf("existing socket did not survive: %v", err)
	}
	if info.Mode()&os.ModeSocket == 0 {
		t.Fatalf("existing path mode=%v, want socket", info.Mode())
	}
}

func TestHTTPTransportUnixSocket_OwnerPrivateAndPreservesSwappedPath(t *testing.T) {
	path := filepath.Join(shortUnixSocketDir(t), "mcp.sock")
	transport := NewHTTPTransport(&HTTPTransportConfig{SocketPath: path})
	serveResult := make(chan error, 1)
	go func() { serveResult <- transport.Serve(echoTransportMessage) }()

	deadline := time.NewTimer(time.Second)
	defer deadline.Stop()
	ticker := time.NewTicker(5 * time.Millisecond)
	defer ticker.Stop()
	var info os.FileInfo
	for info == nil {
		var err error
		info, err = os.Lstat(path)
		if err == nil {
			break
		}
		if !os.IsNotExist(err) {
			t.Fatalf("Lstat listener: %v", err)
		}
		select {
		case err := <-serveResult:
			t.Fatalf("Serve returned before socket creation: %v", err)
		case <-deadline.C:
			t.Fatal("Unix socket was not created")
		case <-ticker.C:
		}
	}
	if info.Mode()&os.ModeSocket == 0 || info.Mode().Perm() != 0600 {
		t.Errorf("created socket mode=%v, want socket 0600", info.Mode())
	}

	if err := os.Remove(path); err != nil {
		t.Fatalf("unlink owned test socket: %v", err)
	}
	const sentinel = "replacement-must-survive"
	if err := os.WriteFile(path, []byte(sentinel), 0600); err != nil {
		t.Fatalf("install replacement: %v", err)
	}
	closeErr := transport.Close()
	if closeErr == nil || !strings.Contains(closeErr.Error(), "changed") {
		t.Errorf("Close error=%v, want changed-path refusal", closeErr)
	}
	if err := <-serveResult; err != nil {
		t.Errorf("Serve error after Close: %v", err)
	}
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("replacement did not survive Close: %v", err)
	}
	if string(content) != sentinel {
		t.Fatalf("replacement content changed: %q", content)
	}
}

func echoTransportMessage(message *Message) (*Message, error) {
	return &Message{JSONRPC: "2.0", ID: message.ID, Result: []byte(`{}`)}, nil
}

func shortUnixSocketDir(t *testing.T) string {
	t.Helper()
	directory, err := os.MkdirTemp("/tmp", "exactmac-uds-")
	if err != nil {
		t.Fatalf("create short socket directory: %v", err)
	}
	t.Cleanup(func() {
		if err := os.RemoveAll(directory); err != nil {
			t.Errorf("remove short socket directory: %v", err)
		}
	})
	return directory
}
