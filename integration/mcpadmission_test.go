// Copyright 2026 Joseph Cumines

package integration

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"sort"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/status"
)

const requestAdmissionBusyCode = -32000

type requestAdmissionBackend struct {
	pb.UnimplementedExactMacServer
	entered chan string
	exited  chan string
	calls   atomic.Int64
}

func (s *requestAdmissionBackend) ListDisplays(
	context.Context,
	*pb.ListDisplaysRequest,
) (*pb.ListDisplaysResponse, error) {
	return &pb.ListDisplaysResponse{}, nil
}

func (s *requestAdmissionBackend) ListWindows(
	ctx context.Context,
	request *pb.ListWindowsRequest,
) (*pb.ListWindowsResponse, error) {
	label := request.GetParent()
	s.calls.Add(1)
	s.entered <- label
	<-ctx.Done()
	s.exited <- label
	return nil, status.FromContextError(ctx.Err()).Err()
}

type requestAdmissionHTTPResult struct {
	result sessionHTTPResult
	id     int
}

func TestMCPRequestAdmission_ProductionTransports(t *testing.T) {
	t.Run("HTTP global per-client cancellation and session close", testMCPRequestAdmissionHTTP)
	t.Run("stdio pre-spawn bound and cancellation", testMCPRequestAdmissionStdio)
}

func testMCPRequestAdmissionHTTP(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	grpcAddress, backend, stopBackend := startRequestAdmissionBackend(t)
	defer stopBackend()
	overrides := requestAdmissionProcessOverrides("4", "2")
	_, baseURL, stopMCP := startMCPTestServerWithOverrides(t, ctx, grpcAddress, overrides)
	defer stopMCP()

	client := &http.Client{Timeout: 10 * time.Second}
	sessionA := initializeHTTPSession(t, ctx, client, baseURL, 1)
	sessionB := initializeHTTPSession(t, ctx, client, baseURL, 2)
	sessionC := initializeHTTPSession(t, ctx, client, baseURL, 3)

	pendingA := []<-chan requestAdmissionHTTPResult{
		startRequestAdmissionHTTPCall(t, ctx, client, baseURL, sessionA, 101, "applications/http-a-1"),
		startRequestAdmissionHTTPCall(t, ctx, client, baseURL, sessionA, 102, "applications/http-a-2"),
	}
	requireRequestAdmissionBackendLabels(t, ctx, backend.entered, "applications/http-a-1", "applications/http-a-2")
	baselineCalls := backend.calls.Load()
	overflowA := callRequestAdmissionHTTP(t, ctx, client, baseURL, sessionA, 103, "applications/http-a-overflow")
	assertRequestAdmissionHTTPBusy(t, overflowA, 103)
	if got := backend.calls.Load(); got != baselineCalls {
		t.Fatalf("same-client overflow backend calls=%d, want unchanged %d", got, baselineCalls)
	}

	pendingB := []<-chan requestAdmissionHTTPResult{
		startRequestAdmissionHTTPCall(t, ctx, client, baseURL, sessionB, 201, "applications/http-b-1"),
		startRequestAdmissionHTTPCall(t, ctx, client, baseURL, sessionB, 202, "applications/http-b-2"),
	}
	requireRequestAdmissionBackendLabels(t, ctx, backend.entered, "applications/http-b-1", "applications/http-b-2")
	baselineCalls = backend.calls.Load()
	overflowC := callRequestAdmissionHTTP(t, ctx, client, baseURL, sessionC, 301, "applications/http-c-overflow")
	assertRequestAdmissionHTTPBusy(t, overflowC, 301)
	if got := backend.calls.Load(); got != baselineCalls {
		t.Fatalf("global overflow backend calls=%d, want unchanged %d", got, baselineCalls)
	}

	for _, requestID := range []int{101, 102} {
		sendRequestAdmissionHTTPCancellation(t, ctx, client, baseURL, sessionA, requestID)
	}
	requireRequestAdmissionBackendLabels(t, ctx, backend.exited, "applications/http-a-1", "applications/http-a-2")
	for _, pending := range pendingA {
		assertRequestAdmissionHTTPCancelled(t, ctx, pending)
	}

	pendingC := startRequestAdmissionHTTPCall(t, ctx, client, baseURL, sessionC, 302, "applications/http-c-admitted")
	requireRequestAdmissionBackendLabels(t, ctx, backend.entered, "applications/http-c-admitted")
	terminatedB := sendSessionMCP(t, ctx, client, baseURL, http.MethodDelete, sessionB, "")
	if terminatedB.Err != nil || terminatedB.Status != http.StatusNoContent || len(terminatedB.Body) != 0 {
		t.Fatalf("terminate saturated HTTP session B status=%d body=%q error=%v", terminatedB.Status, terminatedB.Body, terminatedB.Err)
	}
	requireRequestAdmissionBackendLabels(t, ctx, backend.exited, "applications/http-b-1", "applications/http-b-2")
	for _, pending := range pendingB {
		assertRequestAdmissionHTTPCancelled(t, ctx, pending)
	}

	sendRequestAdmissionHTTPCancellation(t, ctx, client, baseURL, sessionC, 302)
	requireRequestAdmissionBackendLabels(t, ctx, backend.exited, "applications/http-c-admitted")
	assertRequestAdmissionHTTPCancelled(t, ctx, pendingC)
	requireRequestAdmissionHTTPPing(t, ctx, client, baseURL, sessionA, 401)
	requireRequestAdmissionHTTPPing(t, ctx, client, baseURL, sessionC, 402)

	for _, sessionID := range []string{sessionA, sessionC} {
		terminated := sendSessionMCP(t, ctx, client, baseURL, http.MethodDelete, sessionID, "")
		if terminated.Err != nil || terminated.Status != http.StatusNoContent || len(terminated.Body) != 0 {
			t.Fatalf("terminate HTTP session %q status=%d body=%q error=%v", sessionID, terminated.Status, terminated.Body, terminated.Err)
		}
	}
}

