// Copyright 2026 Joseph Cumines

package integration

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"net"
	"net/http"
	"reflect"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

const nonApplicationMatrixUnknownField = "zzzz_func004_w5_unadvertised"

var safeNonApplicationAdmissionFixtures = map[string]map[string]any{
	"screenshot":    {},
	"click":         {"target": "desktop", "x": 0, "y": 0},
	"double_click":  {"target": "desktop", "x": 0, "y": 0},
	"type":          {"target": "desktop", "text": "w5"},
	"keypress":      {"target": "desktop", "keys": []any{"enter"}},
	"scroll":        {"target": "desktop", "x": 0, "y": 0, "scroll_x": 0, "scroll_y": 1},
	"drag":          {"target": "desktop", "path": []any{map[string]any{"x": 0, "y": 0}, map[string]any{"x": 1, "y": 1}}},
	"move":          {"target": "desktop", "x": 0, "y": 0},
	"wait":          {"duration": 0.001},
	"find_elements": {"parent": "applications/w5", "selector": "role:AXButton"},
	"click_element": {
		"parent":   "applications/w5",
		"selector": "role:AXButton",
	},
	"type_element": {
		"parent":       "applications/w5",
		"selector":     "role:AXTextField",
		"text":         "w5",
		"input_method": "ax",
	},
	"read_element": {
		"element": "applications/w5/elements/w5",
	},
	"focus_window": {
		"window": "applications/w5/windows/w5",
	},
	"move_window": {
		"window": "applications/w5/windows/w5",
		"x":      0,
		"y":      0,
	},
	"resize_window": {
		"window": "applications/w5/windows/w5",
		"width":  1,
		"height": 1,
	},
	"list_windows": {"app": "applications/w5"},
	"clipboard":    {"action": "get"},
	"run":          {"command": "0", "type": "javascript", "timeout": 1},
	"get_display":  {},
	"create_macro": {
		"display_name": "w5",
		"actions":      []any{map[string]any{"wait": map[string]any{"duration": 0.001}}},
	},
	"get_macro":     {"macro": "macros/w5"},
	"list_macros":   {},
	"update_macro":  {"macro": "macros/w5", "display_name": "w5"},
	"delete_macro":  {"macro": "macros/w5"},
	"execute_macro": {"macro": "macros/w5"},
	"list_grants":   {},
	"preauthorize": {
		"reason":             "w5",
		"capabilities":       []any{"observation.window"},
		"requested_lifetime": map[string]any{"seconds": 60},
	},
}

var safeNonApplicationFirstRPC = map[string]string{
	"screenshot":    pb.ExactMac_CaptureScreenshot_FullMethodName,
	"click":         pb.ExactMac_CreateInput_FullMethodName,
	"double_click":  pb.ExactMac_CreateInput_FullMethodName,
	"type":          pb.ExactMac_CreateInput_FullMethodName,
	"keypress":      pb.ExactMac_CreateInput_FullMethodName,
	"scroll":        pb.ExactMac_CreateInput_FullMethodName,
	"drag":          pb.ExactMac_CreateInput_FullMethodName,
	"move":          pb.ExactMac_CreateInput_FullMethodName,
	"wait":          "",
	"find_elements": pb.ExactMac_FindElements_FullMethodName,
	"click_element": pb.ExactMac_ClickElement_FullMethodName,
	"type_element":  pb.ExactMac_WriteElementValue_FullMethodName,
	"read_element":  pb.ExactMac_GetElement_FullMethodName,
	"focus_window":  pb.ExactMac_FocusWindow_FullMethodName,
	"move_window":   pb.ExactMac_MoveWindow_FullMethodName,
	"resize_window": pb.ExactMac_ResizeWindow_FullMethodName,
	"list_windows":  pb.ExactMac_ListWindows_FullMethodName,
	"clipboard":     pb.ExactMac_GetClipboard_FullMethodName,
	"run":           pb.ExactMac_ExecuteJavaScript_FullMethodName,
	"get_display":   pb.ExactMac_ListDisplays_FullMethodName,
	"create_macro":  pb.ExactMac_CreateMacro_FullMethodName,
	"get_macro":     pb.ExactMac_GetMacro_FullMethodName,
	"list_macros":   pb.ExactMac_ListMacros_FullMethodName,
	"update_macro":  pb.ExactMac_UpdateMacro_FullMethodName,
	"delete_macro":  pb.ExactMac_DeleteMacro_FullMethodName,
	"execute_macro": pb.ExactMac_ExecuteMacro_FullMethodName,
	"list_grants":   pb.ExactMac_ListGrants_FullMethodName,
	"preauthorize":  pb.ExactMac_PreauthorizeEnvelope_FullMethodName,
}

