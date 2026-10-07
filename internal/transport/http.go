// Copyright 2025 Joseph Cumines
//
// Streamable HTTP transport for JSON-RPC 2.0 communication

package transport

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"mime"
	"net"
	"net/http"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// HTTP transport constants
const (
	// MCPEndpointPath is the single endpoint for MCP Streamable HTTP requests.
	MCPEndpointPath = "/mcp"
	// MCPProtocolVersionCurrent is the protocol version implemented by this transport.
	MCPProtocolVersionCurrent = "2025-11-25"
	// mcpProtocolVersionFallback is assumed when the version header is absent.
	mcpProtocolVersionFallback = "2025-03-26"
	// serverShutdownTimeout is the timeout for graceful HTTP server shutdown.
	// net/http deliberately does not treat a StateNew connection as idle until
	// it has remained unread for more than five seconds. Keep the production
	// grace window beyond that threshold, its whole-second comparison, and the
	// shutdown poll jitter so speculative client dials from normal concurrent
	// traffic do not become false shutdown failures.
	serverShutdownTimeout = 8 * time.Second
	// HTTP sessions are bounded in both count and idle lifetime so abandoned
	// clients cannot grow transport state indefinitely.
	maxHTTPSessions     = 1024
	httpSessionTTL      = time.Hour
	sessionIDByteLength = 32
	maxSessionIDLength  = 128
)

// HTTPTransportConfig holds configuration for HTTP transport.
// Address is the HTTP server address (e.g., ":8080" or "localhost:8080").
// SocketPath is an optional Unix domain socket path (takes precedence over Address).
// CORSOrigin is the allowed browser Origin (default: none).
// ReadTimeout for HTTP server (default: 30s).
// WriteTimeout for HTTP server (default: 30s).
// TLSCertFile is the path to the TLS certificate file (optional, enables TLS if set).
// TLSKeyFile is the path to the TLS private key file (optional, required if TLSCertFile is set).
// APIKey is the API key for Bearer token authentication (optional, no auth if empty).
// RateLimit is the rate limit in requests per second (0 = disabled).
type HTTPTransportConfig struct {
	Address      string
	SocketPath   string
	CORSOrigin   string
	TLSCertFile  string
	TLSKeyFile   string
	APIKey       string
	ReadTimeout  time.Duration
	WriteTimeout time.Duration
	RateLimit    float64
}

// DefaultHTTPConfig returns the default HTTP transport configuration.
// Address defaults to loopback port 8080, browser Origins are denied by
// default, and HTTP read/write timeouts are 30 seconds.
func DefaultHTTPConfig() *HTTPTransportConfig {
	return &HTTPTransportConfig{
		Address:      "127.0.0.1:8080",
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 30 * time.Second,
	}
}

// HTTPTransport implements MCP Streamable HTTP with synchronous JSON responses.
// The single /mcp endpoint accepts POST and deliberately returns 405 for GET
// because this server does not currently initiate standalone SSE streams.
type HTTPTransport struct {
	config      *HTTPTransportConfig
	server      *http.Server
	handler     func(*Message) (*Message, error)
	metrics     *MetricsRegistry
	rateLimiter *RateLimiter
	sessions    map[string]*httpSession
	closeErr    error
	// shutdownTimeout is injectable only for deterministic shutdown tests.
	// Production instances always receive serverShutdownTimeout.
	shutdownTimeout time.Duration
	closed          atomic.Bool
	closeOnce       sync.Once
	sessionMu       sync.Mutex
	serveMu         sync.Mutex
	socketMu        sync.Mutex
	socketIdentity  unixSocketIdentity
	socketOwned     bool
}

type httpSession struct {
	scope    *ClientScope
	lastUsed time.Time
}

type unixSocketIdentity struct {
	device uint64
	inode  uint64
}

