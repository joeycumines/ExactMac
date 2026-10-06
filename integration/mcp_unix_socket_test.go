package integration

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/joeycumines/ExactMac/internal/integrationfixture"
)

func TestMCPUnixSocket_ExactProcessLifecycleAndBackendDispatch(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)
	socketPath := filepath.Join(shortMCPUnixDirectory(t), "mcp.sock")
	cmd, client, baseURL, _, cleanup := startMCPUnixSocketProcess(t, ctx, serverAddr, socketPath)
	defer cleanup()

	created, err := os.Lstat(socketPath)
	if err != nil {
		t.Fatalf("Lstat production Unix socket: %v", err)
	}
	if created.Mode()&os.ModeSocket == 0 || created.Mode().Perm() != 0600 {
		t.Fatalf("production Unix socket mode=%v, want socket 0600", created.Mode())
	}

	status, initializeHeaders, body := requestMCPListenerWithClient(
		t,
		ctx,
		client,
		baseURL+productionMCPEndpoint,
		validMCPInitializePayload(1),
		"",
		"",
	)
	if status != http.StatusOK {
		t.Fatalf("initialize over production Unix socket status=%d body=%q, want 200", status, body)
	}
	var initialize mcpResponse
	if err := json.Unmarshal(body, &initialize); err != nil {
		t.Fatalf("decode initialize over production Unix socket: %v body=%q", err, body)
	}
	if initialize.JSONRPC != "2.0" || initialize.Error != nil || len(initialize.Result) == 0 {
		t.Fatalf("invalid initialize response over production Unix socket: %+v", initialize)
	}
	sessionID := initializeHeaders.Get("MCP-Session-Id")
	if sessionID == "" {
		t.Fatal("initialize over production Unix socket omitted MCP-Session-Id")
	}

	status, _, body = requestMCPListenerWithClient(
		t,
		ctx,
		client,
		baseURL+productionMCPEndpoint,
		`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_apps","arguments":{}}}`,
		"",
		sessionID,
	)
	if status != http.StatusOK {
		t.Fatalf("list_apps over production Unix socket status=%d body=%q, want 200", status, body)
	}
	var call mcpResponse
	if err := json.Unmarshal(body, &call); err != nil {
		t.Fatalf("decode list_apps over production Unix socket: %v body=%q", err, body)
	}
	if call.Error != nil {
		t.Fatalf("list_apps over production Unix socket returned JSON-RPC error: %+v", call.Error)
	}
	var toolResult productionMCPToolResult
	if err := json.Unmarshal(call.Result, &toolResult); err != nil {
		t.Fatalf("decode list_apps tool result over production Unix socket: %v result=%q", err, call.Result)
	}
	if toolResult.IsError || len(toolResult.Content) == 0 {
		t.Fatalf("list_apps over production Unix socket returned unusable result: %+v", toolResult)
	}

	current, err := os.Lstat(socketPath)
	if err != nil {
		t.Fatalf("Lstat production Unix socket before cleanup: %v", err)
	}
	if !os.SameFile(created, current) || current.Mode().Perm() != 0600 {
		t.Fatalf("production Unix socket changed before cleanup: created=%v current=%v", created.Mode(), current.Mode())
	}

	cleanup()
	if cmd.ProcessState == nil || !cmd.ProcessState.Success() {
		t.Fatalf("production Unix-socket MCP process did not exit successfully: %v", cmd.ProcessState)
	}
	if _, err := os.Lstat(socketPath); !os.IsNotExist(err) {
		t.Fatalf("unchanged production Unix socket survived graceful cleanup: %v", err)
	}
}