var applicationMatrixTools = map[string]struct{}{
	"open_app":  {},
	"list_apps": {},
	"close_app": {},
}

type nonApplicationMatrixTool struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`
}

type nonApplicationMatrixToolList struct {
	Tools []nonApplicationMatrixTool `json:"tools"`
}

type nonApplicationMatrixRecorder struct {
	mu                    sync.Mutex
	methods               []string
	allowDisplayBootstrap bool
}

func (r *nonApplicationMatrixRecorder) record(method string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.methods = append(r.methods, method)
}

func (r *nonApplicationMatrixRecorder) drain() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	methods := append([]string(nil), r.methods...)
	r.methods = nil
	return methods
}

func (r *nonApplicationMatrixRecorder) disableDisplayBootstrap() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.allowDisplayBootstrap = false
}

func (r *nonApplicationMatrixRecorder) displayBootstrapAllowed() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.allowDisplayBootstrap
}

type nonApplicationMatrixExactMacServer struct {
	pb.UnimplementedExactMacServer
	recorder *nonApplicationMatrixRecorder
}

func (s nonApplicationMatrixExactMacServer) ListDisplays(
	context.Context,
	*pb.ListDisplaysRequest,
) (*pb.ListDisplaysResponse, error) {
	if !s.recorder.displayBootstrapAllowed() {
		return nil, status.Error(codes.Unavailable, "non-application matrix sentinel")
	}
	return &pb.ListDisplaysResponse{}, nil
}

func TestMCPNonApplicationAdmissionMatrix_ProductionTransports(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()

	grpcAddress, recorder, stopSentinel := startNonApplicationMatrixSentinel(t)
	defer stopSentinel()
	overrides := map[string]string{
		"EXACTMAC_SERVER_TLS":              "false",
		"EXACTMAC_SERVER_CERT_FILE":        "",
		"EXACTMAC_REQUEST_TIMEOUT":         "2",
		"EXACTMAC_CONSENT_TIMEOUT_SECONDS": "1",
		"MCP_SHELL_COMMANDS_ENABLED":       "false",
	}
	_, baseURL, stopHTTP := startMCPTestServerWithOverrides(t, ctx, grpcAddress, overrides)
	defer stopHTTP()
	_, stdin, stdout, stopStdio := startMCPStdioProcessWithOverrides(t, ctx, grpcAddress, overrides)
	defer stopStdio()

	httpClient := &http.Client{Timeout: 10 * time.Second}
	httpSession := initializeHTTPSession(t, ctx, httpClient, baseURL, 1)
	initialized := sendSessionMCP(
		t,
		ctx,
		httpClient,
		baseURL,
		http.MethodPost,
		httpSession,
		`{"jsonrpc":"2.0","method":"notifications/initialized"}`,
	)
	if initialized.Err != nil || initialized.Status != http.StatusAccepted || len(initialized.Body) != 0 {
		t.Fatalf("HTTP initialized notification status=%d body=%q error=%v, want 202 empty", initialized.Status, initialized.Body, initialized.Err)
	}

	stdioInitialize, err := sendStdioRequest(ctx, stdin, stdout, validMCPInitializeRequest(1))
	if err != nil || stdioInitialize.Error != nil {
		t.Fatalf("stdio initialize response=%+v error=%v", stdioInitialize, err)
	}
	if err := writeStdioMessage(stdin, map[string]any{
		"jsonrpc": "2.0",
		"method":  "notifications/initialized",
	}); err != nil {
		t.Fatalf("send stdio initialized notification: %v", err)
	}

	initializationCalls := recorder.drain()
	wantInitializationCalls := []string{
		pb.ExactMac_ListDisplays_FullMethodName,
		pb.ExactMac_ListDisplays_FullMethodName,
	}
	sort.Strings(initializationCalls)
	if !reflect.DeepEqual(initializationCalls, wantInitializationCalls) {
		t.Fatalf("initialization backend calls = %v, want %v", initializationCalls, wantInitializationCalls)
	}
	recorder.disableDisplayBootstrap()

	httpTools := listNonApplicationMatrixToolsHTTP(t, ctx, httpClient, baseURL, httpSession)
	stdioTools := listNonApplicationMatrixToolsStdio(t, ctx, stdin, stdout)
	if !reflect.DeepEqual(httpTools, stdioTools) {
		t.Fatalf("production HTTP and stdio tools/list surfaces differ\nHTTP:  %+v\nstdio: %+v", httpTools, stdioTools)
	}
	assertNoNonApplicationMatrixBackendCalls(t, recorder, "tools/list")
	assertNonApplicationMatrixInventory(t, httpTools)

	requestID := 100
	for _, tool := range httpTools {
		if _, deferred := applicationMatrixTools[tool.Name]; deferred {
			continue
		}
		validArguments := cloneNonApplicationMatrixArguments(safeNonApplicationAdmissionFixtures[tool.Name])
		fixture := cloneNonApplicationMatrixArguments(validArguments)
		properties, ok := tool.InputSchema["properties"].(map[string]any)
		if !ok {
			t.Fatalf("tool %s root schema has no object properties", tool.Name)
		}
		if _, advertised := properties[nonApplicationMatrixUnknownField]; advertised {
			t.Fatalf("tool %s unexpectedly advertises sentinel field %s", tool.Name, nonApplicationMatrixUnknownField)
		}
		if closed, ok := tool.InputSchema["additionalProperties"].(bool); !ok || closed {
			t.Fatalf("tool %s root schema additionalProperties=%v, want false", tool.Name, tool.InputSchema["additionalProperties"])
		}
		fixture[nonApplicationMatrixUnknownField] = true

		requestID++
		httpResponse := callNonApplicationMatrixHTTP(
			t,
			ctx,
			httpClient,
			baseURL,
			httpSession,
			requestID,
			tool.Name,
			fixture,
		)
		assertNonApplicationMatrixHTTPRejection(t, tool.Name, requestID, httpResponse)
		assertNoNonApplicationMatrixBackendCalls(t, recorder, "HTTP rejection for "+tool.Name)
		requestID++
		assertNonApplicationMatrixHTTPPing(t, ctx, httpClient, baseURL, httpSession, requestID)
		assertNoNonApplicationMatrixBackendCalls(t, recorder, "HTTP ping after "+tool.Name)
		requestID++
		httpValid := callNonApplicationMatrixHTTP(
			t,
			ctx,
			httpClient,
			baseURL,
			httpSession,
			requestID,
			tool.Name,
			validArguments,
		)
		assertNonApplicationMatrixHTTPRouting(t, tool.Name, requestID, httpValid)
		assertNonApplicationMatrixFirstRPC(t, recorder, tool.Name, "HTTP")
		requestID++
		assertNonApplicationMatrixHTTPPing(t, ctx, httpClient, baseURL, httpSession, requestID)
		assertNoNonApplicationMatrixBackendCalls(t, recorder, "HTTP ping after valid "+tool.Name)

		requestID++
		stdioResponse, err := sendStdioRequest(ctx, stdin, stdout, map[string]any{
			"jsonrpc": "2.0",
			"id":      requestID,
			"method":  "tools/call",
			"params": map[string]any{
				"name":      tool.Name,
				"arguments": fixture,
			},
		})
		if err != nil {
			t.Fatalf("stdio %s malformed call: %v", tool.Name, err)
		}
		assertNonApplicationMatrixStdioRejection(t, tool.Name, requestID, stdioResponse)
		assertNoNonApplicationMatrixBackendCalls(t, recorder, "stdio rejection for "+tool.Name)
		requestID++
		assertNonApplicationMatrixStdioPing(t, ctx, stdin, stdout, requestID)
		assertNoNonApplicationMatrixBackendCalls(t, recorder, "stdio ping after "+tool.Name)
		requestID++
		stdioValid, err := sendStdioRequest(ctx, stdin, stdout, map[string]any{
			"jsonrpc": "2.0",
			"id":      requestID,
			"method":  "tools/call",
			"params": map[string]any{
				"name":      tool.Name,
				"arguments": validArguments,
			},
		})
		if err != nil {
			t.Fatalf("stdio %s valid call: %v", tool.Name, err)
		}
		assertNonApplicationMatrixStdioRouting(t, tool.Name, requestID, stdioValid)
		assertNonApplicationMatrixFirstRPC(t, recorder, tool.Name, "stdio")
		requestID++
		assertNonApplicationMatrixStdioPing(t, ctx, stdin, stdout, requestID)
		assertNoNonApplicationMatrixBackendCalls(t, recorder, "stdio ping after valid "+tool.Name)
	}
}

func startNonApplicationMatrixSentinel(t *testing.T) (string, *nonApplicationMatrixRecorder, func()) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen for non-application matrix sentinel: %v", err)
	}
	recorder := &nonApplicationMatrixRecorder{allowDisplayBootstrap: true}
	grpcServer := grpc.NewServer(
		grpc.UnaryInterceptor(func(
			ctx context.Context,
			req any,
			info *grpc.UnaryServerInfo,
			handler grpc.UnaryHandler,
		) (any, error) {
			recorder.record(info.FullMethod)
			return handler(ctx, req)
		}),
		grpc.StreamInterceptor(func(
			srv any,
			stream grpc.ServerStream,
			info *grpc.StreamServerInfo,
			handler grpc.StreamHandler,
		) error {
			recorder.record(info.FullMethod)
			return handler(srv, stream)
		}),
		grpc.UnknownServiceHandler(func(_ any, stream grpc.ServerStream) error {
			method, ok := grpc.MethodFromServerStream(stream)
			if !ok {
				method = "<unknown>"
			}
			recorder.record(method)
			return status.Error(codes.Unimplemented, "non-application matrix sentinel")
		}),
	)
	pb.RegisterExactMacServer(grpcServer, nonApplicationMatrixExactMacServer{recorder: recorder})
	serveResult := make(chan error, 1)
	go func() {
		serveResult <- grpcServer.Serve(listener)
	}()
	var stopOnce sync.Once
	stop := func() {
		stopOnce.Do(func() {
			grpcServer.Stop()
			if err := <-serveResult; err != nil && !errors.Is(err, grpc.ErrServerStopped) {
				t.Errorf("stop non-application matrix sentinel: %v", err)
			}
		})
	}
	return listener.Addr().String(), recorder, stop
}

func listNonApplicationMatrixToolsHTTP(
	t *testing.T,
	ctx context.Context,
	client *http.Client,
	baseURL string,
	sessionID string,
) []nonApplicationMatrixTool {
	t.Helper()
	response := sendSessionMCP(
		t,
		ctx,
		client,
		baseURL,
		http.MethodPost,
		sessionID,
		`{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}`,
	)
	if response.Err != nil || response.Status != http.StatusOK {
		t.Fatalf("HTTP tools/list status=%d body=%q error=%v", response.Status, response.Body, response.Err)
	}
	var envelope mcpResponse
	if err := json.Unmarshal(response.Body, &envelope); err != nil || envelope.Error != nil {
		t.Fatalf("decode HTTP tools/list response=%+v error=%v body=%q", envelope, err, response.Body)
	}
	return decodeNonApplicationMatrixToolList(t, envelope.Result)
}

func listNonApplicationMatrixToolsStdio(
	t *testing.T,
	ctx context.Context,
	stdin io.Writer,
	stdout *stdioResponsePump,
) []nonApplicationMatrixTool {
	t.Helper()
	response, err := sendStdioRequest(ctx, stdin, stdout, map[string]any{
		"jsonrpc": "2.0",
		"id":      2,
		"method":  "tools/list",
		"params":  map[string]any{},
	})
	if err != nil || response.Error != nil {
		t.Fatalf("stdio tools/list response=%+v error=%v", response, err)
	}
	return decodeNonApplicationMatrixToolList(t, response.Result)
}

func decodeNonApplicationMatrixToolList(t *testing.T, result json.RawMessage) []nonApplicationMatrixTool {
	t.Helper()
	var decoded nonApplicationMatrixToolList
	if err := json.Unmarshal(result, &decoded); err != nil {
		t.Fatalf("decode production tools/list result: %v", err)
	}
	if len(decoded.Tools) == 0 {
		t.Fatal("production tools/list returned no tools")
	}
	for index, tool := range decoded.Tools {
		if tool.Name == "" || tool.Description == "" || tool.InputSchema == nil {
			t.Fatalf("invalid production tool row %d: %+v", index, tool)
		}
		if index > 0 && decoded.Tools[index-1].Name >= tool.Name {
			t.Fatalf("production tools/list is not strictly sorted: %q before %q", decoded.Tools[index-1].Name, tool.Name)
		}
	}
	return decoded.Tools
}

func assertNonApplicationMatrixInventory(t *testing.T, tools []nonApplicationMatrixTool) {
	t.Helper()
	liveNonApplication := make(map[string]struct{})
	liveApplications := make(map[string]struct{})
	for _, tool := range tools {
		if _, application := applicationMatrixTools[tool.Name]; application {
			liveApplications[tool.Name] = struct{}{}
			continue
		}
		liveNonApplication[tool.Name] = struct{}{}
	}
	if !reflect.DeepEqual(liveApplications, applicationMatrixTools) {
		t.Fatalf("FUNC-012 application tool inventory = %v, want %v", sortedNonApplicationMatrixKeys(liveApplications), sortedNonApplicationMatrixKeys(applicationMatrixTools))
	}
	fixtureNames := make(map[string]struct{}, len(safeNonApplicationAdmissionFixtures))
	for name := range safeNonApplicationAdmissionFixtures {
		fixtureNames[name] = struct{}{}
	}
	if !reflect.DeepEqual(liveNonApplication, fixtureNames) {
		t.Fatalf("safe non-application fixture inventory mismatch: live=%v fixtures=%v", sortedNonApplicationMatrixKeys(liveNonApplication), sortedNonApplicationMatrixKeys(fixtureNames))
	}
	routingNames := make(map[string]struct{}, len(safeNonApplicationFirstRPC))
	for name := range safeNonApplicationFirstRPC {
		routingNames[name] = struct{}{}
	}
	if !reflect.DeepEqual(liveNonApplication, routingNames) {
		t.Fatalf("non-application routing inventory mismatch: live=%v routes=%v", sortedNonApplicationMatrixKeys(liveNonApplication), sortedNonApplicationMatrixKeys(routingNames))
	}
}

func callNonApplicationMatrixHTTP(
	t *testing.T,
	ctx context.Context,
	client *http.Client,
	baseURL string,
	sessionID string,
	requestID int,
	toolName string,
	arguments map[string]any,
) mcpResponse {
	t.Helper()
	payload, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      requestID,
		"method":  "tools/call",
		"params": map[string]any{
			"name":      toolName,
			"arguments": arguments,
		},
	})
	if err != nil {
		t.Fatalf("marshal HTTP %s malformed call: %v", toolName, err)
	}
	response := sendSessionMCP(t, ctx, client, baseURL, http.MethodPost, sessionID, string(payload))
	if response.Err != nil || response.Status != http.StatusOK {
		t.Fatalf("HTTP %s malformed call status=%d body=%q error=%v", toolName, response.Status, response.Body, response.Err)
	}
	var decoded mcpResponse
	if err := json.Unmarshal(response.Body, &decoded); err != nil {
		t.Fatalf("decode HTTP %s malformed response %q: %v", toolName, response.Body, err)
	}
	return decoded
}

func assertNonApplicationMatrixHTTPRejection(t *testing.T, toolName string, requestID int, response mcpResponse) {
	t.Helper()
	if string(response.ID) != fmt.Sprint(requestID) {
		t.Fatalf("HTTP %s response id=%s, want %d", toolName, response.ID, requestID)
	}
	if response.Error == nil || response.Error.Code != -32602 || !strings.Contains(response.Error.Message, nonApplicationMatrixUnknownField) {
		t.Fatalf("HTTP %s response error=%+v, want -32602 naming %s", toolName, response.Error, nonApplicationMatrixUnknownField)
	}
	if len(response.Result) != 0 {
		t.Fatalf("HTTP %s rejection returned result %s", toolName, response.Result)
	}
}

func assertNonApplicationMatrixStdioRejection(t *testing.T, toolName string, requestID int, response *stdioResponse) {
	t.Helper()
	if response == nil || string(response.ID) != fmt.Sprint(requestID) {
		t.Fatalf("stdio %s response=%+v, want id %d", toolName, response, requestID)
	}
	if response.Error == nil || response.Error.Code != -32602 || !strings.Contains(response.Error.Message, nonApplicationMatrixUnknownField) {
		t.Fatalf("stdio %s response error=%+v, want -32602 naming %s", toolName, response.Error, nonApplicationMatrixUnknownField)
	}
	if len(response.Result) != 0 {
		t.Fatalf("stdio %s rejection returned result %s", toolName, response.Result)
	}
}

func assertNonApplicationMatrixHTTPRouting(t *testing.T, toolName string, requestID int, response mcpResponse) {
	t.Helper()
	if string(response.ID) != fmt.Sprint(requestID) || response.Error != nil {
		t.Fatalf("HTTP %s valid response=%+v, want correlated tools result", toolName, response)
	}
	assertNonApplicationMatrixToolResult(t, toolName, response.Result)
}

func assertNonApplicationMatrixStdioRouting(t *testing.T, toolName string, requestID int, response *stdioResponse) {
	t.Helper()
	if response == nil || string(response.ID) != fmt.Sprint(requestID) || response.Error != nil {
		t.Fatalf("stdio %s valid response=%+v, want correlated tools result", toolName, response)
	}
	assertNonApplicationMatrixToolResult(t, toolName, response.Result)
}

func assertNonApplicationMatrixToolResult(t *testing.T, toolName string, raw json.RawMessage) {
	t.Helper()
	var result productionMCPToolResult
	if err := json.Unmarshal(raw, &result); err != nil {
		t.Fatalf("decode %s tools result %q: %v", toolName, raw, err)
	}
	wantError := safeNonApplicationFirstRPC[toolName] != ""
	if result.IsError != wantError {
		t.Fatalf("%s tools result isError=%t, want %t: %+v", toolName, result.IsError, wantError, result)
	}
	if len(result.Content) == 0 || result.Content[0].Text == "" {
		t.Fatalf("%s tools result has no explanatory content: %+v", toolName, result)
	}
}

func assertNonApplicationMatrixFirstRPC(
	t *testing.T,
	recorder *nonApplicationMatrixRecorder,
	toolName string,
	transportName string,
) {
	t.Helper()
	want := safeNonApplicationFirstRPC[toolName]
	methods := recorder.drain()
	if want == "" {
		if len(methods) != 0 {
			t.Fatalf("%s local tool %s reached backend methods %v", transportName, toolName, methods)
		}
		return
	}
	if !reflect.DeepEqual(methods, []string{want}) {
		t.Fatalf("%s tool %s backend methods=%v, want first and only sentinel call %s", transportName, toolName, methods, want)
	}
}

func assertNonApplicationMatrixHTTPPing(
	t *testing.T,
	ctx context.Context,
	client *http.Client,
	baseURL string,
	sessionID string,
	requestID int,
) {
	t.Helper()
	payload := fmt.Sprintf(`{"jsonrpc":"2.0","id":%d,"method":"ping"}`, requestID)
	response := sendSessionMCP(t, ctx, client, baseURL, http.MethodPost, sessionID, payload)
	if response.Err != nil || response.Status != http.StatusOK {
		t.Fatalf("HTTP ping %d status=%d body=%q error=%v", requestID, response.Status, response.Body, response.Err)
	}
	var decoded mcpResponse
	if err := json.Unmarshal(response.Body, &decoded); err != nil || decoded.Error != nil || string(decoded.ID) != fmt.Sprint(requestID) || string(decoded.Result) != "{}" {
		t.Fatalf("HTTP ping %d response=%+v decode_error=%v body=%q", requestID, decoded, err, response.Body)
	}
}

func assertNonApplicationMatrixStdioPing(
	t *testing.T,
	ctx context.Context,
	stdin io.Writer,
	stdout *stdioResponsePump,
	requestID int,
) {
	t.Helper()
	response, err := sendStdioRequest(ctx, stdin, stdout, map[string]any{
		"jsonrpc": "2.0",
		"id":      requestID,
		"method":  "ping",
	})
	if err != nil || response == nil || response.Error != nil || string(response.ID) != fmt.Sprint(requestID) || string(response.Result) != "{}" {
		t.Fatalf("stdio ping %d response=%+v error=%v", requestID, response, err)
	}
}

func assertNoNonApplicationMatrixBackendCalls(t *testing.T, recorder *nonApplicationMatrixRecorder, label string) {
	t.Helper()
	if methods := recorder.drain(); len(methods) != 0 {
		t.Fatalf("%s reached backend methods %v", label, methods)
	}
}

func cloneNonApplicationMatrixArguments(arguments map[string]any) map[string]any {
	clone := make(map[string]any, len(arguments)+1)
	maps.Copy(clone, arguments)
	return clone
}

func sortedNonApplicationMatrixKeys(values map[string]struct{}) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}
