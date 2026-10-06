// Copyright 2025 Joseph Cumines
//
// Configuration unit tests

package config

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestLoad_Defaults(t *testing.T) {
	// Clear any env vars that might affect the test
	os.Unsetenv("EXACTMAC_SERVER_ADDR")
	os.Unsetenv("EXACTMAC_SERVER_TLS")
	os.Unsetenv("EXACTMAC_REQUEST_TIMEOUT")
	os.Unsetenv("EXACTMAC_DEBUG")
	os.Unsetenv("MCP_HTTP_ADDRESS")
	os.Unsetenv("MCP_HTTP_SOCKET")
	os.Unsetenv("MCP_CORS_ORIGIN")
	os.Unsetenv("MCP_TLS_CERT_FILE")
	os.Unsetenv("MCP_TLS_KEY_FILE")
	os.Unsetenv("MCP_API_KEY")
	os.Unsetenv("MCP_AUDIT_LOG_FILE")
	os.Unsetenv("MCP_RATE_LIMIT")

	cfg, err := Load(TransportStdio)
	if err != nil {
		t.Fatalf("Load(TransportStdio) error = %v", err)
	}

	if cfg.ServerAddr != "localhost:50051" {
		t.Errorf("ServerAddr = %s, want localhost:50051", cfg.ServerAddr)
	}

	if cfg.ServerTLS != false {
		t.Errorf("ServerTLS = %v, want false", cfg.ServerTLS)
	}

	if cfg.RequestTimeout != DefaultRequestTimeoutSeconds {
		t.Errorf("RequestTimeout = %d, want %d", cfg.RequestTimeout, DefaultRequestTimeoutSeconds)
	}

	if cfg.Transport != TransportStdio {
		t.Errorf("Transport = %s, want stdio", cfg.Transport)
	}

	if cfg.HTTPAddress != "127.0.0.1:8080" {
		t.Errorf("HTTPAddress = %s, want 127.0.0.1:8080", cfg.HTTPAddress)
	}

	if cfg.CORSOrigin != "" {
		t.Errorf("CORSOrigin = %s, want empty secure default", cfg.CORSOrigin)
	}
}

// TestTheDefaultDeadlineOutlastsTheServersConsentWait is the assertion that the two
// defaults cannot drift into the state that shipped.
//
// A consent-requiring call blocks until the operator answers or the SERVER's own bound
// expires — ServerConfig.defaultConsentTimeoutSeconds, restated here as
// ServerConsentTimeoutSeconds. With a client deadline below that bound every
// consent-requiring call fails with DeadlineExceeded before the operator can answer, and the
// person answering a request that has already been refused is the confusion the consent flow
// exists to prevent. The client default was 30 and the server's wait is 90.
//
// The numbers live in two languages and nothing could read one from the other, which is
// exactly why a green suite shipped the mismatch: the server tests drive consent with a test
// clock and never go through the client, and the client tests exercise handlers without a
// real ninety-second wait. This test is the only thing standing between them.
func TestTheDefaultDeadlineOutlastsTheServersConsentWait(t *testing.T) {
	if DefaultRequestTimeoutSeconds <= ServerConsentTimeoutSeconds {
		t.Fatalf(
			"default client deadline %ds does not outlast the server's %ds consent wait, so "+
				"every consent-requiring call would time out before the operator could answer",
			DefaultRequestTimeoutSeconds,
			ServerConsentTimeoutSeconds,
		)
	}
	// And the shipped default actually clears the bound, rather than the constant merely
	// having the right relationship to itself.
	t.Setenv("EXACTMAC_REQUEST_TIMEOUT", "")
	os.Unsetenv("EXACTMAC_REQUEST_TIMEOUT")
	cfg, err := Load(TransportStdio)
	if err != nil {
		t.Fatalf("Load(TransportStdio) error = %v", err)
	}
	if cfg.RequestTimeout <= ServerConsentTimeoutSeconds {
		t.Errorf("loaded deadline %ds does not outlast the %ds consent wait",
			cfg.RequestTimeout, ServerConsentTimeoutSeconds)
	}
}

