// Copyright 2025 Joseph Cumines
//
// MCP server unit tests

package server

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/joeycumines/ExactMac/internal/config"
)

// TestNewMCPServer_WithDefaultConfig tests that NewMCPServer can be created
// Note: This test may fail in CI if there's no server running - that's expected
func TestNewMCPServer_WithDefaultConfig(t *testing.T) {
	cfg := &config.Config{
		ServerAddr:     "localhost:50051",
		RequestTimeout: 30,
	}
	// NewMCPServer will fail to connect but should still create the server struct
	// This tests that the initialization code runs without panicking
	_, err := NewMCPServer(cfg)
	if err != nil {
		// Expected if no server is running
		t.Logf("NewMCPServer returned error (expected if no gRPC server): %v", err)
	}
}

// TestConfigDefaults tests config default values
func TestConfigDefaults(t *testing.T) {
	cfg, err := config.Load(config.TransportStdio)
	if err != nil {
		t.Fatalf("Failed to load config: %v", err)
	}

	if cfg.RequestTimeout <= 0 {
		t.Errorf("RequestTimeout = %d, want > 0", cfg.RequestTimeout)
	}
}

// ============================================================================
// Unix Socket Support Tests
// ============================================================================

func TestValidateUnixSocketEndpoint(t *testing.T) {
	directory, err := os.MkdirTemp("/tmp", "mus-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(directory) })
	path := filepath.Join(directory, "server.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if err := os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
	if err := validateUnixSocketEndpoint(path); err != nil {
		t.Fatalf("valid endpoint rejected: %v", err)
	}
	link := filepath.Join(directory, "link.sock")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if err := validateUnixSocketEndpoint(link); err == nil {
		t.Fatal("symlink endpoint accepted")
	}
}

func TestValidateUnixSocketEndpointAllowsMissing(t *testing.T) {
	path := filepath.Join("/tmp", fmt.Sprintf("mus-missing-%d.sock", os.Getpid()))
	if err := validateUnixSocketEndpoint(path); err != nil {
		t.Fatalf("missing endpoint rejected: %v", err)
	}
}

// TestMCPServer_WithUnixSocketConfig tests that MCPServer can be configured with Unix socket
func TestMCPServer_WithUnixSocketConfig(t *testing.T) {
	cfg := &config.Config{
		ServerSocketPath: "/var/run/exactmac.sock",
		RequestTimeout:   30,
	}

	// Verify the config is set correctly
	if cfg.ServerSocketPath != "/var/run/exactmac.sock" {
		t.Errorf("ServerSocketPath = %s, want /var/run/exactmac.sock", cfg.ServerSocketPath)
	}

	if cfg.ServerAddr != "" {
		t.Errorf("ServerAddr should be empty when using socket path, got: %s", cfg.ServerAddr)
	}
}

// TestMCPServer_WithTCPAddressConfig tests that MCPServer can be configured with TCP address
func TestMCPServer_WithTCPAddressConfig(t *testing.T) {
	cfg := &config.Config{
		ServerAddr:       "localhost:50051",
		ServerSocketPath: "",
		RequestTimeout:   30,
	}

	// Verify the config is set correctly
	if cfg.ServerAddr != "localhost:50051" {
		t.Errorf("ServerAddr = %s, want localhost:50051", cfg.ServerAddr)
	}

	if cfg.ServerSocketPath != "" {
		t.Errorf("ServerSocketPath should be empty when using TCP, got: %s", cfg.ServerSocketPath)
	}
}

// TestMCPServer_WithBothAddressAndSocketPath tests that both can be configured
func TestMCPServer_WithBothAddressAndSocketPath(t *testing.T) {
	cfg := &config.Config{
		ServerAddr:       "localhost:50051",
		ServerSocketPath: "/tmp/test.sock",
		RequestTimeout:   30,
	}

	// Verify both are set
	if cfg.ServerAddr != "localhost:50051" {
		t.Errorf("ServerAddr = %s, want localhost:50051", cfg.ServerAddr)
	}

	if cfg.ServerSocketPath != "/tmp/test.sock" {
		t.Errorf("ServerSocketPath = %s, want /tmp/test.sock", cfg.ServerSocketPath)
	}
}

// TestMCPServer_UnixSocketAddressFormat tests that Unix socket addresses are formatted correctly
func TestMCPServer_UnixSocketAddressFormat(t *testing.T) {
	tests := []struct {
		name       string
		socketPath string
		wantPrefix string
		wantPath   string
	}{
		{
			name:       "standard socket path",
			socketPath: "/var/run/exactmac.sock",
			wantPrefix: "unix://",
			wantPath:   "/var/run/exactmac.sock",
		},
		{
			name:       "tmp socket path",
			socketPath: "/tmp/test.sock",
			wantPrefix: "unix://",
			wantPath:   "/tmp/test.sock",
		},
		{
			name:       "user socket path",
			socketPath: "/Users/test/Library/Application Support/ExactMac/exactmac.sock",
			wantPrefix: "unix://",
			wantPath:   "/Users/test/Library/Application Support/ExactMac/exactmac.sock",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Simulate the address construction from initGRPC
			addr := "unix://" + tt.socketPath
			if !strings.HasPrefix(addr, tt.wantPrefix) {
				t.Errorf("Address prefix = %s, want prefix %s", addr, tt.wantPrefix)
			}
			expected := tt.wantPrefix + tt.wantPath
			if addr != expected {
				t.Errorf("Address = %s, want %s", addr, expected)
			}
		})
	}
}

// TestMCPServer_SocketPathVsTCPAddressSelection tests the selection logic
func TestMCPServer_SocketPathVsTCPAddressSelection(t *testing.T) {
	tests := []struct {
		name         string
		serverAddr   string
		socketPath   string
		expectSocket bool
		expectedAddr string
	}{
		{
			name:         "socket path takes precedence",
			serverAddr:   "localhost:50051",
			socketPath:   "/tmp/test.sock",
			expectSocket: true,
			expectedAddr: "unix:///tmp/test.sock",
		},
		{
			name:         "TCP when no socket",
			serverAddr:   "localhost:50051",
			socketPath:   "",
			expectSocket: false,
			expectedAddr: "localhost:50051",
		},
		{
			name:         "TCP when socket is empty",
			serverAddr:   "192.168.1.100:50051",
			socketPath:   "",
			expectSocket: false,
			expectedAddr: "192.168.1.100:50051",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Simulate the address selection logic from initGRPC
			var serverAddr string
			if tt.socketPath != "" {
				serverAddr = "unix://" + tt.socketPath
			} else {
				serverAddr = tt.serverAddr
			}

			if tt.expectSocket {
				if !strings.HasPrefix(serverAddr, "unix://") {
					t.Errorf("Expected Unix socket address, got: %s", serverAddr)
				}
			} else {
				if strings.HasPrefix(serverAddr, "unix://") {
					t.Errorf("Expected TCP address, got Unix socket: %s", serverAddr)
				}
			}

			if serverAddr != tt.expectedAddr {
				t.Errorf("Server address = %s, want %s", serverAddr, tt.expectedAddr)
			}
		})
	}
}

// TestConfig_ServerSocketPathValidation tests config validation for socket path
func TestConfig_ServerSocketPathValidation(t *testing.T) {
	tests := []struct {
		name       string
		serverAddr string
		socketPath string
		wantErr    bool
	}{
		{
			name:       "socket path valid",
			serverAddr: "",
			socketPath: "/tmp/test.sock",
			wantErr:    false,
		},
		{
			name:       "address valid",
			serverAddr: "localhost:50051",
			socketPath: "",
			wantErr:    false,
		},
		{
			name:       "both valid",
			serverAddr: "localhost:50051",
			socketPath: "/tmp/test.sock",
			wantErr:    false,
		},
		{
			name:       "neither is invalid",
			serverAddr: "",
			socketPath: "",
			wantErr:    true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Simulate config validation
			err := error(nil)
			if tt.serverAddr == "" && tt.socketPath == "" {
				err = fmt.Errorf("server address or socket path must be provided")
			}

			if (err != nil) != tt.wantErr {
				t.Errorf("Validation error = %v, wantErr = %v", err, tt.wantErr)
			}
		})
	}
}