// NewHTTPTransport creates a Streamable HTTP transport with the given configuration.
// If config is nil, default configuration is used.
func NewHTTPTransport(config *HTTPTransportConfig) *HTTPTransport {
	if config == nil {
		config = DefaultHTTPConfig()
	}
	if config.ReadTimeout == 0 {
		config.ReadTimeout = 30 * time.Second
	}
	if config.WriteTimeout == 0 {
		config.WriteTimeout = 30 * time.Second
	}

	t := &HTTPTransport{
		config:          config,
		metrics:         NewMetricsRegistry(),
		rateLimiter:     NewRateLimiter(config.RateLimit),
		sessions:        make(map[string]*httpSession),
		shutdownTimeout: serverShutdownTimeout,
	}

	mux := http.NewServeMux()
	mux.HandleFunc(MCPEndpointPath, t.handleMCP)
	mux.HandleFunc("/health", t.handleHealth)
	mux.HandleFunc("/metrics", t.handleMetrics)

	// Build middleware chain with Origin validation outermost so an untrusted
	// browser origin is rejected before authentication, rate accounting, or dispatch.
	var handler http.Handler = mux
	if t.rateLimiter != nil {
		handler = RateLimitMiddleware(t.rateLimiter, handler)
	}
	if config.APIKey != "" {
		handler = t.authMiddleware(handler)
	}
	handler = t.corsMiddleware(handler)

	t.server = &http.Server{
		Handler:      handler,
		ReadTimeout:  config.ReadTimeout,
		WriteTimeout: config.WriteTimeout,
	}

	return t
}

// corsMiddleware validates browser Origin and adds CORS response headers.
func (t *HTTPTransport) corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Origin changes both admission and response headers. Ensure shared caches
		// never reuse a trusted-origin response for an untrusted browser origin (or
		// cache a rejection over a later trusted request).
		w.Header().Add("Vary", "Origin")
		originValues := r.Header.Values("Origin")
		if len(originValues) > 1 ||
			(len(originValues) == 1 &&
				(t.config.CORSOrigin == "" ||
					(t.config.CORSOrigin != "*" && originValues[0] != t.config.CORSOrigin))) {
			http.Error(w, "Origin not allowed", http.StatusForbidden)
			return
		}

		if t.config.CORSOrigin != "" {
			w.Header().Set("Access-Control-Allow-Origin", t.config.CORSOrigin)
		}
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Accept, Content-Type, Last-Event-ID, MCP-Protocol-Version, MCP-Session-Id, Authorization")
		w.Header().Set("Access-Control-Expose-Headers", "Content-Type, MCP-Session-Id")

		if r.Method == "OPTIONS" {
			w.WriteHeader(http.StatusNoContent)
			return
		}

		next.ServeHTTP(w, r)
	})
}

// authMiddleware validates Bearer token authentication.
// If the APIKey is configured, requests must include a valid Authorization header.
// The /health endpoint is exempt from authentication for load balancer health checks.
func (t *HTTPTransport) authMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Health check endpoint is exempt from authentication
		if r.URL.Path == "/health" {
			next.ServeHTTP(w, r)
			return
		}

		authHeader := r.Header.Get("Authorization")
		if authHeader == "" {
			http.Error(w, "Authorization header required", http.StatusUnauthorized)
			return
		}

		// HTTP authentication scheme names are case-insensitive. Bearer tokens
		// themselves remain exact and are compared in constant time.
		scheme, token, ok := strings.Cut(authHeader, " ")
		if !ok || !strings.EqualFold(scheme, "Bearer") {
			http.Error(w, "Invalid authorization format, expected Bearer token", http.StatusUnauthorized)
			return
		}
		token = strings.TrimLeft(token, " ")
		if strings.ContainsAny(token, " \t\r\n") {
			http.Error(w, "Invalid API key", http.StatusUnauthorized)
			return
		}
		// Use constant-time comparison to prevent timing attacks
		if subtle.ConstantTimeCompare([]byte(token), []byte(t.config.APIKey)) != 1 {
			http.Error(w, "Invalid API key", http.StatusUnauthorized)
			return
		}

		next.ServeHTTP(w, r)
	})
}

