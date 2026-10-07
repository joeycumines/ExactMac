// Copyright 2025 Joseph Cumines

// Package server implements a Model Context Protocol (MCP) server that proxies
// macOS automation requests to a gRPC backend. It exposes 29 CUA-aligned tools
// across 6 categories: core CUA input, application management, element interaction,
// window management, utility (clipboard, scripting, display), and macros.
//
// The server supports both stdio (for MCP clients like Claude Desktop) and
// Streamable HTTP transport (for web-based integrations). All tools follow MCP
// specification version 2025-11-25 with soft-error semantics (isError field
// in ToolResult rather than RPC-level failures).
//
// See docs/ai-artifacts/10-api-reference.md for comprehensive tool documentation.
package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"github.com/joeycumines/ExactMac/internal/config"
	"github.com/joeycumines/ExactMac/internal/transport"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
)

// MCP server constants.
const (
	// displayInfoTimeout is the timeout for fetching display information.
	displayInfoTimeout = 5 * time.Second

	// maxGRPCReceiveMessageBytes matches the signed 32-bit message ceiling used
	// by gRPC senders. Public responses can contain encoded screenshots and
	// clipboard images, so the client's implicit 4 MiB receive default is not a
	// coherent limit for the generated contract.
	maxGRPCReceiveMessageBytes = 1<<31 - 1
)

// MCPServer implements the Model Context Protocol (MCP) server.
// It connects to a gRPC backend and exposes 29 CUA-aligned MCP tools for macOS automation.
// The server supports both stdio and Streamable HTTP transports.
//
//lint:ignore BETTERALIGN struct is intentionally ordered for clarity
type MCPServer struct {
	client         pb.ExactMacClient
	opsClient      longrunningpb.OperationsClient
	httpTransport  *transport.HTTPTransport
	auditLogger    *AuditLogger
	admission      *requestAdmission
	ctx            context.Context
	cfg            *config.Config
	conn           *grpc.ClientConn
	tools          map[string]*Tool
	activeRequests map[activeRequestKey]*activeRequest
	mutationGate   *mutationExecutor
	cancel         context.CancelFunc
	mutationOnce   sync.Once
	admissionOnce  sync.Once
	activeMu       sync.Mutex
	mu             sync.RWMutex
}

// Tool represents an MCP tool with its handler, schema, and metadata.
// Each tool is registered with the server and exposed via the MCP protocol.
//
//lint:ignore BETTERALIGN struct is intentionally ordered for clarity
type Tool struct {
	Handler       func(*ToolCall) (*ToolResult, error)
	ValidateInput func(map[string]any) error
	InputSchema   map[string]any
	// Annotations are optional MCP tool hints (MCP 2025-11-25). When nil,
	// sensible defaults are derived from MutationPolicy via mcpAnnotations.
	// Set explicitly only to override a default (e.g. destructiveHint:true).
	Annotations    map[string]any
	Name           string
	Description    string
	MutationPolicy toolMutationPolicy
}

// mcpAnnotations returns the MCP tool hints surfaced in tools/list. When the
// tool sets explicit Annotations they win; otherwise the hints are derived
// from MutationPolicy. All desktop-automation tools interact with live,
// externally-owned applications, so openWorldHint is true for every tool.
func (t *Tool) mcpAnnotations() map[string]any {
	if len(t.Annotations) > 0 {
		return t.Annotations
	}
	switch t.MutationPolicy {
	case mutationPolicyReadOnly:
		// Read-only traversal: repeating the call yields the same observed
		// state and no side effect.
		return map[string]any{
			"readOnlyHint":    true,
			"destructiveHint": false,
			"idempotentHint":  true,
			"openWorldHint":   true,
		}
	default:
		// Mutating (exclusive or clipboard-write): state-changing and not
		// guaranteed idempotent. Non-destructive by default; genuinely
		// destructive tools (delete/execute/close) override destructiveHint.
		return map[string]any{
			"readOnlyHint":    false,
			"destructiveHint": false,
			"idempotentHint":  false,
			"openWorldHint":   true,
		}
	}
}

type toolMutationPolicy uint8

const (
	mutationPolicyUnspecified toolMutationPolicy = iota
	mutationPolicyReadOnly
	mutationPolicyExclusive
	mutationPolicyClipboard
)

