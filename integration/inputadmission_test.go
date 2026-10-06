// Copyright 2026 Joseph Cumines

package integration

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"reflect"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	typepb "github.com/joeycumines/ExactMac/gen/go/exactmac/type"
	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"
)

type inputAdmissionBackendRecorder struct {
	mu               sync.Mutex
	methods          []string
	inputs           []*pb.CreateInputRequest
	postedEventCount int32
}

type physicalInputAdmissionCase struct {
	name       string
	arguments  map[string]any
	wantParent string
	wantTarget *pb.InputTarget
	wantAction *pb.InputAction
	wantPosts  int32
}

func (r *inputAdmissionBackendRecorder) recordMethod(method string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.methods = append(r.methods, method)
}

func (r *inputAdmissionBackendRecorder) recordInput(request *pb.CreateInputRequest) int32 {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.inputs = append(r.inputs, request)
	return r.postedEventCount
}

func (r *inputAdmissionBackendRecorder) setPostedEventCount(count int32) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.postedEventCount = count
}

func (r *inputAdmissionBackendRecorder) drain() ([]string, []*pb.CreateInputRequest) {
	r.mu.Lock()
	defer r.mu.Unlock()
	methods := append([]string(nil), r.methods...)
	inputs := append([]*pb.CreateInputRequest(nil), r.inputs...)
	r.methods = nil
	r.inputs = nil
	return methods, inputs
}

type inputAdmissionBackend struct {
	pb.UnimplementedExactMacServer
	recorder *inputAdmissionBackendRecorder
}

func (s inputAdmissionBackend) ListDisplays(context.Context, *pb.ListDisplaysRequest) (*pb.ListDisplaysResponse, error) {
	return &pb.ListDisplaysResponse{}, nil
}

func (s inputAdmissionBackend) CreateInput(_ context.Context, request *pb.CreateInputRequest) (*pb.Input, error) {
	postedEventCount := s.recorder.recordInput(request)
	created := time.Unix(1_700_000_000, 0)
	return &pb.Input{
		Name:         request.GetParent() + "/inputs/" + request.GetInputId(),
		Action:       proto.Clone(request.GetInput().GetAction()).(*pb.InputAction),
		Target:       proto.Clone(request.GetInput().GetTarget()).(*pb.InputTarget),
		State:        pb.Input_STATE_COMPLETED,
		CreateTime:   timestamppb.New(created),
		CompleteTime: timestamppb.New(created.Add(time.Millisecond)),
		DeliveryResult: &pb.InputDeliveryResult{
			Commitment:             pb.InputDeliveryResult_COMMITMENT_COMMITTED_AND_SETTLED,
			PostedEventCount:       postedEventCount,
			RoutedDeliveryObserved: true,
		},
	}, nil
}