func (t *HTTPTransport) handleMCP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Allow", "GET, POST, DELETE")
	switch r.Method {
	case http.MethodPost:
		t.handleMCPPost(w, r)
	case http.MethodGet:
		if _, ok := t.requireHTTPSession(w, r); !ok {
			return
		}
		if !acceptsMediaType(r.Header.Values("Accept"), "text/event-stream") {
			http.Error(w, "Accept must include text/event-stream", http.StatusNotAcceptable)
			return
		}
		http.Error(w, "Standalone SSE stream is not supported", http.StatusMethodNotAllowed)
	case http.MethodDelete:
		t.handleMCPDelete(w, r)
	default:
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
	}
}

func (t *HTTPTransport) handleMCPPost(w http.ResponseWriter, r *http.Request) {
	if !acceptsMediaType(r.Header.Values("Accept"), "application/json") ||
		!acceptsMediaType(r.Header.Values("Accept"), "text/event-stream") {
		http.Error(w, "Accept must include application/json and text/event-stream", http.StatusNotAcceptable)
		return
	}
	if !hasJSONContentType(r.Header.Get("Content-Type")) {
		http.Error(w, "Content-Type must be application/json encoded as UTF-8", http.StatusUnsupportedMediaType)
		return
	}
	if !validMCPProtocolVersionHeader(r.Header.Values("MCP-Protocol-Version")) {
		http.Error(w, "Invalid or unsupported MCP-Protocol-Version", http.StatusBadRequest)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, MaxJSONRPCMessageBytes)
	body, err := io.ReadAll(r.Body)
	if err != nil {
		status := http.StatusBadRequest
		if _, ok := errors.AsType[*http.MaxBytesError](err); ok {
			status = http.StatusRequestEntityTooLarge
		}
		writeHTTPProtocolError(w, status, ErrCodeInvalidRequest, invalidRequestMessage)
		return
	}
	msg, err := DecodeRequest(body)
	if err != nil {
		var readErr *MessageReadError
		if !errors.As(err, &readErr) {
			readErr = newRequestReadError(ErrCodeInvalidRequest, invalidRequestMessage, err)
		}
		writeHTTPProtocolError(w, http.StatusBadRequest, readErr.Code, readErr.Message)
		return
	}
	initialize := msg.Method == "initialize"
	if initialize {
		if _, present, valid := parseMCPSessionHeader(r.Header.Values("MCP-Session-Id")); present || !valid {
			http.Error(w, "MCP-Session-Id is not valid on initialize", http.StatusBadRequest)
			return
		}
	} else {
		scope, ok := t.requireHTTPSession(w, r)
		if !ok {
			return
		}
		msg.ClientScope = scope
	}
	// Streamable HTTP explicitly does not equate a disconnected response stream
	// with MCP cancellation. Preserve request values while removing its deadline
	// and cancellation; explicit notifications and client/session lifetime own
	// cancellation after admission.
	msg.Context = context.WithoutCancel(r.Context())

	if t.handler == nil {
		http.Error(w, "Handler not set", http.StatusInternalServerError)
		return
	}

	response, err := t.handler(msg)
	notification := len(bytes.TrimSpace(msg.ID)) == 0
	if initialize && err == nil && !notification && response != nil && response.Error == nil {
		sessionID, sessionErr := t.createHTTPSession()
		if sessionErr != nil {
			http.Error(w, sessionErr.Error(), http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("MCP-Session-Id", sessionID)
	}
	if notification {
		if err != nil {
			writeHTTPProtocolError(w, http.StatusInternalServerError, ErrCodeInternalError, err.Error())
			return
		}
		w.WriteHeader(http.StatusAccepted)
		return
	}
	if err != nil {
		if errors.Is(err, ErrRequestCancelled) {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		response = &Message{
			JSONRPC: "2.0",
			ID:      msg.ID,
			Error: &ErrorObj{
				Code:    ErrCodeInternalError,
				Message: err.Error(),
			},
		}
	}

	if response == nil {
		response = &Message{
			JSONRPC: "2.0",
			ID:      msg.ID,
			Error: &ErrorObj{
				Code:    ErrCodeInternalError,
				Message: "request handler returned no response",
			},
		}
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(response); err != nil {
		log.Printf("Error encoding response: %v", err)
	}
}

func (t *HTTPTransport) handleMCPDelete(w http.ResponseWriter, r *http.Request) {
	sessionID, present, valid := parseMCPSessionHeader(r.Header.Values("MCP-Session-Id"))
	if !present || !valid {
		http.Error(w, "valid MCP-Session-Id is required", http.StatusBadRequest)
		return
	}

	t.sessionMu.Lock()
	t.pruneExpiredHTTPSessionsLocked(time.Now())
	session, ok := t.sessions[sessionID]
	if ok {
		delete(t.sessions, sessionID)
	}
	t.sessionMu.Unlock()
	if !ok {
		http.Error(w, "MCP session not found", http.StatusNotFound)
		return
	}
	session.scope.Close()
	w.WriteHeader(http.StatusNoContent)
}

func (t *HTTPTransport) requireHTTPSession(w http.ResponseWriter, r *http.Request) (*ClientScope, bool) {
	sessionID, present, valid := parseMCPSessionHeader(r.Header.Values("MCP-Session-Id"))
	if !present || !valid {
		http.Error(w, "valid MCP-Session-Id is required", http.StatusBadRequest)
		return nil, false
	}

	t.sessionMu.Lock()
	now := time.Now()
	t.pruneExpiredHTTPSessionsLocked(now)
	session, ok := t.sessions[sessionID]
	if ok {
		session.lastUsed = now
	}
	t.sessionMu.Unlock()
	if !ok {
		http.Error(w, "MCP session not found", http.StatusNotFound)
		return nil, false
	}
	return session.scope, true
}

func parseMCPSessionHeader(values []string) (sessionID string, present, valid bool) {
	if len(values) == 0 {
		return "", false, true
	}
	if len(values) != 1 {
		return "", true, false
	}
	sessionID = values[0]
	if sessionID == "" || len(sessionID) > maxSessionIDLength || strings.TrimSpace(sessionID) != sessionID || strings.Contains(sessionID, ",") {
		return "", true, false
	}
	for i := range len(sessionID) {
		if sessionID[i] < 0x21 || sessionID[i] > 0x7e {
			return "", true, false
		}
	}
	return sessionID, true, true
}

func (t *HTTPTransport) createHTTPSession() (string, error) {
	var random [sessionIDByteLength]byte
	for range 4 {
		if _, err := rand.Read(random[:]); err != nil {
			return "", fmt.Errorf("generate MCP session ID: %w", err)
		}
		sessionID := base64.RawURLEncoding.EncodeToString(random[:])
		t.sessionMu.Lock()
		if t.closed.Load() {
			t.sessionMu.Unlock()
			return "", ErrTransportClosed
		}
		now := time.Now()
		t.pruneExpiredHTTPSessionsLocked(now)
		if len(t.sessions) >= maxHTTPSessions {
			t.sessionMu.Unlock()
			return "", fmt.Errorf("MCP session capacity reached")
		}
		if _, exists := t.sessions[sessionID]; !exists {
			t.sessions[sessionID] = &httpSession{scope: NewClientScope(), lastUsed: now}
			t.sessionMu.Unlock()
			return sessionID, nil
		}
		t.sessionMu.Unlock()
	}
	return "", fmt.Errorf("generate unique MCP session ID")
}

func (t *HTTPTransport) pruneExpiredHTTPSessionsLocked(now time.Time) {
	cutoff := now.Add(-httpSessionTTL)
	for sessionID, session := range t.sessions {
		if session.lastUsed.Before(cutoff) {
			delete(t.sessions, sessionID)
			session.scope.Close()
		}
	}
}

func (t *HTTPTransport) closeHTTPSessions() {
	t.sessionMu.Lock()
	sessions := t.sessions
	t.sessions = make(map[string]*httpSession)
	t.sessionMu.Unlock()
	for _, session := range sessions {
		session.scope.Close()
	}
}

func acceptsMediaType(values []string, target string) bool {
	for _, value := range values {
		for item := range strings.SplitSeq(value, ",") {
			mediaType, parameters, err := mime.ParseMediaType(strings.TrimSpace(item))
			if err != nil || !strings.EqualFold(mediaType, target) {
				continue
			}
			if quality, ok := parameters["q"]; ok {
				parsed, err := strconv.ParseFloat(quality, 64)
				if err != nil || parsed <= 0 {
					continue
				}
			}
			return true
		}
	}
	return false
}

func hasJSONContentType(value string) bool {
	mediaType, parameters, err := mime.ParseMediaType(value)
	if err != nil || !strings.EqualFold(mediaType, "application/json") {
		return false
	}
	charset, ok := parameters["charset"]
	return !ok || strings.EqualFold(charset, "utf-8")
}

func validMCPProtocolVersionHeader(values []string) bool {
	if len(values) == 0 {
		return true
	}
	if len(values) != 1 {
		return false
	}
	version := strings.TrimSpace(values[0])
	return version == MCPProtocolVersionCurrent || version == mcpProtocolVersionFallback
}

func writeHTTPProtocolError(w http.ResponseWriter, status, code int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(&Message{
		JSONRPC: "2.0",
		ID:      json.RawMessage("null"),
		Error: &ErrorObj{
			Code:    code,
			Message: message,
		},
	}); err != nil {
		log.Printf("Error encoding JSON-RPC protocol error: %v", err)
	}
}

// handleHealth handles GET /health for health checks
func (t *HTTPTransport) handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(map[string]any{
		"status":      "ok",
		"server_time": time.Now().UTC().Format(time.RFC3339),
	}); err != nil {
		log.Printf("Error encoding health response: %v", err)
	}
}

// handleMetrics handles GET /metrics for Prometheus-style metrics exposition.
// Exposes MCP request metrics and the live Go goroutine count in Prometheus format.
func (t *HTTPTransport) handleMetrics(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	t.metrics.SetGauge("go_goroutines", "", float64(runtime.NumGoroutine()))
	if err := t.metrics.WritePrometheus(w); err != nil {
		log.Printf("Error writing metrics: %v", err)
	}
}

// Serve starts the HTTP server and handles messages.
// If TLSCertFile and TLSKeyFile are configured, the server uses TLS.
// Otherwise, it serves plain HTTP.
func (t *HTTPTransport) Serve(handler func(*Message) (*Message, error)) error {
	tlsConfig, err := t.loadTLSConfig()
	if err != nil {
		return err
	}

	// Registration and Close form one lifecycle decision. Holding this lock
	// through bind guarantees that either Serve registers first and Close shuts
	// that listener down, or Close wins and no later listener side effect occurs.
	t.serveMu.Lock()
	if t.closed.Load() {
		t.serveMu.Unlock()
		return ErrTransportClosed
	}
	t.handler = handler

	var listener net.Listener

	if t.config.SocketPath != "" {
		listener, err = t.listenUnixSocket()
		if err != nil {
			t.serveMu.Unlock()
			return err
		}
		log.Printf("Streamable HTTP transport listening on unix:%s", t.config.SocketPath)
	} else {
		// Use TCP
		listener, err = net.Listen("tcp", t.config.Address)
		if err != nil {
			t.serveMu.Unlock()
			return fmt.Errorf("failed to listen on %s: %w", t.config.Address, err)
		}
		log.Printf("Streamable HTTP transport listening on %s", t.config.Address)
	}

	if tlsConfig != nil {
		listener = tls.NewListener(listener, tlsConfig)
		log.Printf("TLS enabled with certificate: %s", t.config.TLSCertFile)
	}
	t.serveMu.Unlock()

	if err := t.server.Serve(listener); err != nil && err != http.ErrServerClosed {
		return err
	}
	return nil
}

func (t *HTTPTransport) cleanupUnixSocket() error {
	if t.config.SocketPath == "" {
		return nil
	}
	t.socketMu.Lock()
	defer t.socketMu.Unlock()
	if !t.socketOwned {
		return nil
	}
	t.socketOwned = false
	return removeUnixSocketIfIdentity(t.config.SocketPath, t.socketIdentity)
}

func (t *HTTPTransport) loadTLSConfig() (*tls.Config, error) {
	certificateConfigured := t.config.TLSCertFile != ""
	keyConfigured := t.config.TLSKeyFile != ""
	if !certificateConfigured && !keyConfigured {
		return nil, nil
	}
	if certificateConfigured != keyConfigured {
		return nil, fmt.Errorf("TLS certificate and private key must be configured together")
	}
	certificate, err := tls.LoadX509KeyPair(t.config.TLSCertFile, t.config.TLSKeyFile)
	if err != nil {
		return nil, fmt.Errorf("failed to load TLS certificate: %w", err)
	}
	return &tls.Config{
		Certificates: []tls.Certificate{certificate},
		MinVersion:   tls.VersionTLS12,
	}, nil
}

// IsTLSEnabled returns true if TLS is configured for this transport.
func (t *HTTPTransport) IsTLSEnabled() bool {
	return t.config.TLSCertFile != "" && t.config.TLSKeyFile != ""
}

// IsAuthEnabled returns true if API key authentication is configured.
func (t *HTTPTransport) IsAuthEnabled() bool {
	return t.config.APIKey != ""
}

// Metrics returns the metrics registry for this transport.
// This allows the MCP server to record request metrics for tool invocations.
func (t *HTTPTransport) Metrics() *MetricsRegistry {
	return t.metrics
}

// IsRateLimitEnabled returns true if rate limiting is configured.
func (t *HTTPTransport) IsRateLimitEnabled() bool {
	return t.rateLimiter != nil
}

// ReadMessage is provided for Transport interface compatibility but is not the
// primary message handling pattern for HTTPTransport. The HTTP transport uses
// the callback-based Serve(handler) pattern instead, where messages are delivered
// directly to the handler function. This method returns immediately with an error
// explaining the correct usage pattern.
func (t *HTTPTransport) ReadMessage() (*Message, error) {
	// HTTP transport uses callback pattern via Serve(handler).
	// Return immediately with a clear error rather than blocking.
	return nil, fmt.Errorf("ReadMessage is not supported by HTTPTransport: use Serve(handler) callback pattern instead")
}

// WriteMessage is retained only to satisfy Transport. Streamable HTTP writes
// the correlated response synchronously from the request handler.
func (t *HTTPTransport) WriteMessage(_ *Message) error {
	if t.closed.Load() {
		return ErrTransportClosed
	}
	return fmt.Errorf("WriteMessage is not supported by synchronous Streamable HTTP")
}

// Close closes the HTTP transport and shuts down the server gracefully.
// It waits up to eight seconds for in-flight HTTP requests to finish.
func (t *HTTPTransport) Close() error {
	t.closeOnce.Do(func() {
		t.serveMu.Lock()
		t.closed.Store(true)
		t.serveMu.Unlock()
		t.closeHTTPSessions()

		ctx, cancel := context.WithTimeout(context.Background(), t.shutdownTimeout)
		shutdownErr := t.server.Shutdown(ctx)
		cancel()
		if shutdownErr != nil {
			// Shutdown preserves active and newly accepted connections. Once the
			// bounded grace period expires, force-close every remaining connection
			// so Close actually releases transport-owned resources.
			forceErr := t.server.Close()
			t.closeErr = fmt.Errorf("failed to gracefully shutdown server: %w; forced close completed", shutdownErr)
			if forceErr != nil && !errors.Is(forceErr, http.ErrServerClosed) {
				t.closeErr = errors.Join(t.closeErr, fmt.Errorf("failed to force-close server: %w", forceErr))
			}
		}

		if err := t.cleanupUnixSocket(); err != nil {
			t.closeErr = errors.Join(t.closeErr, err)
		}
	})

	return t.closeErr
}

// IsClosed returns true if the transport has been closed.
func (t *HTTPTransport) IsClosed() bool {
	return t.closed.Load()
}

// Ensure HTTPTransport implements Transport interface
var _ Transport = (*HTTPTransport)(nil)