func (t *Tool) requiresExclusiveMutation(arguments json.RawMessage) bool {
	if t == nil {
		return true
	}
	switch t.MutationPolicy {
	case mutationPolicyReadOnly:
		return false
	case mutationPolicyClipboard:
		var params struct {
			Action string `json:"action"`
		}
		if err := json.Unmarshal(arguments, &params); err != nil {
			return true
		}
		return params.Action != "get"
	case mutationPolicyExclusive, mutationPolicyUnspecified:
		return true
	default:
		return true
	}
}

func (s *MCPServer) physicalDesktopMutations() *mutationExecutor {
	s.mutationOnce.Do(func() {
		if s.mutationGate == nil {
			s.mutationGate = newMutationExecutor(s.ctx, maxQueuedPhysicalDesktopMutations)
		}
	})
	return s.mutationGate
}

// ToolCall represents an incoming MCP tool invocation request.
// It contains the tool name and the JSON-encoded arguments.
type ToolCall struct {
	Context   context.Context `json:"-"`
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
}

func (s *MCPServer) newToolCallContext(requestCtx context.Context) (context.Context, context.CancelFunc) {
	serverCtx := s.ctx
	if serverCtx == nil {
		serverCtx = context.Background()
	}
	ctx, cancel := context.WithCancel(serverCtx)
	if requestCtx == nil {
		return ctx, cancel
	}
	stopRequestCancellation := context.AfterFunc(requestCtx, cancel)
	return ctx, func() {
		stopRequestCancellation()
		cancel()
	}
}

// toolCallContext is the ONE place every handler's context comes from, which is why the
// agent's reason is attached here rather than in twenty handlers.
//
// One seam means no tool can forget the reason, and it means the reason travels on the wire
// the server reads it from rather than on a field some handler remembered to set. A handler
// that built its own context from s.ctx would silently lose it.
func (s *MCPServer) toolCallContext(call *ToolCall) context.Context {
	base := s.baseCallContext(call)
	return withAgentReason(base, call)
}

func (s *MCPServer) baseCallContext(call *ToolCall) context.Context {
	if call != nil && call.Context != nil {
		return call.Context
	}
	if s.ctx != nil {
		return s.ctx
	}
	return context.Background()
}

// ToolResult represents the result of an MCP tool invocation.
// It contains one or more content items (text, images, etc.) and an optional error flag.
type ToolResult struct {
	Content []Content `json:"content"`
	IsError bool      `json:"isError,omitempty"`
}

// Content represents a content item in an MCP tool result.
//
// For type="text":
//   - Text: the text content
//
// For type="image":
//   - Data: base64-encoded image bytes (no data-URI prefix)
//   - MimeType: MIME type (e.g., "image/png", "image/jpeg")
type Content struct {
	Type     string `json:"type"`
	Text     string `json:"text,omitempty"`
	Data     string `json:"data,omitempty"`
	MimeType string `json:"mimeType,omitempty"`
}

// MCPInitializeParams represents the params of an MCP initialize request.
// Per MCP spec, clients send protocolVersion, clientInfo, and capabilities.
type MCPInitializeParams struct {
	Capabilities    map[string]json.RawMessage `json:"capabilities"`
	ClientInfo      *MCPClientInfo             `json:"clientInfo"`
	ProtocolVersion string                     `json:"protocolVersion"`
}

// MCPClientInfo represents client information in an initialize request.
type MCPClientInfo struct {
	Name    string `json:"name"`
	Version string `json:"version"`
}

// Supported MCP protocol versions.
const (
	// mcpProtocolVersionCurrent is the current MCP specification version.
	mcpProtocolVersionCurrent = "2025-11-25"
)