func TestMCPInputAdmission_ProductionTransports(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	grpcAddress, recorder, stopBackend := startInputAdmissionBackend(t)
	defer stopBackend()
	overrides := map[string]string{
		"EXACTMAC_SERVER_TLS":                    "false",
		"EXACTMAC_SERVER_CERT_FILE":              "",
		"EXACTMAC_REQUEST_TIMEOUT":               "2",
		"EXACTMAC_CONSENT_TIMEOUT_SECONDS":       "1",
		"MCP_MAX_CONCURRENT_REQUESTS":            "1",
		"MCP_MAX_CONCURRENT_REQUESTS_PER_CLIENT": "1",
		"MCP_SHELL_COMMANDS_ENABLED":             "false",
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
		t.Fatalf("HTTP initialized status=%d body=%q error=%v", initialized.Status, initialized.Body, initialized.Err)
	}
	stdioInitialize, err := sendStdioRequest(ctx, stdin, stdout, validMCPInitializeRequest(2))
	if err != nil || stdioInitialize.Error != nil {
		t.Fatalf("stdio initialize response=%+v error=%v", stdioInitialize, err)
	}
	if err := writeStdioMessage(stdin, map[string]any{
		"jsonrpc": "2.0",
		"method":  "notifications/initialized",
	}); err != nil {
		t.Fatalf("send stdio initialized notification: %v", err)
	}
	methods, inputs := recorder.drain()
	if !reflect.DeepEqual(methods, []string{
		pb.ExactMac_ListDisplays_FullMethodName,
		pb.ExactMac_ListDisplays_FullMethodName,
	}) || len(inputs) != 0 {
		t.Fatalf("initialization backend methods=%v inputs=%d", methods, len(inputs))
	}

	invalid := []struct {
		name      string
		tool      string
		arguments map[string]any
		message   string
	}{
		{name: "explicit zero click count", tool: "click", arguments: map[string]any{"target": "desktop", "x": 0, "y": 0, "click_count": 0}, message: "click_count"},
		{name: "null click button", tool: "click", arguments: map[string]any{"target": "desktop", "x": 0, "y": 0, "button": nil}, message: "button"},
		{name: "multiple primary keys", tool: "keypress", arguments: map[string]any{"target": "desktop", "keys": []any{"a", "b"}}, message: "primary"},
		{name: "duplicate modifiers", tool: "keypress", arguments: map[string]any{"target": "desktop", "keys": []any{"meta", "command", "a"}}, message: "modifier"},
		{name: "explicit zero wait", tool: "wait", arguments: map[string]any{"duration": 0}, message: "duration"},
		{name: "over-timeout wait", tool: "wait", arguments: map[string]any{"duration": 3}, message: "duration"},
	}
	requestID := 100
	for _, test := range invalid {
		t.Run(test.name, func(t *testing.T) {
			recorder.drain()
			requestID++
			httpResponse := callNonApplicationMatrixHTTP(
				t,
				ctx,
				httpClient,
				baseURL,
				httpSession,
				requestID,
				test.tool,
				test.arguments,
			)
			assertInputAdmissionHTTPRejection(t, requestID, httpResponse, test.message)
			assertInputAdmissionNoBackendCalls(t, recorder, "HTTP "+test.name)
			requestID++
			assertNonApplicationMatrixHTTPPing(t, ctx, httpClient, baseURL, httpSession, requestID)
			assertInputAdmissionNoBackendCalls(t, recorder, "HTTP ping after "+test.name)
			requestID++
			httpValid := callNonApplicationMatrixHTTP(
				t,
				ctx,
				httpClient,
				baseURL,
				httpSession,
				requestID,
				"click",
				map[string]any{"target": "desktop", "x": 0, "y": 0},
			)
			assertInputAdmissionHTTPSuccess(t, requestID, httpValid)
			assertInputAdmissionDefaultClick(t, recorder, "HTTP recovery after "+test.name)

			requestID++
			stdioResponse, err := sendStdioRequest(ctx, stdin, stdout, map[string]any{
				"jsonrpc": "2.0",
				"id":      requestID,
				"method":  "tools/call",
				"params": map[string]any{
					"name":      test.tool,
					"arguments": test.arguments,
				},
			})
			if err != nil {
				t.Fatalf("stdio invalid input call: %v", err)
			}
			assertInputAdmissionStdioRejection(t, requestID, stdioResponse, test.message)
			assertInputAdmissionNoBackendCalls(t, recorder, "stdio "+test.name)
			requestID++
			assertNonApplicationMatrixStdioPing(t, ctx, stdin, stdout, requestID)
			assertInputAdmissionNoBackendCalls(t, recorder, "stdio ping after "+test.name)
			requestID++
			stdioValid, err := sendStdioRequest(ctx, stdin, stdout, map[string]any{
				"jsonrpc": "2.0",
				"id":      requestID,
				"method":  "tools/call",
				"params": map[string]any{
					"name":      "click",
					"arguments": map[string]any{"target": "desktop", "x": 0, "y": 0},
				},
			})
			if err != nil {
				t.Fatalf("stdio recovery click: %v", err)
			}
			assertInputAdmissionStdioSuccess(t, requestID, stdioValid)
			assertInputAdmissionDefaultClick(t, recorder, "stdio recovery after "+test.name)
		})
	}

	right := pb.MouseClick_CLICK_TYPE_RIGHT
	middle := pb.MouseClick_CLICK_TYPE_MIDDLE
	triple := int32(3)
	double := int32(2)
	physical := []physicalInputAdmissionCase{
		{
			name: "click",
			arguments: map[string]any{
				"target":      "applications/editor/windows/document",
				"x":           10.25,
				"y":           -20.5,
				"button":      "right",
				"click_count": 3,
				"keys":        []any{"meta", "shift"},
			},
			wantParent: "applications/editor",
			wantTarget: &pb.InputTarget{
				Destination: &pb.InputTarget_Window{
					Window: "applications/editor/windows/document",
				},
			},
			wantAction: &pb.InputAction{
				InputType: &pb.InputAction_MouseClick{MouseClick: &pb.MouseClick{
					Position:   &typepb.Point{X: 10.25, Y: -20.5},
					ClickType:  &right,
					ClickCount: &triple,
					Modifiers: []pb.KeyPress_Modifier{
						pb.KeyPress_MODIFIER_COMMAND,
						pb.KeyPress_MODIFIER_SHIFT,
					},
				}},
			},
			wantPosts: 6,
		},
		{
			name: "double_click",
			arguments: map[string]any{
				"target": "displays/7",
				"x":      0.25,
				"y":      1.5,
				"button": "middle",
				"keys":   []any{"option"},
			},
			wantParent: "applications/-",
			wantTarget: &pb.InputTarget{
				Destination: &pb.InputTarget_Display{Display: "displays/7"},
			},
			wantAction: &pb.InputAction{
				InputType: &pb.InputAction_MouseClick{MouseClick: &pb.MouseClick{
					Position:   &typepb.Point{X: 0.25, Y: 1.5},
					ClickType:  &middle,
					ClickCount: &double,
					Modifiers:  []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_OPTION},
				}},
			},
			wantPosts: 4,
		},
		{
			name: "type",
			arguments: map[string]any{
				"target":     "applications/editor",
				"text":       "é👨‍👩‍👧‍👦",
				"char_delay": 0.125,
			},
			wantParent: "applications/editor",
			wantTarget: &pb.InputTarget{
				Destination: &pb.InputTarget_Application{Application: "applications/editor"},
			},
			wantAction: &pb.InputAction{
				InputType: &pb.InputAction_TextInput{TextInput: &pb.TextInput{
					Text:      "é👨‍👩‍👧‍👦",
					CharDelay: 0.125,
				}},
			},
			wantPosts: 4,
		},
		{
			name: "keypress",
			arguments: map[string]any{
				"target":        "applications/editor/windows/document",
				"keys":          []any{"control", "é"},
				"hold_duration": 0.375,
			},
			wantParent: "applications/editor",
			wantTarget: &pb.InputTarget{
				Destination: &pb.InputTarget_Window{
					Window: "applications/editor/windows/document",
				},
			},
			wantAction: &pb.InputAction{
				InputType: &pb.InputAction_KeyPress{KeyPress: &pb.KeyPress{
					Key:          "é",
					Modifiers:    []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_CONTROL},
					HoldDuration: 0.375,
				}},
			},
			wantPosts: 2,
		},
		{
			name: "scroll",
			arguments: map[string]any{
				"target":   "desktop",
				"x":        1.25,
				"y":        2.5,
				"scroll_x": 2.5,
				"scroll_y": -3.5,
				"duration": 1.25,
				"keys":     []any{"fn"},
			},
			wantParent: "applications/-",
			wantTarget: &pb.InputTarget{
				Destination: &pb.InputTarget_Desktop{Desktop: true},
			},
			wantAction: &pb.InputAction{
				InputType: &pb.InputAction_ScrollAction{ScrollAction: &pb.Scroll{
					Position:   &typepb.Point{X: 1.25, Y: 2.5},
					Horizontal: 2.5,
					Vertical:   3.5,
					Duration:   1.25,
					Modifiers:  []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_FUNCTION},
				}},
			},
			wantPosts: 4,
		},
		nonPhysicalInputAdmissionDragCase(),
		{
			name: "move",
			arguments: map[string]any{
				"target":   "displays/9",
				"x":        -0.25,
				"y":        1.5,
				"duration": 0.5,
				"keys":     []any{"cmd"},
			},
			wantParent: "applications/-",
			wantTarget: &pb.InputTarget{
				Destination: &pb.InputTarget_Display{Display: "displays/9"},
			},
			wantAction: &pb.InputAction{
				InputType: &pb.InputAction_MouseMove{MouseMove: &pb.MouseMove{
					Position:  &typepb.Point{X: -0.25, Y: 1.5},
					Duration:  0.5,
					Modifiers: []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_COMMAND},
				}},
			},
			wantPosts: 20,
		},
	}
	seenInputIDs := make(map[string]struct{}, len(physical)*2)
	for _, test := range physical {
		t.Run("physical/"+test.name, func(t *testing.T) {
			recorder.setPostedEventCount(test.wantPosts)

			requestID++
			httpResponse := callNonApplicationMatrixHTTP(
				t,
				ctx,
				httpClient,
				baseURL,
				httpSession,
				requestID,
				test.name,
				test.arguments,
			)
			assertInputAdmissionHTTPSuccess(t, requestID, httpResponse)
			assertInputAdmissionForwarding(
				t,
				recorder,
				"HTTP "+test.name,
				test.wantParent,
				test.wantTarget,
				test.wantAction,
				seenInputIDs,
			)

			requestID++
			stdioResponse, err := sendStdioRequest(ctx, stdin, stdout, map[string]any{
				"jsonrpc": "2.0",
				"id":      requestID,
				"method":  "tools/call",
				"params": map[string]any{
					"name":      test.name,
					"arguments": test.arguments,
				},
			})
			if err != nil {
				t.Fatalf("stdio %s: %v", test.name, err)
			}
			assertInputAdmissionStdioSuccess(t, requestID, stdioResponse)
			assertInputAdmissionForwarding(
				t,
				recorder,
				"stdio "+test.name,
				test.wantParent,
				test.wantTarget,
				test.wantAction,
				seenInputIDs,
			)
		})
	}
}