// TestADeadlineShorterThanTheConsentWaitIsRefused asserts the configuration cannot be set
// back into the state that shipped. The error has to name the server's value, because an
// operator who lowers one number has no way to know the other end has a different one.
func TestADeadlineShorterThanTheConsentWaitIsRefused(t *testing.T) {
	t.Setenv("EXACTMAC_REQUEST_TIMEOUT", "30")
	_, err := Load(TransportStdio)
	if err == nil {
		t.Fatal("Load(TransportStdio) accepted a 30s deadline against a 90s consent wait")
	}
	if !strings.Contains(err.Error(), "consent") {
		t.Errorf("error = %v, want it to name the consent wait as the cause", err)
	}
	if !strings.Contains(err.Error(), strconv.Itoa(ServerConsentTimeoutSeconds)) {
		t.Errorf("error = %v, want it to name the server's %d-second value",
			err, ServerConsentTimeoutSeconds)
	}
}

func TestLoad_ConsentTimeoutSecondsOverride(t *testing.T) {
	t.Setenv("EXACTMAC_CONSENT_TIMEOUT_SECONDS", "10")
	t.Setenv("EXACTMAC_REQUEST_TIMEOUT", "15")
	cfg, err := Load(TransportStdio)
	if err != nil {
		t.Fatalf("Load(TransportStdio) error = %v, want accepted request timeout >= custom consent timeout", err)
	}
	if cfg.RequestTimeout != 15 {
		t.Errorf("RequestTimeout = %d, want 15", cfg.RequestTimeout)
	}
}

func TestLoad_PhysicalRequestTimeoutMustFitTimeDuration(t *testing.T) {
	const maximumDurationSeconds = int64((1<<63 - 1) / int64(time.Second))
	t.Setenv(
		"EXACTMAC_REQUEST_TIMEOUT",
		strconv.FormatInt(maximumDurationSeconds+1, 10),
	)
	_, err := Load(TransportStdio)
	if err == nil || !strings.Contains(err.Error(), "EXACTMAC_REQUEST_TIMEOUT") {
		t.Fatalf("Load(TransportStdio) error=%v, want request-timeout overflow rejection", err)
	}
}

func TestLoad_TransportStdio(t *testing.T) {
	cfg, err := Load(TransportStdio)
	if err != nil {
		t.Fatalf("Load(TransportStdio) error = %v", err)
	}

	if cfg.Transport != TransportStdio {
		t.Errorf("Transport = %s, want stdio", cfg.Transport)
	}
}

func TestLoad_TransportStreamableHTTP(t *testing.T) {
	cfg, err := Load(TransportHTTP)
	if err != nil {
		t.Fatalf("Load(TransportHTTP) error = %v", err)
	}

	if cfg.Transport != TransportHTTP {
		t.Errorf("Transport = %s, want streamable-http", cfg.Transport)
	}
}

func TestLoad_TransportInvalid(t *testing.T) {
	for _, value := range []TransportType{"invalid", "sse", ""} {
		t.Run(string(value), func(t *testing.T) {
			_, err := Load(value)
			if err == nil {
				t.Fatalf("Load accepted obsolete or invalid transport %q", value)
			}
		})
	}
}

func TestLoad_IgnoresMCPTransportEnv(t *testing.T) {
	t.Setenv("MCP_TRANSPORT", "streamable-http")
	cfg, err := Load(TransportStdio)
	if err != nil {
		t.Fatalf("Load(TransportStdio) error = %v", err)
	}
	if cfg.Transport != TransportStdio {
		t.Fatalf("Transport = %s, want stdio (MCP_TRANSPORT must be ignored)", cfg.Transport)
	}
}

func TestLoad_InvalidInt(t *testing.T) {
	os.Setenv("EXACTMAC_REQUEST_TIMEOUT", "not-a-number")
	defer os.Unsetenv("EXACTMAC_REQUEST_TIMEOUT")

	_, err := Load(TransportStdio)
	if err == nil {
		t.Error("Load(TransportStdio) should return error for invalid integer config")
	}
}

func TestLoad_InvalidDuration(t *testing.T) {
	os.Setenv("MCP_HTTP_READ_TIMEOUT", "not-a-duration")
	defer os.Unsetenv("MCP_HTTP_READ_TIMEOUT")

	_, err := Load(TransportStdio)
	if err == nil {
		t.Error("Load(TransportStdio) should return error for invalid duration config")
	}
}