func testMCPRequestAdmissionStdio(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	grpcAddress, backend, stopBackend := startRequestAdmissionBackend(t)
	defer stopBackend()
	_, stdin, stdout, stopMCP := startMCPStdioProcessWithOverrides(
		t,
		ctx,
		grpcAddress,
		requestAdmissionProcessOverrides("4", "2"),
	)
	defer stopMCP()

	initialize, err := sendStdioRequest(ctx, stdin, stdout, validMCPInitializeRequest(1))
	if err != nil || initialize.Error != nil {
		t.Fatalf("stdio request-admission initialize response=%+v error=%v", initialize, err)
	}
	if err := writeStdioMessage(stdin, map[string]any{
		"jsonrpc": "2.0",
		"method":  "notifications/initialized",
	}); err != nil {
		t.Fatalf("send stdio initialized notification: %v", err)
	}

	for requestID, parent := range map[int]string{
		11: "applications/stdio-1",
		12: "applications/stdio-2",
	} {
		if err := writeStdioMessage(stdin, requestAdmissionToolRequest(requestID, parent)); err != nil {
			t.Fatalf("send stdio blocking request %d: %v", requestID, err)
		}
	}
	requireRequestAdmissionBackendLabels(t, ctx, backend.entered, "applications/stdio-1", "applications/stdio-2")
	baselineCalls := backend.calls.Load()
	overflow, err := sendStdioRequest(ctx, stdin, stdout, requestAdmissionToolRequest(13, "applications/stdio-overflow"))
	if err != nil {
		t.Fatalf("stdio overflow request: %v", err)
	}
	assertRequestAdmissionStdioBusy(t, overflow, 13)
	if got := backend.calls.Load(); got != baselineCalls {
		t.Fatalf("stdio overflow backend calls=%d, want unchanged %d", got, baselineCalls)
	}

	for _, requestID := range []int{11, 12} {
		if err := writeStdioMessage(stdin, map[string]any{
			"jsonrpc": "2.0",
			"method":  "notifications/cancelled",
			"params":  map[string]any{"requestId": requestID},
		}); err != nil {
			t.Fatalf("send stdio cancellation %d: %v", requestID, err)
		}
	}
	requireRequestAdmissionBackendLabels(t, ctx, backend.exited, "applications/stdio-1", "applications/stdio-2")

	pollContext, cancelPoll := context.WithTimeout(ctx, 5*time.Second)
	defer cancelPoll()
	nextID := 20
	if err := PollUntilContext(pollContext, 10*time.Millisecond, func() (bool, error) {
		nextID++
		response, err := sendStdioRequest(pollContext, stdin, stdout, map[string]any{
			"jsonrpc": "2.0",
			"id":      nextID,
			"method":  "ping",
		})
		if err != nil {
			return false, err
		}
		if response.Error != nil && response.Error.Code == requestAdmissionBusyCode {
			return false, nil
		}
		if response.Error != nil || string(response.ID) != fmt.Sprint(nextID) || string(response.Result) != "{}" {
			return false, fmt.Errorf("unexpected stdio recovery response: %+v", response)
		}
		return true, nil
	}); err != nil {
		t.Fatalf("stdio admission did not recover after cancellation: %v", err)
	}
	if got := backend.calls.Load(); got != baselineCalls {
		t.Fatalf("stdio recovery backend calls=%d, want unchanged %d", got, baselineCalls)
	}
}

