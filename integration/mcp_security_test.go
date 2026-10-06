package integration

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"io"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestMCPProductionListenerSecurity_APIKey(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)
	_, baseURL, cleanup := startMCPTestServerWithOverrides(t, ctx, serverAddr, map[string]string{
		"MCP_API_KEY": "production-secret",
	})
	defer cleanup()

	payload := validMCPInitializePayload(1)
	status, _, _ := requestMCPListener(t, ctx, baseURL+productionMCPEndpoint, payload, "")
	if status != http.StatusUnauthorized {
		t.Fatalf("production listener without API key status=%d, want 401", status)
	}
	status, _, _ = requestMCPListener(t, ctx, baseURL+productionMCPEndpoint, payload, "wrong-secret")
	if status != http.StatusUnauthorized {
		t.Fatalf("production listener with wrong API key status=%d, want 401", status)
	}
	status, _, body := requestMCPListener(t, ctx, baseURL+productionMCPEndpoint, payload, "production-secret")
	if status != http.StatusOK {
		t.Fatalf("production listener with valid API key status=%d body=%q, want 200", status, body)
	}
	var response mcpResponse
	if err := json.Unmarshal(body, &response); err != nil || response.Error != nil {
		t.Fatalf("decode authorized initialize response=%+v error=%v body=%q", response, err, body)
	}

	status, _, _ = requestMCPListener(t, ctx, baseURL+"/metrics", "", "")
	if status != http.StatusUnauthorized {
		t.Fatalf("production metrics without API key status=%d, want 401", status)
	}
	healthRequest, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/health", nil)
	if err != nil {
		t.Fatalf("create health request: %v", err)
	}
	healthResponse, err := http.DefaultClient.Do(healthRequest)
	if err != nil {
		t.Fatalf("request health endpoint: %v", err)
	}
	defer healthResponse.Body.Close()
	if healthResponse.StatusCode != http.StatusOK {
		t.Fatalf("production health status=%d, want 200", healthResponse.StatusCode)
	}
}

func TestMCPProductionListenerSecurity_Origin(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	const trustedOrigin = "https://trusted.example"
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)
	_, baseURL, cleanup := startMCPTestServerWithOverrides(t, ctx, serverAddr, map[string]string{
		"MCP_CORS_ORIGIN": trustedOrigin,
	})
	defer cleanup()

	request := func(method string, origins ...string) (int, http.Header, []byte) {
		t.Helper()
		var body io.Reader
		if method == http.MethodPost {
			body = bytes.NewBufferString(validMCPInitializePayload(1))
		}
		req, err := http.NewRequestWithContext(ctx, method, baseURL+productionMCPEndpoint, body)
		if err != nil {
			t.Fatalf("create production Origin request: %v", err)
		}
		for _, origin := range origins {
			req.Header.Add("Origin", origin)
		}
		if method == http.MethodPost {
			req.Header.Set("Accept", "application/json, text/event-stream")
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("MCP-Protocol-Version", productionMCPProtocolVersion)
		} else {
			req.Header.Set("Access-Control-Request-Method", http.MethodPost)
			req.Header.Set("Access-Control-Request-Headers", "content-type,mcp-protocol-version")
		}
		response, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("send production Origin request: %v", err)
		}
		defer response.Body.Close()
		responseBody, err := io.ReadAll(response.Body)
		if err != nil {
			t.Fatalf("read production Origin response: %v", err)
		}
		return response.StatusCode, response.Header.Clone(), responseBody
	}

	status, headers, _ := request(http.MethodPost, "https://untrusted.example")
	if status != http.StatusForbidden {
		t.Fatalf("untrusted production Origin status=%d, want 403", status)
	}
	if got := headers.Get("Access-Control-Allow-Origin"); got != "" {
		t.Fatalf("untrusted production Origin received allow-origin %q", got)
	}

	status, _, _ = request(http.MethodPost, trustedOrigin, trustedOrigin)
	if status != http.StatusForbidden {
		t.Fatalf("duplicate production Origin status=%d, want 403", status)
	}

	status, headers, body := request(http.MethodPost, trustedOrigin)
	if status != http.StatusOK {
		t.Fatalf("trusted production Origin status=%d body=%q, want 200", status, body)
	}
	if got := headers.Get("Access-Control-Allow-Origin"); got != trustedOrigin {
		t.Fatalf("trusted production allow-origin=%q, want %q", got, trustedOrigin)
	}
	if !strings.Contains(headers.Get("Vary"), "Origin") {
		t.Fatalf("trusted production response Vary=%q, want Origin cache isolation", headers.Get("Vary"))
	}

	status, headers, body = request(http.MethodOptions, trustedOrigin)
	if status != http.StatusNoContent || len(body) != 0 {
		t.Fatalf("trusted production preflight status=%d body=%q, want 204 empty", status, body)
	}
	if got := headers.Get("Access-Control-Allow-Origin"); got != trustedOrigin {
		t.Fatalf("trusted production preflight allow-origin=%q, want %q", got, trustedOrigin)
	}
	if !strings.Contains(headers.Get("Vary"), "Origin") {
		t.Fatalf("trusted production preflight Vary=%q, want Origin cache isolation", headers.Get("Vary"))
	}
}