// NewMCPServer creates a new MCP server with the given configuration.
// It initializes the gRPC connection, audit logger, and registers all tools.
// Returns an error if gRPC connection or audit logger initialization fails.
func NewMCPServer(cfg *config.Config) (*MCPServer, error) {
	if cfg == nil {
		return nil, fmt.Errorf("configuration is required")
	}
	if _, err := physicalInputRequestTimeout(cfg); err != nil {
		return nil, err
	}
	globalRequestLimit := cfg.MaxConcurrentRequests
	if globalRequestLimit == 0 {
		globalRequestLimit = defaultMaxConcurrentMCPRequests
	}
	clientRequestLimit := cfg.MaxConcurrentRequestsPerClient
	if clientRequestLimit == 0 {
		clientRequestLimit = defaultMaxConcurrentMCPRequestsPerClient
	}
	admission, err := newRequestAdmission(globalRequestLimit, clientRequestLimit)
	if err != nil {
		return nil, fmt.Errorf("invalid request admission configuration: %w", err)
	}
	ctx, cancel := context.WithCancel(context.Background())

	// Initialize audit logger
	auditLogger, err := NewAuditLogger(cfg.AuditLogFile)
	if err != nil {
		cancel()
		return nil, fmt.Errorf("failed to initialize audit logger: %w", err)
	}

	if cfg.RequestTimeout > 0 {
		requestTimeoutSeconds = cfg.RequestTimeout
	}

	s := &MCPServer{
		cfg:            cfg,
		ctx:            ctx,
		cancel:         cancel,
		tools:          make(map[string]*Tool),
		activeRequests: make(map[activeRequestKey]*activeRequest),
		auditLogger:    auditLogger,
		admission:      admission,
	}

	// Initialize gRPC connection
	if err := s.initGRPC(); err != nil {
		auditLogger.Close()
		cancel()
		return nil, fmt.Errorf("failed to initialize gRPC: %w", err)
	}

	// Register tools
	s.registerTools()

	return s, nil
}

// validateUnixSocketEndpoint validates only static configuration before the
// lazy gRPC client is created. The socket may not exist yet (for example while
// launchd is starting the server), and grpc.NewClient intentionally defers
// connection establishment until the first RPC. Runtime pathname checks would
// create a startup race and still would not establish a pathname lease.
func validateUnixSocketEndpoint(path string) error {
	if !filepath.IsAbs(path) {
		return fmt.Errorf("unix socket path must be absolute: %q", path)
	}
	pathBytes := len([]byte(path))
	if pathBytes >= 104 {
		return fmt.Errorf("unix socket path is too long: %d bytes", pathBytes)
	}
	info, err := os.Lstat(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("stat unix socket %q: %w", path, err)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("unix socket path must not be a symlink: %q", path)
	}
	if info.Mode()&os.ModeSocket == 0 {
		return fmt.Errorf("unix socket path is not a socket: %q", path)
	}
	if info.Mode().Perm() != 0600 {
		return fmt.Errorf("unix socket path must have mode 0600: %q has %04o", path, info.Mode().Perm())
	}
	status, ok := info.Sys().(*syscall.Stat_t)
	if !ok || status.Uid != uint32(os.Geteuid()) {
		return fmt.Errorf("unix socket path is not owned by the current user: %q", path)
	}
	return nil
}

// initGRPC initializes the gRPC connection
func (s *MCPServer) initGRPC() error {
	opts, err := grpcClientDialOptions(s.cfg)

	if s.cfg.ServerSocketPath != "" {
		if err := validateUnixSocketEndpoint(s.cfg.ServerSocketPath); err != nil {
			return err
		}
	}

	if err != nil {
		return err
	}

	// Determine the server address
	var serverAddr string
	if s.cfg.ServerSocketPath != "" {
		// Use Unix socket for connection
		serverAddr = "unix://" + s.cfg.ServerSocketPath
		log.Printf("Connecting to gRPC server via Unix socket: %s", s.cfg.ServerSocketPath)
	} else {
		serverAddr = s.cfg.ServerAddr
		log.Printf("Connecting to gRPC server at: %s", serverAddr)
	}

	conn, err := grpc.NewClient(serverAddr, opts...)
	if err != nil {
		return fmt.Errorf("failed to create client: %w", err)
	}

	s.conn = conn
	s.client = pb.NewExactMacClient(conn)
	s.opsClient = longrunningpb.NewOperationsClient(conn)

	return nil
}

func grpcClientDialOptions(cfg *config.Config) ([]grpc.DialOption, error) {
	opts := []grpc.DialOption{
		grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(maxGRPCReceiveMessageBytes)),
	}
	if cfg.ServerSocketPath != "" {
		// A Unix-socket client that does not name its own socket is unattributable, and the
		// server refuses every capability on an unattributable connection. Naming it here
		// rather than in a transport-specific branch means there is one code path and no
		// configuration in which the client silently loses the ability to ask for anything.
		identity, err := newPeerIdentityDialer(cfg.ServerSocketPath)
		if err != nil {
			return nil, err
		}
		opts = append(opts, grpc.WithContextDialer(identity.dial))
	}
	if cfg.ServerTLS {
		creds := credentials.NewTLS(nil)
		if cfg.ServerCertFile != "" {
			var err error
			creds, err = credentials.NewClientTLSFromFile(cfg.ServerCertFile, "")
			if err != nil {
				return nil, fmt.Errorf("failed to load TLS cert: %w", err)
			}
		}
		opts = append(opts, grpc.WithTransportCredentials(creds))
	} else {
		opts = append(opts, grpc.WithTransportCredentials(insecure.NewCredentials()))
	}
	return opts, nil
}