func startRequestAdmissionBackend(t *testing.T) (string, *requestAdmissionBackend, func()) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen for request-admission backend: %v", err)
	}
	backend := &requestAdmissionBackend{
		entered: make(chan string, 16),
		exited:  make(chan string, 16),
	}
	grpcServer := grpc.NewServer()
	pb.RegisterExactMacServer(grpcServer, backend)
	serveResult := make(chan error, 1)
	go func() {
		serveResult <- grpcServer.Serve(listener)
	}()
	var stopOnce sync.Once
	stop := func() {
		stopOnce.Do(func() {
			grpcServer.Stop()
			if err := <-serveResult; err != nil && !errors.Is(err, grpc.ErrServerStopped) {
				t.Errorf("stop request-admission backend: %v", err)
			}
		})
	}
	return listener.Addr().String(), backend, stop
}

func requestAdmissionProcessOverrides(global, perClient string) map[string]string {
	return map[string]string{
		"EXACTMAC_REQUEST_TIMEOUT":               "135",
		"EXACTMAC_SERVER_CERT_FILE":              "",
		"EXACTMAC_SERVER_TLS":                    "false",
		"MCP_MAX_CONCURRENT_REQUESTS":            global,
		"MCP_MAX_CONCURRENT_REQUESTS_PER_CLIENT": perClient,
		"MCP_SHELL_COMMANDS_ENABLED":             "false",
	}
}

func startRequestAdmissionHTTPCall(
	t *testing.T,
	ctx context.Context,
	client *http.Client,
	baseURL string,
	sessionID string,
	requestID int,
	parent string,
) <-chan requestAdmissionHTTPResult {
	t.Helper()
	result := make(chan requestAdmissionHTTPResult, 1)
	payload := marshalRequestAdmissionToolRequest(t, requestID, parent)
	go func() {
		result <- requestAdmissionHTTPResult{
			id: requestID,
			result: sendSessionMCP(
				t,
				ctx,
				client,
				baseURL,
				http.MethodPost,
				sessionID,
				payload,
			),
		}
	}()
	return result
}

func callRequestAdmissionHTTP(
	t *testing.T,
	ctx context.Context,
	client *http.Client,
	baseURL string,
	sessionID string,
	requestID int,
	parent string,
) sessionHTTPResult {
	t.Helper()
	return sendSessionMCP(
		t,
		ctx,
		client,
		baseURL,
		http.MethodPost,
		sessionID,
		marshalRequestAdmissionToolRequest(t, requestID, parent),
	)
}

func marshalRequestAdmissionToolRequest(t *testing.T, requestID int, parent string) string {
	t.Helper()
	payload, err := json.Marshal(requestAdmissionToolRequest(requestID, parent))
	if err != nil {
		t.Fatalf("marshal request-admission tool request %d: %v", requestID, err)
	}
	return string(payload)
}

func requestAdmissionToolRequest(requestID int, parent string) map[string]any {
	return map[string]any{
		"jsonrpc": "2.0",
		"id":      requestID,
		"method":  "tools/call",
		"params": map[string]any{
			"name": "list_windows",
			"arguments": map[string]any{
				"app": parent,
			},
		},
	}
}