func nonPhysicalInputAdmissionDragCase() physicalInputAdmissionCase {
	right := pb.MouseClick_CLICK_TYPE_RIGHT
	return physicalInputAdmissionCase{
		name: "drag",
		arguments: map[string]any{
			"target": "applications/editor/windows/document",
			"path": []any{
				map[string]any{"x": -1.25, "y": 2.5},
				map[string]any{"x": 3.75, "y": 4.125},
				map[string]any{"x": 8.5, "y": 9.25},
			},
			"button":   "right",
			"duration": 0.75,
			"keys":     []any{"shift"},
		},
		wantParent: "applications/editor",
		wantTarget: &pb.InputTarget{
			Destination: &pb.InputTarget_Window{
				Window: "applications/editor/windows/document",
			},
		},
		wantAction: &pb.InputAction{
			InputType: &pb.InputAction_MouseDrag{MouseDrag: &pb.MouseDrag{
				StartPosition: &typepb.Point{X: -1.25, Y: 2.5},
				EndPosition:   &typepb.Point{X: 8.5, Y: 9.25},
				Duration:      0.75,
				Button:        &right,
				Modifiers:     []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_SHIFT},
				Waypoints: []*typepb.Point{
					{X: -1.25, Y: 2.5},
					{X: 3.75, Y: 4.125},
					{X: 8.5, Y: 9.25},
				},
			}},
		},
		wantPosts: 4,
	}
}