func TestLoad_HTTPConfig(t *testing.T) {
	os.Setenv("MCP_HTTP_ADDRESS", "127.0.0.1:9000")
	os.Setenv("MCP_HTTP_SOCKET", "/tmp/mcp.sock")
	os.Setenv("MCP_CORS_ORIGIN", "https://example.com")
	os.Setenv("MCP_HTTP_READ_TIMEOUT", "45s")
	os.Setenv("MCP_HTTP_WRITE_TIMEOUT", "45s")
	defer func() {
		os.Unsetenv("MCP_HTTP_ADDRESS")
		os.Unsetenv("MCP_HTTP_SOCKET")
		os.Unsetenv("MCP_CORS_ORIGIN")
		os.Unsetenv("MCP_HTTP_READ_TIMEOUT")
		os.Unsetenv("MCP_HTTP_WRITE_TIMEOUT")
	}()

	cfg, err := Load(TransportStdio)
	if err != nil {
		t.Fatalf("Load(TransportStdio) error = %v", err)
	}

	if cfg.HTTPAddress != "127.0.0.1:9000" {
		t.Errorf("HTTPAddress = %s, want 127.0.0.1:9000", cfg.HTTPAddress)
	}

	if cfg.HTTPSocketPath != "/tmp/mcp.sock" {
		t.Errorf("HTTPSocketPath = %s, want /tmp/mcp.sock", cfg.HTTPSocketPath)
	}

	if cfg.CORSOrigin != "https://example.com" {
		t.Errorf("CORSOrigin = %s, want https://example.com", cfg.CORSOrigin)
	}

	if cfg.HTTPReadTimeout != 45*time.Second {
		t.Errorf("HTTPReadTimeout = %v, want 45s", cfg.HTTPReadTimeout)
	}

	if cfg.HTTPWriteTimeout != 45*time.Second {
		t.Errorf("HTTPWriteTimeout = %v, want 45s", cfg.HTTPWriteTimeout)
	}
}

func TestTransportTypeConstants(t *testing.T) {
	if TransportStdio != "stdio" {
		t.Errorf("TransportStdio = %s, want stdio", TransportStdio)
	}

	if TransportHTTP != "streamable-http" {
		t.Errorf("TransportHTTP = %s, want streamable-http", TransportHTTP)
	}
}