func TestMCPUnixSocket_ExactProcessPreservesSwappedPath(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	socketPath := filepath.Join(shortMCPUnixDirectory(t), "mcp.sock")
	cmd, _, _, logPath, cleanup := startMCPUnixSocketProcess(t, ctx, "127.0.0.1:1", socketPath)
	defer cleanup()

	if err := os.Remove(socketPath); err != nil {
		t.Fatalf("unlink fixture-owned production Unix socket: %v", err)
	}
	const sentinel = "replacement-must-survive-production-cleanup"
	if err := os.WriteFile(socketPath, []byte(sentinel), 0600); err != nil {
		t.Fatalf("install replacement at production Unix socket path: %v", err)
	}

	cleanup()
	if cmd.ProcessState == nil || cmd.ProcessState.Success() {
		t.Fatalf("production Unix-socket MCP process reported successful changed-path cleanup: %v", cmd.ProcessState)
	}
	logBytes, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read changed-path production process log: %v", err)
	}
	if !strings.Contains(string(logBytes), "unix socket path changed") {
		t.Fatalf("changed-path production process log=%q, want cleanup refusal", logBytes)
	}
	content, err := os.ReadFile(socketPath)
	if err != nil {
		t.Fatalf("replacement did not survive production cleanup: %v", err)
	}
	if string(content) != sentinel {
		t.Fatalf("replacement content changed during production cleanup: %q", content)
	}
}

func TestMCPUnixSocket_ExactProcessRejectsExistingPath(t *testing.T) {
	tests := []string{"regular", "directory", "symlink"}
	for _, name := range tests {
		t.Run(name, func(t *testing.T) {
			directory := shortMCPUnixDirectory(t)
			path := filepath.Join(directory, "mcp.sock")
			const sentinel = "existing-path-must-survive"
			switch name {
			case "regular":
				if err := os.WriteFile(path, []byte(sentinel), 0600); err != nil {
					t.Fatalf("create regular fixture: %v", err)
				}
			case "directory":
				if err := os.Mkdir(path, 0700); err != nil {
					t.Fatalf("create directory fixture: %v", err)
				}
			case "symlink":
				target := filepath.Join(directory, "target")
				if err := os.WriteFile(target, []byte(sentinel), 0600); err != nil {
					t.Fatalf("create symlink target: %v", err)
				}
				if err := os.Symlink(target, path); err != nil {
					t.Fatalf("create symlink fixture: %v", err)
				}
			}

			before, err := os.Lstat(path)
			if err != nil {
				t.Fatalf("Lstat existing fixture: %v", err)
			}
			runCtx, cancelRun := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancelRun()
			cmd := exec.CommandContext(runCtx, "../.build/debug/exactmac", "http")
			cmd.Env = mcpUnixProcessEnvironment("127.0.0.1:1", path)
			output, runErr := cmd.CombinedOutput()
			if runCtx.Err() != nil {
				t.Fatalf("production MCP did not promptly reject %s socket path: %v output=%q", name, runCtx.Err(), output)
			}
			var exitErr *exec.ExitError
			if runErr == nil || !errors.As(runErr, &exitErr) || exitErr.ExitCode() == 0 {
				t.Fatalf("production MCP rejection of %s path exited successfully: err=%v output=%q", name, runErr, output)
			}
			if !strings.Contains(string(output), "refusing Unix socket path") {
				t.Fatalf("production MCP rejection log=%q, want stable refusal", output)
			}

			after, err := os.Lstat(path)
			if err != nil {
				t.Fatalf("existing %s fixture did not survive: %v", name, err)
			}
			if !os.SameFile(before, after) || before.Mode() != after.Mode() {
				t.Fatalf("existing %s fixture was replaced: before=%v after=%v", name, before.Mode(), after.Mode())
			}
			switch name {
			case "regular":
				content, err := os.ReadFile(path)
				if err != nil || string(content) != sentinel {
					t.Fatalf("regular fixture changed: content=%q error=%v", content, err)
				}
			case "directory":
				if !after.IsDir() {
					t.Fatalf("directory fixture changed to mode %v", after.Mode())
				}
			case "symlink":
				target, err := os.Readlink(path)
				if err != nil {
					t.Fatalf("symlink fixture changed: %v", err)
				}
				content, err := os.ReadFile(target)
				if err != nil || string(content) != sentinel {
					t.Fatalf("symlink target changed: content=%q error=%v", content, err)
				}
			}
		})
	}
}