func startInputAdmissionBackend(t *testing.T) (string, *inputAdmissionBackendRecorder, func()) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen for input-admission backend: %v", err)
	}
	recorder := &inputAdmissionBackendRecorder{postedEventCount: 2}
	grpcServer := grpc.NewServer(grpc.UnaryInterceptor(func(
		ctx context.Context,
		req any,
		info *grpc.UnaryServerInfo,
		handler grpc.UnaryHandler,
	) (any, error) {
		recorder.recordMethod(info.FullMethod)
		return handler(ctx, req)
	}))
	pb.RegisterExactMacServer(grpcServer, inputAdmissionBackend{recorder: recorder})
	serveResult := make(chan error, 1)
	go func() { serveResult <- grpcServer.Serve(listener) }()
	var stopOnce sync.Once
	stop := func() {
		stopOnce.Do(func() {
			grpcServer.Stop()
			if err := <-serveResult; err != nil && !errors.Is(err, grpc.ErrServerStopped) {
				t.Errorf("stop input-admission backend: %v", err)
			}
		})
	}
	return listener.Addr().String(), recorder, stop
}

func assertInputAdmissionHTTPRejection(t *testing.T, requestID int, response mcpResponse, message string) {
	t.Helper()
	if string(response.ID) != fmt.Sprint(requestID) || response.Error == nil || response.Error.Code != -32602 || !strings.Contains(strings.ToLower(response.Error.Message), strings.ToLower(message)) {
		t.Fatalf("HTTP response=%+v, want correlated -32602 naming %q", response, message)
	}
	if len(response.Result) != 0 {
		t.Fatalf("HTTP rejection returned result %s", response.Result)
	}
}

func assertInputAdmissionStdioRejection(t *testing.T, requestID int, response *stdioResponse, message string) {
	t.Helper()
	if response == nil || string(response.ID) != fmt.Sprint(requestID) || response.Error == nil || response.Error.Code != -32602 || !strings.Contains(strings.ToLower(response.Error.Message), strings.ToLower(message)) {
		t.Fatalf("stdio response=%+v, want correlated -32602 naming %q", response, message)
	}
	if len(response.Result) != 0 {
		t.Fatalf("stdio rejection returned result %s", response.Result)
	}
}