func TestMCPProductionListenerSecurity_RateLimit(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)
	_, baseURL, cleanup := startMCPTestServerWithOverrides(t, ctx, serverAddr, map[string]string{
		"MCP_RATE_LIMIT": "0.5",
	})
	defer cleanup()

	first := validMCPInitializePayload(1)
	status, _, body := requestMCPListener(t, ctx, baseURL+productionMCPEndpoint, first, "")
	if status != http.StatusOK {
		t.Fatalf("first production request status=%d body=%q, want 200", status, body)
	}
	second := `{"jsonrpc":"2.0","id":2,"method":"ping","params":{}}`
	status, headers, body := requestMCPListener(t, ctx, baseURL+productionMCPEndpoint, second, "")
	if status != http.StatusTooManyRequests {
		t.Fatalf("rate-limited production request status=%d body=%q, want 429", status, body)
	}
	if headers.Get("Retry-After") == "" {
		t.Fatal("rate-limited production response omitted Retry-After")
	}
}

func TestMCPProductionListenerSecurity_TLS(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	certificatePEM, certificatePath, keyPath := writeProductionTLSCertificate(t)
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)
	_, baseURL, cleanup := startMCPTestServerWithOverrides(t, ctx, serverAddr, map[string]string{
		"MCP_API_KEY":       "production-secret",
		"MCP_TLS_CERT_FILE": certificatePath,
		"MCP_TLS_KEY_FILE":  keyPath,
	})
	defer cleanup()

	if !strings.HasPrefix(baseURL, "https://") {
		t.Fatalf("production TLS listener URL = %q, want https scheme", baseURL)
	}
	payload := validMCPInitializePayload(1)

	untrustedClient := &http.Client{Timeout: 2 * time.Second}
	untrustedRequest, err := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+productionMCPEndpoint, bytes.NewBufferString(payload))
	if err != nil {
		t.Fatalf("create untrusted TLS request: %v", err)
	}
	untrustedRequest.Header.Set("Content-Type", "application/json")
	untrustedRequest.Header.Set("Accept", "application/json, text/event-stream")
	if response, requestErr := untrustedClient.Do(untrustedRequest); requestErr == nil {
		response.Body.Close()
		t.Fatal("production TLS listener accepted its self-signed certificate without an explicit trust root")
	}

	trustedClient := productionTLSClient(t, certificatePEM)
	status, _, body := requestMCPListenerWithClient(t, ctx, trustedClient, baseURL+productionMCPEndpoint, payload, "", "")
	if status != http.StatusUnauthorized {
		t.Fatalf("production TLS listener without API key status=%d body=%q, want 401", status, body)
	}

	request, err := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+productionMCPEndpoint, bytes.NewBufferString(payload))
	if err != nil {
		t.Fatalf("create trusted TLS request: %v", err)
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Accept", "application/json, text/event-stream")
	request.Header.Set("Authorization", "Bearer production-secret")
	response, err := trustedClient.Do(request)
	if err != nil {
		t.Fatalf("send trusted production TLS request: %v", err)
	}
	defer response.Body.Close()
	responseBody, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatalf("read trusted production TLS response: %v", err)
	}
	if response.StatusCode != http.StatusOK {
		t.Fatalf("trusted production TLS status=%d body=%q, want 200", response.StatusCode, responseBody)
	}
	if response.TLS == nil || !response.TLS.HandshakeComplete || response.TLS.Version < tls.VersionTLS12 {
		t.Fatalf("production response did not prove TLS 1.2+: %+v", response.TLS)
	}
	var decoded mcpResponse
	if err := json.Unmarshal(responseBody, &decoded); err != nil || decoded.Error != nil {
		t.Fatalf("decode production TLS initialize response=%+v error=%v body=%q", decoded, err, responseBody)
	}

	plainURL := "http://" + strings.TrimPrefix(baseURL, "https://") + productionMCPEndpoint
	plainRequest, err := http.NewRequestWithContext(ctx, http.MethodPost, plainURL, bytes.NewBufferString(payload))
	if err != nil {
		t.Fatalf("create plaintext request against TLS listener: %v", err)
	}
	plainRequest.Header.Set("Content-Type", "application/json")
	plainRequest.Header.Set("Accept", "application/json, text/event-stream")
	plainRequest.Header.Set("Authorization", "Bearer production-secret")
	if plainResponse, requestErr := untrustedClient.Do(plainRequest); requestErr == nil {
		defer plainResponse.Body.Close()
		if plainResponse.StatusCode == http.StatusOK {
			t.Fatal("production TLS listener executed initialize over plaintext HTTP")
		}
	}
}