func startMCPUnixSocketProcess(
	t *testing.T,
	ctx context.Context,
	grpcAddr string,
	socketPath string,
) (*exec.Cmd, *http.Client, string, string, func()) {
	t.Helper()

	binaryPath := filepath.Clean("../.build/debug/exactmac")
	info, err := os.Stat(binaryPath)
	if err != nil || info.Mode()&0111 == 0 {
		t.Fatalf("production MCP test binary is unavailable or non-executable at %s: %v", binaryPath, err)
	}
	logPath := filepath.Join(t.TempDir(), "mcp-unix.log")
	logFile, err := os.Create(logPath)
	if err != nil {
		t.Fatalf("create production Unix-socket process log: %v", err)
	}
	cmd := exec.CommandContext(ctx, "../.build/debug/exactmac", "http")
	cmd.Env = mcpUnixProcessEnvironment(grpcAddr, socketPath)
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	if err := cmd.Start(); err != nil {
		_ = logFile.Close()
		t.Fatalf("start production Unix-socket MCP process: %v", err)
	}

	httpTransport := &http.Transport{
		Proxy: nil,
		DialContext: func(dialCtx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(dialCtx, "unix", socketPath)
		},
	}
	client := &http.Client{Transport: httpTransport, Timeout: 2 * time.Second}
	baseURL := "http://mcp.local"

	var cleanupOnce sync.Once
	cleanup := func() {
		cleanupOnce.Do(func() {
			httpTransport.CloseIdleConnections()
			if err := integrationfixture.StopChildGracefully(cmd, productionMCPGracefulStopMargin); err != nil {
				t.Errorf("stop production Unix-socket MCP process: %v", err)
			}
			if err := logFile.Close(); err != nil {
				t.Errorf("close production Unix-socket MCP process log: %v", err)
			}
			logBytes, err := os.ReadFile(logPath)
			if err != nil {
				t.Errorf("read production Unix-socket MCP process log: %v", err)
			} else if strings.Contains(string(logBytes), goRaceWarning) {
				t.Errorf("production Unix-socket MCP process emitted a Go race report: %s", logBytes)
			}
		})
	}

	readyCtx, cancelReady := context.WithTimeout(ctx, 5*time.Second)
	defer cancelReady()
	err = PollUntilContext(readyCtx, 25*time.Millisecond, func() (bool, error) {
		request, err := http.NewRequestWithContext(readyCtx, http.MethodGet, baseURL+"/health", nil)
		if err != nil {
			return false, err
		}
		response, err := client.Do(request)
		if err != nil {
			return false, nil
		}
		_, readErr := io.Copy(io.Discard, response.Body)
		closeErr := response.Body.Close()
		if readErr != nil {
			return false, readErr
		}
		if closeErr != nil {
			return false, closeErr
		}
		return response.StatusCode == http.StatusOK, nil
	})
	if err != nil {
		cleanup()
		logBytes, readErr := os.ReadFile(logPath)
		t.Fatalf("production Unix-socket MCP process did not become ready: %v log=%q read_error=%v", err, logBytes, readErr)
	}

	return cmd, client, baseURL, logPath, cleanup
}

func mcpUnixProcessEnvironment(grpcAddr string, socketPath string) []string {
	return testEnvironment(map[string]string{
		"EXACTMAC_DEBUG":              "false",
		"EXACTMAC_REQUEST_TIMEOUT":    "135",
		"EXACTMAC_SERVER_ADDR":        grpcAddr,
		"EXACTMAC_SERVER_CERT_FILE":   "",
		"EXACTMAC_SERVER_SOCKET_PATH": "",
		"EXACTMAC_SERVER_TLS":         "false",
		"MCP_API_KEY":                 "",
		"MCP_AUDIT_LOG_FILE":          "",
		"MCP_CORS_ORIGIN":             "",
		"MCP_HTTP_ADDRESS":            "127.0.0.1:1",
		"MCP_HTTP_READ_TIMEOUT":       "30s",
		"MCP_HTTP_SOCKET":             socketPath,
		"MCP_HTTP_WRITE_TIMEOUT":      "30s",
		"MCP_RATE_LIMIT":              "0",
		"MCP_SHELL_COMMANDS_ENABLED":  "false",
		"MCP_TLS_CERT_FILE":           "",
		"MCP_TLS_KEY_FILE":            "",
	})
}

func shortMCPUnixDirectory(t *testing.T) string {
	t.Helper()
	directory, err := os.MkdirTemp("/tmp", "mcp-uds-")
	if err != nil {
		t.Fatalf("create short production Unix-socket directory: %v", err)
	}
	t.Cleanup(func() {
		if err := os.RemoveAll(directory); err != nil {
			t.Errorf("remove short production Unix-socket directory: %v", err)
		}
	})
	return directory
}