func assertRequestAdmissionHTTPBusy(t *testing.T, result sessionHTTPResult, requestID int) {
	t.Helper()
	if result.Err != nil || result.Status != http.StatusOK {
		t.Fatalf("HTTP busy request %d status=%d body=%q error=%v", requestID, result.Status, result.Body, result.Err)
	}
	var response mcpResponse
	if err := json.Unmarshal(result.Body, &response); err != nil {
		t.Fatalf("decode HTTP busy response %q: %v", result.Body, err)
	}
	if string(response.ID) != fmt.Sprint(requestID) || response.Error == nil || response.Error.Code != requestAdmissionBusyCode || response.Error.Message != "server request capacity reached" {
		t.Fatalf("HTTP busy response=%+v, want correlated -32000", response)
	}
}

func assertRequestAdmissionStdioBusy(t *testing.T, response *stdioResponse, requestID int) {
	t.Helper()
	if response == nil || string(response.ID) != fmt.Sprint(requestID) || response.Error == nil || response.Error.Code != requestAdmissionBusyCode || response.Error.Message != "server request capacity reached" {
		t.Fatalf("stdio busy response=%+v, want correlated -32000", response)
	}
}

func sendRequestAdmissionHTTPCancellation(
	t *testing.T,
	ctx context.Context,
	client *http.Client,
	baseURL string,
	sessionID string,
	requestID int,
) {
	t.Helper()
	payload := fmt.Sprintf(
		`{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":%d}}`,
		requestID,
	)
	result := sendSessionMCP(t, ctx, client, baseURL, http.MethodPost, sessionID, payload)
	if result.Err != nil || result.Status != http.StatusAccepted || len(result.Body) != 0 {
		t.Fatalf("HTTP cancellation %d status=%d body=%q error=%v", requestID, result.Status, result.Body, result.Err)
	}
}

func assertRequestAdmissionHTTPCancelled(
	t *testing.T,
	ctx context.Context,
	pending <-chan requestAdmissionHTTPResult,
) {
	t.Helper()
	select {
	case completed := <-pending:
		if completed.result.Err != nil || completed.result.Status != http.StatusNoContent || len(completed.result.Body) != 0 {
			t.Fatalf(
				"cancelled HTTP request %d status=%d body=%q error=%v",
				completed.id,
				completed.result.Status,
				completed.result.Body,
				completed.result.Err,
			)
		}
	case <-ctx.Done():
		t.Fatalf("cancelled HTTP request did not finish: %v", ctx.Err())
	}
}

func requireRequestAdmissionHTTPPing(
	t *testing.T,
	ctx context.Context,
	client *http.Client,
	baseURL string,
	sessionID string,
	requestID int,
) {
	t.Helper()
	payload := fmt.Sprintf(`{"jsonrpc":"2.0","id":%d,"method":"ping"}`, requestID)
	result := sendSessionMCP(t, ctx, client, baseURL, http.MethodPost, sessionID, payload)
	if result.Err != nil || result.Status != http.StatusOK {
		t.Fatalf("HTTP recovery ping %d status=%d body=%q error=%v", requestID, result.Status, result.Body, result.Err)
	}
	var response mcpResponse
	if err := json.Unmarshal(result.Body, &response); err != nil || response.Error != nil || string(response.ID) != fmt.Sprint(requestID) || string(response.Result) != "{}" {
		t.Fatalf("HTTP recovery ping %d response=%+v decode_error=%v body=%q", requestID, response, err, result.Body)
	}
}

func requireRequestAdmissionBackendLabels(
	t *testing.T,
	ctx context.Context,
	labels <-chan string,
	expected ...string,
) {
	t.Helper()
	actual := make([]string, 0, len(expected))
	for range expected {
		select {
		case label := <-labels:
			actual = append(actual, label)
		case <-ctx.Done():
			t.Fatalf("backend labels=%v, want %v before timeout: %v", actual, expected, ctx.Err())
		}
	}
	sort.Strings(actual)
	sort.Strings(expected)
	for index := range expected {
		if actual[index] != expected[index] {
			t.Fatalf("backend labels=%v, want %v", actual, expected)
		}
	}
}