func TestMCPProductionListenerSecurity_InvalidConfigurationExitsBeforeBind(t *testing.T) {
	tests := []struct {
		environment map[string]string
		name        string
		wantLog     string
	}{
		{
			name:        "incomplete TLS",
			environment: map[string]string{"MCP_TLS_CERT_FILE": "/tmp/incomplete.crt"},
			wantLog:     "MCP_TLS_CERT_FILE and MCP_TLS_KEY_FILE must be configured together",
		},
		{
			name:        "negative rate",
			environment: map[string]string{"MCP_RATE_LIMIT": "-1"},
			wantLog:     "MCP_RATE_LIMIT must be zero or a finite positive number",
		},
		{
			name:        "zero request timeout",
			environment: map[string]string{"EXACTMAC_REQUEST_TIMEOUT": "0"},
			wantLog:     "EXACTMAC_REQUEST_TIMEOUT must be positive",
		},
		{
			name:        "malformed origin",
			environment: map[string]string{"MCP_CORS_ORIGIN": "https://trusted.example/path"},
			wantLog:     "MCP_CORS_ORIGIN must be an exact HTTP or HTTPS origin",
		},
		{
			name:        "unsafe all-interface listener",
			environment: map[string]string{"MCP_HTTP_ADDRESS": "unspecified"},
			wantLog:     "non-loopback MCP_HTTP_ADDRESS requires TLS, API key authentication, and rate limiting",
		},
		{
			name:        "malformed security boolean",
			environment: map[string]string{"MCP_SHELL_COMMANDS_ENABLED": "truthy"},
			wantLog:     "invalid value for MCP_SHELL_COMMANDS_ENABLED",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			listener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatalf("reserve listener address: %v", err)
			}
			defer listener.Close()

			address := listener.Addr().String()
			processEnvironment := map[string]string{
				"EXACTMAC_REQUEST_TIMEOUT":   "135",
				"EXACTMAC_SERVER_ADDR":       "127.0.0.1:1",
				"MCP_API_KEY":                "",
				"MCP_CORS_ORIGIN":            "",
				"MCP_HEARTBEAT_INTERVAL":     "30s",
				"MCP_HTTP_ADDRESS":           address,
				"MCP_HTTP_READ_TIMEOUT":      "30s",
				"MCP_HTTP_SOCKET":            "",
				"MCP_HTTP_WRITE_TIMEOUT":     "30s",
				"MCP_RATE_LIMIT":             "0",
				"MCP_SHELL_COMMANDS_ENABLED": "false",
				"MCP_TLS_CERT_FILE":          "",
				"MCP_TLS_KEY_FILE":           "",
			}
			for key, value := range test.environment {
				if key == "MCP_HTTP_ADDRESS" && value == "unspecified" {
					_, port, splitErr := net.SplitHostPort(address)
					if splitErr != nil {
						t.Fatalf("split reserved listener address: %v", splitErr)
					}
					value = ":" + port
				}
				processEnvironment[key] = value
			}

			runCtx, cancelRun := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancelRun()
			cmd := exec.CommandContext(runCtx, "../.build/debug/exactmac", "http")
			cmd.Env = testEnvironment(processEnvironment)
			var output bytes.Buffer
			cmd.Stdout = &output
			cmd.Stderr = &output
			runErr := cmd.Run()
			if runCtx.Err() != nil {
				t.Fatalf("invalid production configuration did not exit: %v output=%q", runCtx.Err(), output.String())
			}
			if runErr == nil {
				t.Fatalf("invalid production configuration exited successfully: output=%q", output.String())
			}
			if !strings.Contains(output.String(), test.wantLog) {
				t.Fatalf("invalid production configuration log=%q, want substring %q", output.String(), test.wantLog)
			}
			if strings.Contains(output.String(), "address already in use") {
				t.Fatalf("invalid production configuration reached listener bind: %q", output.String())
			}
		})
	}
}