func assertInputAdmissionHTTPSuccess(t *testing.T, requestID int, response mcpResponse) {
	t.Helper()
	if string(response.ID) != fmt.Sprint(requestID) || response.Error != nil {
		t.Fatalf("HTTP recovery response=%+v", response)
	}
	assertInputAdmissionToolSuccess(t, response.Result)
}

func assertInputAdmissionStdioSuccess(t *testing.T, requestID int, response *stdioResponse) {
	t.Helper()
	if response == nil || string(response.ID) != fmt.Sprint(requestID) || response.Error != nil {
		t.Fatalf("stdio recovery response=%+v", response)
	}
	assertInputAdmissionToolSuccess(t, response.Result)
}

func assertInputAdmissionToolSuccess(t *testing.T, raw json.RawMessage) {
	t.Helper()
	var result productionMCPToolResult
	if err := json.Unmarshal(raw, &result); err != nil || result.IsError || len(result.Content) == 0 {
		t.Fatalf("tool success result=%+v decode_error=%v raw=%s", result, err, raw)
	}
}

func assertInputAdmissionNoBackendCalls(t *testing.T, recorder *inputAdmissionBackendRecorder, label string) {
	t.Helper()
	methods, inputs := recorder.drain()
	if len(methods) != 0 || len(inputs) != 0 {
		t.Fatalf("%s reached backend methods=%v inputs=%d", label, methods, len(inputs))
	}
}

func assertInputAdmissionDefaultClick(t *testing.T, recorder *inputAdmissionBackendRecorder, label string) {
	t.Helper()
	methods, inputs := recorder.drain()
	if !reflect.DeepEqual(methods, []string{pb.ExactMac_CreateInput_FullMethodName}) || len(inputs) != 1 {
		t.Fatalf("%s methods=%v inputs=%d", label, methods, len(inputs))
	}
	click := inputs[0].GetInput().GetAction().GetMouseClick()
	if click == nil || click.GetClickType() != pb.MouseClick_CLICK_TYPE_LEFT || click.GetClickCount() != 1 || click.GetPosition().GetX() != 0 || click.GetPosition().GetY() != 0 {
		t.Fatalf("%s click=%+v, want explicit left/1 at (0,0)", label, click)
	}
	request := inputs[0]
	if request.GetParent() != "applications/-" ||
		!request.GetInput().GetTarget().GetDesktop() ||
		!strings.HasPrefix(request.GetInputId(), "mcp-") {
		t.Fatalf(
			"%s parent=%q target=%+v input_id=%q, want exact desktop and opaque MCP id",
			label,
			request.GetParent(),
			request.GetInput().GetTarget(),
			request.GetInputId(),
		)
	}
}

func assertInputAdmissionForwarding(
	t *testing.T,
	recorder *inputAdmissionBackendRecorder,
	label string,
	wantParent string,
	wantTarget *pb.InputTarget,
	wantAction *pb.InputAction,
	seenInputIDs map[string]struct{},
) {
	t.Helper()
	methods, inputs := recorder.drain()
	if !reflect.DeepEqual(methods, []string{pb.ExactMac_CreateInput_FullMethodName}) ||
		len(inputs) != 1 {
		t.Fatalf("%s methods=%v inputs=%d", label, methods, len(inputs))
	}
	request := inputs[0]
	if request.GetParent() != wantParent {
		t.Errorf("%s parent=%q want=%q", label, request.GetParent(), wantParent)
	}
	if !proto.Equal(request.GetInput().GetTarget(), wantTarget) {
		t.Errorf("%s target=%v want=%v", label, request.GetInput().GetTarget(), wantTarget)
	}
	if !proto.Equal(request.GetInput().GetAction(), wantAction) {
		t.Errorf("%s action=%v want=%v", label, request.GetInput().GetAction(), wantAction)
	}
	if matched, err := regexp.MatchString(`^mcp-[0-9a-f]{32}$`, request.GetInputId()); err != nil || !matched {
		t.Errorf("%s input_id=%q, want stable opaque MCP identity", label, request.GetInputId())
	}
	if _, duplicate := seenInputIDs[request.GetInputId()]; duplicate {
		t.Errorf("%s reused input_id=%q", label, request.GetInputId())
	}
	seenInputIDs[request.GetInputId()] = struct{}{}
}