// Shutdown gracefully shuts down the server and releases all resources.
// It closes the HTTP transport, audit logger, and gRPC connection and returns
// every cleanup failure so the production process cannot report false success.
func (s *MCPServer) Shutdown() error {
	var shutdownErr error
	drained := s.requestAdmissionController().beginDrain()

	// Cancel request work before waiting for transports to drain. Otherwise an
	// active handler can hold HTTP graceful shutdown until its full tool timeout.
	if s.cancel != nil {
		s.cancel()
	}

	// Close HTTP transport if active
	s.mu.RLock()
	httpTransport := s.httpTransport
	s.mu.RUnlock()
	if httpTransport != nil {
		if err := httpTransport.Close(); err != nil {
			shutdownErr = errors.Join(shutdownErr, fmt.Errorf("close HTTP transport: %w", err))
		}
	}

	// Request handlers retain the audit logger and gRPC connection. Do not close
	// either dependency until cancellation and transport teardown have joined
	// every admitted request lease.
	<-drained

	// Close audit logger
	if s.auditLogger != nil {
		if err := s.auditLogger.Close(); err != nil {
			shutdownErr = errors.Join(shutdownErr, fmt.Errorf("close audit logger: %w", err))
		}
	}

	// Close gRPC connection
	if s.conn != nil {
		if err := s.conn.Close(); err != nil {
			shutdownErr = errors.Join(shutdownErr, fmt.Errorf("close gRPC connection: %w", err))
		}
	}
	log.Println("Shutting down MCP server...")
	return shutdownErr
}

// Serve starts serving MCP requests over the given stdio transport.
// It blocks until the transport is closed or the server context is cancelled.
func (s *MCPServer) Serve(tr *transport.StdioTransport) error {
	log.Println("MCP server starting...")

	// Use a goroutine for reading messages to allow context cancellation
	type readResult struct {
		msg *transport.Message
		err error
	}
	msgCh := make(chan readResult)

	go func() {
		for {
			msg, err := tr.ReadMessage()
			select {
			case msgCh <- readResult{msg, err}:
				if err != nil {
					if _, ok := errors.AsType[*transport.MessageReadError](err); ok {
						continue
					}
					return
				}
			case <-s.ctx.Done():
				return // Exit reader goroutine on context cancellation
			}
		}
	}()

	for {
		select {
		case <-s.ctx.Done():
			log.Println("MCP server stopping (context cancelled)")
			tr.Close() // Close transport to unblock reader goroutine
			return nil
		case result := <-msgCh:
			if result.err != nil {
				if errors.Is(result.err, transport.ErrTransportClosed) {
					log.Println("MCP server stopping (transport closed)")
					return nil
				}
				if errors.Is(result.err, io.EOF) {
					log.Println("MCP server stopping (EOF)")
					return nil
				}
				if readErr, ok := errors.AsType[*transport.MessageReadError](result.err); ok {
					if err := tr.WriteMessage(&transport.Message{
						JSONRPC: "2.0",
						ID:      json.RawMessage("null"),
						Error: &transport.ErrorObj{
							Code:    readErr.Code,
							Message: readErr.Message,
						},
					}); err != nil {
						return fmt.Errorf("write JSON-RPC frame error: %w", err)
					}
					continue
				}
				return fmt.Errorf("read stdio message: %w", result.err)
			}
			prepared, response := s.prepareMCPMessage(result.msg)
			if prepared != nil {
				// Admission and active-request registration happen synchronously
				// before this goroutine exists, so stdio concurrency is bounded by
				// the configured request budget.
				go s.handlePreparedStdioMessage(tr, prepared)
				continue
			}
			if response != nil {
				if err := tr.WriteMessage(response); err != nil {
					return fmt.Errorf("write stdio admission response: %w", err)
				}
			}
		}
	}
}

// ServeHTTP starts serving MCP requests over the Streamable HTTP transport.
// It blocks until the transport is closed or an error occurs.
func (s *MCPServer) ServeHTTP(tr *transport.HTTPTransport) error {
	log.Println("MCP server starting with Streamable HTTP transport...")
	s.mu.Lock()
	s.httpTransport = tr
	s.mu.Unlock()
	return tr.Serve(s.handleHTTPMessage)
}