func TestGetEnvAsDuration(t *testing.T) {
	tests := []struct {
		name      string
		envValue  string
		want      time.Duration
		wantError bool
	}{
		{"valid duration", "30s", 30 * time.Second, false},
		{"minutes", "5m", 5 * time.Minute, false},
		{"milliseconds", "500ms", 500 * time.Millisecond, false},
		{"empty fallback", "", 10 * time.Second, false},
		{"invalid error", "invalid", 0, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			os.Setenv("TEST_DURATION", tt.envValue)
			defer os.Unsetenv("TEST_DURATION")

			got, err := getEnvAsDuration("TEST_DURATION", 10*time.Second)
			if tt.wantError {
				if err == nil {
					t.Errorf("getEnvAsDuration() expected error for %q", tt.envValue)
				}
				return
			}
			if err != nil {
				t.Errorf("getEnvAsDuration() unexpected error: %v", err)
				return
			}
			if got != tt.want {
				t.Errorf("getEnvAsDuration() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestGetEnv(t *testing.T) {
	os.Setenv("TEST_ENV", "custom")
	defer os.Unsetenv("TEST_ENV")

	if got := getEnv("TEST_ENV", "default"); got != "custom" {
		t.Errorf("getEnv() = %s, want custom", got)
	}

	if got := getEnv("TEST_ENV_UNDEFINED", "default"); got != "default" {
		t.Errorf("getEnv() for undefined = %s, want default", got)
	}
}

func TestGetEnvAsBool(t *testing.T) {
	tests := []struct {
		value     string
		want      bool
		wantError bool
	}{
		{"true", true, false},
		{"1", true, false},
		{"yes", true, false},
		{"false", false, false},
		{"0", false, false},
		{"no", false, false},
		{"", false, false},
		{"truthy", false, true},
	}

	for _, tt := range tests {
		t.Run(tt.value, func(t *testing.T) {
			if tt.value != "" {
				os.Setenv("TEST_BOOL", tt.value)
				defer os.Unsetenv("TEST_BOOL")
			} else {
				os.Unsetenv("TEST_BOOL")
			}

			got, err := getEnvAsBool("TEST_BOOL", false)
			if tt.wantError {
				if err == nil {
					t.Fatalf("getEnvAsBool(%q) succeeded, want error", tt.value)
				}
				return
			}
			if err != nil {
				t.Fatalf("getEnvAsBool(%q) error = %v", tt.value, err)
			}
			if got != tt.want {
				t.Errorf("getEnvAsBool(%q) = %v, want %v", tt.value, got, tt.want)
			}
		})
	}
}

func TestGetEnvAsInt(t *testing.T) {
	tests := []struct {
		value     string
		want      int
		wantError bool
	}{
		{"42", 42, false},
		{"0", 0, false},
		{"-1", -1, false},
		{"invalid", 0, true},
		{"", 10, false},
	}

	for _, tt := range tests {
		t.Run(tt.value, func(t *testing.T) {
			if tt.value != "" {
				os.Setenv("TEST_INT", tt.value)
				defer os.Unsetenv("TEST_INT")
			} else {
				os.Unsetenv("TEST_INT")
			}

			got, err := getEnvAsInt("TEST_INT", 10)
			if tt.wantError {
				if err == nil {
					t.Errorf("getEnvAsInt() expected error for %q", tt.value)
				}
				return
			}
			if err != nil {
				t.Errorf("getEnvAsInt() unexpected error: %v", err)
				return
			}
			if got != tt.want {
				t.Errorf("getEnvAsInt(%q) = %d, want %d", tt.value, got, tt.want)
			}
		})
	}
}

func TestLoad_TLSConfig(t *testing.T) {
	os.Setenv("MCP_TLS_CERT_FILE", "/path/to/cert.pem")
	os.Setenv("MCP_TLS_KEY_FILE", "/path/to/key.pem")
	defer func() {
		os.Unsetenv("MCP_TLS_CERT_FILE")
		os.Unsetenv("MCP_TLS_KEY_FILE")
	}()

	cfg, err := Load(TransportStdio)
	if err != nil {
		t.Fatalf("Load(TransportStdio) error = %v", err)
	}

	if cfg.TLSCertFile != "/path/to/cert.pem" {
		t.Errorf("TLSCertFile = %s, want /path/to/cert.pem", cfg.TLSCertFile)
	}

	if cfg.TLSKeyFile != "/path/to/key.pem" {
		t.Errorf("TLSKeyFile = %s, want /path/to/key.pem", cfg.TLSKeyFile)
	}
}

func TestLoad_TLSConfigDefaults(t *testing.T) {
	os.Unsetenv("MCP_TLS_CERT_FILE")
	os.Unsetenv("MCP_TLS_KEY_FILE")

	cfg, err := Load(TransportStdio)
	if err != nil {
		t.Fatalf("Load(TransportStdio) error = %v", err)
	}

	if cfg.TLSCertFile != "" {
		t.Errorf("TLSCertFile = %s, want empty (optional)", cfg.TLSCertFile)
	}

	if cfg.TLSKeyFile != "" {
		t.Errorf("TLSKeyFile = %s, want empty (optional)", cfg.TLSKeyFile)
	}
}

func TestLoad_APIKeyConfig(t *testing.T) {
	os.Setenv("MCP_API_KEY", "test-secret-key-12345")
	defer os.Unsetenv("MCP_API_KEY")

	cfg, err := Load(TransportStdio)
	if err != nil {
		t.Fatalf("Load(TransportStdio) error = %v", err)
	}

	if cfg.APIKey != "test-secret-key-12345" {
		t.Errorf("APIKey = %s, want test-secret-key-12345", cfg.APIKey)
	}
}

func TestLoad_APIKeyConfigDefault(t *testing.T) {
	os.Unsetenv("MCP_API_KEY")

	cfg, err := Load(TransportStdio)
	if err != nil {
		t.Fatalf("Load(TransportStdio) error = %v", err)
	}

	if cfg.APIKey != "" {
		t.Errorf("APIKey = %s, want empty (optional)", cfg.APIKey)
	}
}

func TestLoad_AuditLogFileConfig(t *testing.T) {
	os.Setenv("MCP_AUDIT_LOG_FILE", "/var/log/mcp-audit.log")
	defer os.Unsetenv("MCP_AUDIT_LOG_FILE")

	cfg, err := Load(TransportStdio)
	if err != nil {
		t.Fatalf("Load(TransportStdio) error = %v", err)
	}

	if cfg.AuditLogFile != "/var/log/mcp-audit.log" {
		t.Errorf("AuditLogFile = %s, want /var/log/mcp-audit.log", cfg.AuditLogFile)
	}
}

func TestLoad_AuditLogFileConfigDefault(t *testing.T) {
	os.Unsetenv("MCP_AUDIT_LOG_FILE")

	cfg, err := Load(TransportStdio)
	if err != nil {
		t.Fatalf("Load(TransportStdio) error = %v", err)
	}

	if cfg.AuditLogFile != "" {
		t.Errorf("AuditLogFile = %s, want empty (disabled)", cfg.AuditLogFile)
	}
}

func TestLoad_RateLimitConfig(t *testing.T) {
	os.Setenv("MCP_RATE_LIMIT", "100.5")
	defer os.Unsetenv("MCP_RATE_LIMIT")

	cfg, err := Load(TransportStdio)
	if err != nil {
		t.Fatalf("Load(TransportStdio) error = %v", err)
	}

	if cfg.RateLimit != 100.5 {
		t.Errorf("RateLimit = %v, want 100.5", cfg.RateLimit)
	}
}

func TestLoad_RateLimitConfigDefault(t *testing.T) {
	os.Unsetenv("MCP_RATE_LIMIT")

	cfg, err := Load(TransportStdio)
	if err != nil {
		t.Fatalf("Load(TransportStdio) error = %v", err)
	}

	if cfg.RateLimit != 0 {
		t.Errorf("RateLimit = %v, want 0 (disabled)", cfg.RateLimit)
	}
}

func TestLoad_RateLimitInvalid(t *testing.T) {
	os.Setenv("MCP_RATE_LIMIT", "not-a-number")
	defer os.Unsetenv("MCP_RATE_LIMIT")

	_, err := Load(TransportStdio)
	if err == nil {
		t.Error("Load(TransportStdio) should return error for invalid rate limit")
	}
}

func TestLoad_RejectsUnsafeHTTPConfiguration(t *testing.T) {
	tests := []struct {
		environment map[string]string
		name        string
		wantError   string
	}{
		{
			name:        "certificate without key",
			environment: map[string]string{"MCP_TLS_CERT_FILE": "/tmp/server.crt"},
			wantError:   "MCP_TLS_CERT_FILE and MCP_TLS_KEY_FILE must be configured together",
		},
		{
			name:        "key without certificate",
			environment: map[string]string{"MCP_TLS_KEY_FILE": "/tmp/server.key"},
			wantError:   "MCP_TLS_CERT_FILE and MCP_TLS_KEY_FILE must be configured together",
		},
		{
			name:        "negative rate",
			environment: map[string]string{"MCP_RATE_LIMIT": "-0.5"},
			wantError:   "MCP_RATE_LIMIT must be zero or a finite positive number",
		},
		{
			name:        "non-finite rate",
			environment: map[string]string{"MCP_RATE_LIMIT": "NaN"},
			wantError:   "MCP_RATE_LIMIT must be zero or a finite positive number",
		},
		{
			name:        "zero request timeout",
			environment: map[string]string{"EXACTMAC_REQUEST_TIMEOUT": "0"},
			wantError:   "EXACTMAC_REQUEST_TIMEOUT must be positive",
		},
		{
			name:        "trailing request timeout data",
			environment: map[string]string{"EXACTMAC_REQUEST_TIMEOUT": "30seconds"},
			wantError:   "invalid value for EXACTMAC_REQUEST_TIMEOUT",
		},
		{
			name:        "negative read timeout",
			environment: map[string]string{"MCP_HTTP_READ_TIMEOUT": "-1s"},
			wantError:   "MCP_HTTP_READ_TIMEOUT must be positive",
		},
		{
			name:        "negative write timeout",
			environment: map[string]string{"MCP_HTTP_WRITE_TIMEOUT": "-1s"},
			wantError:   "MCP_HTTP_WRITE_TIMEOUT must not be negative",
		},
		{
			name:        "origin with path",
			environment: map[string]string{"MCP_CORS_ORIGIN": "https://trusted.example/path"},
			wantError:   "MCP_CORS_ORIGIN must be an exact HTTP or HTTPS origin",
		},
		{
			name:        "wildcard origin",
			environment: map[string]string{"MCP_CORS_ORIGIN": "*"},
			wantError:   "MCP_CORS_ORIGIN must be an exact HTTP or HTTPS origin",
		},
		{
			name:        "invalid listener address",
			environment: map[string]string{"MCP_HTTP_ADDRESS": "localhost"},
			wantError:   "MCP_HTTP_ADDRESS must be a host:port listener address",
		},
		{
			name:        "unspecified listener without controls",
			environment: map[string]string{"MCP_HTTP_ADDRESS": ":9000"},
			wantError:   "non-loopback MCP_HTTP_ADDRESS requires TLS, API key authentication, and rate limiting",
		},
		{
			name: "remote listener missing rate limit",
			environment: map[string]string{
				"MCP_API_KEY":       "production-secret",
				"MCP_HTTP_ADDRESS":  "0.0.0.0:9000",
				"MCP_TLS_CERT_FILE": "/tmp/server.crt",
				"MCP_TLS_KEY_FILE":  "/tmp/server.key",
			},
			wantError: "non-loopback MCP_HTTP_ADDRESS requires TLS, API key authentication, and rate limiting",
		},
		{
			name:        "relative socket path",
			environment: map[string]string{"MCP_HTTP_SOCKET": "relative/mcp.sock"},
			wantError:   "MCP_HTTP_SOCKET must be an absolute path",
		},
		{
			name:        "invalid boolean",
			environment: map[string]string{"MCP_SHELL_COMMANDS_ENABLED": "truthy"},
			wantError:   "invalid value for MCP_SHELL_COMMANDS_ENABLED",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Setenv("MCP_HTTP_ADDRESS", "127.0.0.1:8080")
			t.Setenv("MCP_HTTP_SOCKET", "")
			t.Setenv("MCP_TLS_CERT_FILE", "")
			t.Setenv("MCP_TLS_KEY_FILE", "")
			t.Setenv("MCP_API_KEY", "")
			t.Setenv("MCP_RATE_LIMIT", "0")
			t.Setenv("MCP_CORS_ORIGIN", "")
			for key, value := range test.environment {
				t.Setenv(key, value)
			}

			_, err := Load(TransportHTTP)
			if err == nil {
				t.Fatalf("Load(TransportHTTP) succeeded, want error containing %q", test.wantError)
			}
			if !strings.Contains(err.Error(), test.wantError) {
				t.Fatalf("Load(TransportHTTP) error = %q, want substring %q", err, test.wantError)
			}
		})
	}
}

func TestLoad_AllowsProtectedRemoteHTTPListener(t *testing.T) {
	t.Setenv("MCP_HTTP_ADDRESS", "0.0.0.0:9443")
	t.Setenv("MCP_TLS_CERT_FILE", "/tmp/server.crt")
	t.Setenv("MCP_TLS_KEY_FILE", "/tmp/server.key")
	t.Setenv("MCP_API_KEY", "production-secret")
	t.Setenv("MCP_RATE_LIMIT", "25")

	cfg, err := Load(TransportHTTP)
	if err != nil {
		t.Fatalf("Load(TransportHTTP) rejected protected remote listener: %v", err)
	}
	if cfg.HTTPAddress != "0.0.0.0:9443" {
		t.Fatalf("HTTPAddress = %q, want protected remote listener", cfg.HTTPAddress)
	}
}

func TestGetEnvAsFloat(t *testing.T) {
	tests := []struct {
		value     string
		want      float64
		wantError bool
	}{
		{"42.5", 42.5, false},
		{"0", 0, false},
		{"-1.5", -1.5, false},
		{"100", 100, false},
		{"invalid", 0, true},
		{"", 10.0, false},
	}

	for _, tt := range tests {
		t.Run(tt.value, func(t *testing.T) {
			if tt.value != "" {
				os.Setenv("TEST_FLOAT", tt.value)
				defer os.Unsetenv("TEST_FLOAT")
			} else {
				os.Unsetenv("TEST_FLOAT")
			}

			got, err := getEnvAsFloat("TEST_FLOAT", 10.0)
			if tt.wantError {
				if err == nil {
					t.Errorf("getEnvAsFloat() expected error for %q", tt.value)
				}
				return
			}
			if err != nil {
				t.Errorf("getEnvAsFloat() unexpected error: %v", err)
				return
			}
			if got != tt.want {
				t.Errorf("getEnvAsFloat(%q) = %v, want %v", tt.value, got, tt.want)
			}
		})
	}
}

func TestLoad_ServerSocketPathConfig(t *testing.T) {
	os.Setenv("EXACTMAC_SERVER_SOCKET_PATH", "/var/run/exactmac.sock")
	defer os.Unsetenv("EXACTMAC_SERVER_SOCKET_PATH")

	cfg, err := Load(TransportStdio)
	if err != nil {
		t.Fatalf("Load(TransportStdio) error = %v", err)
	}

	if cfg.ServerSocketPath != "/var/run/exactmac.sock" {
		t.Errorf("ServerSocketPath = %s, want /var/run/exactmac.sock", cfg.ServerSocketPath)
	}
}

// TestLoad_ServerSocketPathConfigDefault pins the default the product ships with.
//
// IT USED TO ASSERT THAT THE FIELD IS EMPTY, and that assertion was a defect being recorded
// as a requirement: with an empty path the client selects TCP, a TCP listener has no
// authenticating principal, and every consent-requiring capability is denied by design. An
// agent host that installed the console and spawned `exactmac mcp` with no environment at all
// therefore got a uniform total denial that looked exactly like an operator declining
// everything, and the real cause — the wrong transport — appeared nowhere. The console app
// already defaults its own socket path for precisely this reason; the client did not, and
// the two could disagree about where the product lives.
//
// The test is corrected in place rather than deleted: it pins a default, and the default is
// now the one the product needs.
func TestLoad_ServerSocketPathConfigDefault(t *testing.T) {
	os.Unsetenv("EXACTMAC_SERVER_SOCKET_PATH")

	cfg, err := Load(TransportStdio)
	if err != nil {
		t.Fatalf("Load(TransportStdio) error = %v", err)
	}

	home, err := os.UserHomeDir()
	if err != nil {
		t.Skipf("no home directory available: %v", err)
	}
	want := filepath.Join(home, "Library", "Caches", "exactmac.sock")
	if cfg.ServerSocketPath != want {
		t.Errorf("ServerSocketPath = %q, want %q (the console's own default socket path)",
			cfg.ServerSocketPath, want)
	}
}

func TestLoad_ServerSocketPathWithAddress(t *testing.T) {
	// Both socket path and address should be configurable
	os.Setenv("EXACTMAC_SERVER_ADDR", "localhost:50051")
	os.Setenv("EXACTMAC_SERVER_SOCKET_PATH", "/tmp/test.sock")
	defer func() {
		os.Unsetenv("EXACTMAC_SERVER_ADDR")
		os.Unsetenv("EXACTMAC_SERVER_SOCKET_PATH")
	}()

	cfg, err := Load(TransportStdio)
	if err != nil {
		t.Fatalf("Load(TransportStdio) error = %v", err)
	}

	if cfg.ServerAddr != "localhost:50051" {
		t.Errorf("ServerAddr = %s, want localhost:50051", cfg.ServerAddr)
	}

	if cfg.ServerSocketPath != "/tmp/test.sock" {
		t.Errorf("ServerSocketPath = %s, want /tmp/test.sock", cfg.ServerSocketPath)
	}
}

func TestLoad_ValidationWithOnlySocketPath(t *testing.T) {
	// Only socket path - should succeed (address uses default)
	os.Setenv("EXACTMAC_SERVER_SOCKET_PATH", "/tmp/test.sock")
	defer os.Unsetenv("EXACTMAC_SERVER_SOCKET_PATH")

	cfg, err := Load(TransportStdio)
	if err != nil {
		t.Fatalf("Load(TransportStdio) error = %v", err)
	}

	if cfg.ServerSocketPath != "/tmp/test.sock" {
		t.Errorf("ServerSocketPath = %s, want /tmp/test.sock", cfg.ServerSocketPath)
	}

	// ServerAddr should have default value
	if cfg.ServerAddr != "localhost:50051" {
		t.Errorf("ServerAddr = %s, want localhost:50051 (default)", cfg.ServerAddr)
	}
}

func TestLoad_ExplicitServerAddrSelectsTCP(t *testing.T) {
	os.Unsetenv("EXACTMAC_SERVER_SOCKET_PATH")
	os.Setenv("EXACTMAC_SERVER_ADDR", "127.0.0.1:54321")
	defer os.Unsetenv("EXACTMAC_SERVER_ADDR")

	cfg, err := Load(TransportStdio)
	if err != nil {
		t.Fatalf("Load(TransportStdio) error = %v", err)
	}

	if cfg.ServerAddr != "127.0.0.1:54321" {
		t.Errorf("ServerAddr = %s, want 127.0.0.1:54321", cfg.ServerAddr)
	}

	if cfg.ServerSocketPath != "" {
		t.Errorf("ServerSocketPath = %q, want empty when EXACTMAC_SERVER_ADDR is set explicitly", cfg.ServerSocketPath)
	}
}

func TestLoad_ExplicitEmptyServerSocketPathSelectsTCP(t *testing.T) {
	os.Setenv("EXACTMAC_SERVER_SOCKET_PATH", "")
	os.Setenv("EXACTMAC_SERVER_ADDR", "127.0.0.1:54321")
	defer func() {
		os.Unsetenv("EXACTMAC_SERVER_SOCKET_PATH")
		os.Unsetenv("EXACTMAC_SERVER_ADDR")
	}()

	cfg, err := Load(TransportStdio)
	if err != nil {
		t.Fatalf("Load(TransportStdio) error = %v", err)
	}

	if cfg.ServerSocketPath != "" {
		t.Errorf("ServerSocketPath = %q, want empty when EXACTMAC_SERVER_SOCKET_PATH is set to empty string", cfg.ServerSocketPath)
	}
}

func TestLoad_ServerTLSConfig(t *testing.T) {
	os.Setenv("EXACTMAC_SERVER_TLS", "true")
	defer os.Unsetenv("EXACTMAC_SERVER_TLS")

	cfg, err := Load(TransportStdio)
	if err != nil {
		t.Fatalf("Load(TransportStdio) error = %v", err)
	}

	if cfg.ServerTLS != true {
		t.Errorf("ServerTLS = %v, want true", cfg.ServerTLS)
	}
}

func TestLoad_ServerTLSConfigFalse(t *testing.T) {
	os.Setenv("EXACTMAC_SERVER_TLS", "false")
	defer os.Unsetenv("EXACTMAC_SERVER_TLS")

	cfg, err := Load(TransportStdio)
	if err != nil {
		t.Fatalf("Load(TransportStdio) error = %v", err)
	}

	if cfg.ServerTLS != false {
		t.Errorf("ServerTLS = %v, want false", cfg.ServerTLS)
	}
}

func TestLoad_ServerTLSConfigDefault(t *testing.T) {
	os.Unsetenv("EXACTMAC_SERVER_TLS")

	cfg, err := Load(TransportStdio)
	if err != nil {
		t.Fatalf("Load(TransportStdio) error = %v", err)
	}

	if cfg.ServerTLS != false {
		t.Errorf("ServerTLS = %v, want false (default)", cfg.ServerTLS)
	}
}

func TestLoad_ServerCertFileConfig(t *testing.T) {
	os.Setenv("EXACTMAC_SERVER_CERT_FILE", "/path/to/server.crt")
	defer os.Unsetenv("EXACTMAC_SERVER_CERT_FILE")

	cfg, err := Load(TransportStdio)
	if err != nil {
		t.Fatalf("Load(TransportStdio) error = %v", err)
	}

	if cfg.ServerCertFile != "/path/to/server.crt" {
		t.Errorf("ServerCertFile = %s, want /path/to/server.crt", cfg.ServerCertFile)
	}
}

func TestLoad_ServerCertFileConfigDefault(t *testing.T) {
	os.Unsetenv("EXACTMAC_SERVER_CERT_FILE")

	cfg, err := Load(TransportStdio)
	if err != nil {
		t.Fatalf("Load(TransportStdio) error = %v", err)
	}

	if cfg.ServerCertFile != "" {
		t.Errorf("ServerCertFile = %s, want empty (optional)", cfg.ServerCertFile)
	}
}

func TestLoad_DebugConfig(t *testing.T) {
	os.Setenv("EXACTMAC_DEBUG", "true")
	defer os.Unsetenv("EXACTMAC_DEBUG")

	cfg, err := Load(TransportStdio)
	if err != nil {
		t.Fatalf("Load(TransportStdio) error = %v", err)
	}

	if cfg.Debug != true {
		t.Errorf("Debug = %v, want true", cfg.Debug)
	}
}

func TestLoad_DebugConfigDefault(t *testing.T) {
	os.Unsetenv("EXACTMAC_DEBUG")

	cfg, err := Load(TransportStdio)
	if err != nil {
		t.Fatalf("Load(TransportStdio) error = %v", err)
	}

	if cfg.Debug != false {
		t.Errorf("Debug = %v, want false (default)", cfg.Debug)
	}
}