func writeProductionTLSCertificate(t *testing.T) ([]byte, string, string) {
	t.Helper()
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate production test TLS key: %v", err)
	}
	serialNumber, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		t.Fatalf("generate production test TLS serial: %v", err)
	}
	now := time.Now()
	template := x509.Certificate{
		SerialNumber:          serialNumber,
		Subject:               pkix.Name{CommonName: "127.0.0.1"},
		NotBefore:             now.Add(-time.Minute),
		NotAfter:              now.Add(time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IPAddresses:           []net.IP{net.ParseIP("127.0.0.1")},
	}
	certificateDER, err := x509.CreateCertificate(rand.Reader, &template, &template, &privateKey.PublicKey, privateKey)
	if err != nil {
		t.Fatalf("create production test TLS certificate: %v", err)
	}
	privateKeyDER, err := x509.MarshalECPrivateKey(privateKey)
	if err != nil {
		t.Fatalf("marshal production test TLS key: %v", err)
	}
	certificatePEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certificateDER})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: privateKeyDER})
	directory := t.TempDir()
	certificatePath := filepath.Join(directory, "server.crt")
	keyPath := filepath.Join(directory, "server.key")
	if err := os.WriteFile(certificatePath, certificatePEM, 0o600); err != nil {
		t.Fatalf("write production test TLS certificate: %v", err)
	}
	if err := os.WriteFile(keyPath, keyPEM, 0o600); err != nil {
		t.Fatalf("write production test TLS key: %v", err)
	}
	return certificatePEM, certificatePath, keyPath
}

func productionTLSClient(t *testing.T, certificatePEM []byte) *http.Client {
	t.Helper()
	rootCAs := x509.NewCertPool()
	if !rootCAs.AppendCertsFromPEM(certificatePEM) {
		t.Fatal("append production test TLS trust root")
	}
	transport := &http.Transport{
		TLSClientConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
			RootCAs:    rootCAs,
		},
	}
	t.Cleanup(transport.CloseIdleConnections)
	return &http.Client{Transport: transport, Timeout: 5 * time.Second}
}

func requestMCPListener(
	t *testing.T,
	ctx context.Context,
	url string,
	payload string,
	apiKey string,
) (int, http.Header, []byte) {
	t.Helper()
	return requestMCPListenerWithClient(t, ctx, http.DefaultClient, url, payload, apiKey, "")
}

func requestMCPListenerWithClient(
	t *testing.T,
	ctx context.Context,
	client *http.Client,
	url string,
	payload string,
	apiKey string,
	sessionID string,
) (int, http.Header, []byte) {
	t.Helper()
	method := http.MethodGet
	var body io.Reader
	if payload != "" {
		method = http.MethodPost
		body = bytes.NewBufferString(payload)
	}
	request, err := http.NewRequestWithContext(ctx, method, url, body)
	if err != nil {
		t.Fatalf("create production listener request: %v", err)
	}
	if payload != "" {
		request.Header.Set("Content-Type", "application/json")
		request.Header.Set("Accept", "application/json, text/event-stream")
		request.Header.Set("MCP-Protocol-Version", productionMCPProtocolVersion)
	}
	if apiKey != "" {
		request.Header.Set("Authorization", "Bearer "+apiKey)
	}
	if sessionID != "" {
		request.Header.Set("MCP-Session-Id", sessionID)
	}
	response, err := client.Do(request)
	if err != nil {
		t.Fatalf("send production listener request: %v", err)
	}
	defer response.Body.Close()
	responseBody, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatalf("read production listener response: %v", err)
	}
	return response.StatusCode, response.Header.Clone(), responseBody
}
