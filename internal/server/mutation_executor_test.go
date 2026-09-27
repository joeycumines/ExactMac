// Copyright 2026 Joseph Cumines

package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/joeycumines/ExactMac/internal/transport"
)

func TestMutationExecutor_SerializesPhysicalDesktopJobs(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	executor := newMutationExecutor(ctx, 2)
	var active atomic.Int32
	var maximum atomic.Int32
	entered := make(chan string, 2)
	releaseFirst := make(chan struct{})
	releaseSecond := make(chan struct{})
	results := make(chan error, 2)

	start := func(label string, release <-chan struct{}) {
		go func() {
			_, err := executor.execute(ctx, func() (*ToolResult, error) {
				current := active.Add(1)
				for {
					observed := maximum.Load()
					if current <= observed || maximum.CompareAndSwap(observed, current) {
						break
					}
				}
				entered <- label
				select {
				case <-release:
				case <-ctx.Done():
				}
				active.Add(-1)
				return textResult(label), nil
			})
			results <- err
		}()
	}

	start("first", releaseFirst)
	waitForMutationSignal(t, ctx, entered, "first")
	start("second", releaseSecond)
	waitForMutationPending(t, ctx, executor, 1)
	if got := maximum.Load(); got != 1 {
		t.Fatalf("maximum active mutations=%d while second was queued, want 1", got)
	}
	close(releaseFirst)
	waitForMutationSignal(t, ctx, entered, "second")
	close(releaseSecond)
	for range 2 {
		select {
		case err := <-results:
			if err != nil {
				t.Fatalf("mutation execution error: %v", err)
			}
		case <-ctx.Done():
			t.Fatalf("mutation execution did not finish: %v", ctx.Err())
		}
	}
	if got := maximum.Load(); got != 1 {
		t.Fatalf("maximum active mutations=%d, want 1", got)
	}
}

func TestMutationExecutor_BoundsAndCancelsQueuedJobs(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	executor := newMutationExecutor(ctx, 1)
	entered := make(chan string, 1)
	release := make(chan struct{})
	firstResult := make(chan error, 1)
	go func() {
		_, err := executor.execute(ctx, func() (*ToolResult, error) {
			entered <- "first"
			<-release
			return textResultf("first"), nil
		})
		firstResult <- err
	}()
	waitForMutationSignal(t, ctx, entered, "first")

	queuedCtx, cancelQueued := context.WithCancel(ctx)
	queuedResult := make(chan error, 1)
	go func() {
		_, err := executor.execute(queuedCtx, func() (*ToolResult, error) {
			return nil, errors.New("cancelled queued job executed")
		})
		queuedResult <- err
	}()
	waitForMutationPending(t, ctx, executor, 1)

	if _, err := executor.execute(ctx, func() (*ToolResult, error) {
		return textResultf("overflow"), nil
	}); !errors.Is(err, errMutationQueueFull) {
		t.Fatalf("overflow mutation error=%v, want errMutationQueueFull", err)
	}
	cancelQueued()
	select {
	case err := <-queuedResult:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("queued cancellation error=%v, want context canceled", err)
		}
	case <-ctx.Done():
		t.Fatalf("queued cancellation did not return: %v", ctx.Err())
	}
	close(release)
	select {
	case err := <-firstResult:
		if err != nil {
			t.Fatalf("first mutation error: %v", err)
		}
	case <-ctx.Done():
		t.Fatalf("first mutation did not finish: %v", ctx.Err())
	}
}

func TestProductionTools_DeclareMutationPolicy(t *testing.T) {
	server := &MCPServer{tools: make(map[string]*Tool)}
	server.registerTools()
	wantPolicies := map[string]toolMutationPolicy{
		"screenshot":    mutationPolicyReadOnly,
		"click":         mutationPolicyExclusive,
		"double_click":  mutationPolicyExclusive,
		"type":          mutationPolicyExclusive,
		"keypress":      mutationPolicyExclusive,
		"scroll":        mutationPolicyExclusive,
		"drag":          mutationPolicyExclusive,
		"move":          mutationPolicyExclusive,
		"wait":          mutationPolicyReadOnly,
		"open_app":      mutationPolicyExclusive,
		"list_apps":     mutationPolicyReadOnly,
		"close_app":     mutationPolicyExclusive,
		"find_elements": mutationPolicyReadOnly,
		"click_element": mutationPolicyExclusive,
		"type_element":  mutationPolicyExclusive,
		"read_element":  mutationPolicyReadOnly,
		"focus_window":  mutationPolicyExclusive,
		"move_window":   mutationPolicyExclusive,
		"resize_window": mutationPolicyExclusive,
		"list_windows":  mutationPolicyReadOnly,
		"clipboard":     mutationPolicyClipboard,
		"run":           mutationPolicyExclusive,
		"get_display":   mutationPolicyReadOnly,
		"create_macro":  mutationPolicyExclusive,
		"get_macro":     mutationPolicyReadOnly,
		"list_macros":   mutationPolicyReadOnly,
		"update_macro":  mutationPolicyExclusive,
		"delete_macro":  mutationPolicyExclusive,
		"execute_macro": mutationPolicyExclusive,
		"preauthorize":  mutationPolicyExclusive,
		"list_grants":   mutationPolicyReadOnly,
	}
	for name, tool := range server.tools {
		if tool.MutationPolicy == mutationPolicyUnspecified {
			t.Errorf("production tool %q has no mutation policy", name)
		}
		want, ok := wantPolicies[name]
		if !ok {
			t.Errorf("production tool %q has no audited mutation contract", name)
			continue
		}
		if tool.MutationPolicy != want {
			t.Errorf("production tool %q mutation policy=%d, want %d", name, tool.MutationPolicy, want)
		}
		delete(wantPolicies, name)
	}
	for name := range wantPolicies {
		t.Errorf("audited production tool %q is absent from the live registry", name)
	}

	clipboard := server.tools["clipboard"]
	for _, test := range []struct {
		arguments string
		want      bool
	}{
		{arguments: `{"action":"get"}`},
		{arguments: `{"action":"set","text":"owned"}`, want: true},
		{arguments: `{"action":"clear"}`, want: true},
	} {
		if got := clipboard.requiresExclusiveMutation(json.RawMessage(test.arguments)); got != test.want {
			t.Errorf("clipboard arguments=%s exclusive=%t, want %t", test.arguments, got, test.want)
		}
	}
}

func TestMutationDispatcher_SerializesBoundsAndBypassesReadOnly(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	entered := make(chan string, 2)
	readEntered := make(chan string, 1)
	releaseFirst := make(chan struct{})
	releaseSecond := make(chan struct{})
	var mutationCalls atomic.Int32

	server := &MCPServer{ctx: ctx}
	server.mutationGate = newMutationExecutor(ctx, 1)
	server.tools = map[string]*Tool{
		"mutate": {
			Name:           "mutate",
			MutationPolicy: mutationPolicyExclusive,
			InputSchema:    emptyMutationTestSchema(),
			Handler: func(_ *ToolCall) (*ToolResult, error) {
				call := mutationCalls.Add(1)
				switch call {
				case 1:
					entered <- "first"
					select {
					case <-releaseFirst:
					case <-ctx.Done():
					}
				case 2:
					entered <- "second"
					select {
					case <-releaseSecond:
					case <-ctx.Done():
					}
				default:
					return nil, fmt.Errorf("unexpected mutation handler call %d", call)
				}
				return textResultf("mutation %d", call), nil
			},
		},
		"read": {
			Name:           "read",
			MutationPolicy: mutationPolicyReadOnly,
			InputSchema:    emptyMutationTestSchema(),
			Handler: func(_ *ToolCall) (*ToolResult, error) {
				readEntered <- "read"
				return textResult("read"), nil
			},
		},
	}

	results := make(chan error, 2)
	go dispatchMutationTestTool(ctx, server, "mutate", results)
	waitForMutationSignal(t, ctx, entered, "first")
	go dispatchMutationTestTool(ctx, server, "mutate", results)
	waitForMutationPending(t, ctx, server.mutationGate, 1)
	if got := mutationCalls.Load(); got != 1 {
		t.Fatalf("mutation handler calls while second is queued=%d, want 1", got)
	}

	readResponse, err := dispatchMutationTestToolResponse(ctx, server, "read")
	if err != nil {
		t.Fatalf("read-only dispatch: %v", err)
	}
	assertMutationToolResult(t, readResponse, false, "read")
	waitForMutationSignal(t, ctx, readEntered, "read")

	overflowResponse, err := dispatchMutationTestToolResponse(ctx, server, "mutate")
	if err != nil {
		t.Fatalf("overflow dispatch: %v", err)
	}
	assertMutationToolResult(t, overflowResponse, true, "queue is full")
	if got := mutationCalls.Load(); got != 1 {
		t.Fatalf("mutation handler calls after overflow=%d, want 1", got)
	}

	close(releaseFirst)
	waitForMutationSignal(t, ctx, entered, "second")
	close(releaseSecond)
	for range 2 {
		select {
		case err := <-results:
			if err != nil {
				t.Fatalf("mutation dispatch: %v", err)
			}
		case <-ctx.Done():
			t.Fatalf("mutation dispatch did not finish: %v", ctx.Err())
		}
	}
}

func emptyMutationTestSchema() map[string]any {
	return map[string]any{
		"type":                 "object",
		"properties":           map[string]any{},
		"additionalProperties": false,
	}
}

func dispatchMutationTestTool(
	ctx context.Context,
	server *MCPServer,
	name string,
	results chan<- error,
) {
	response, err := dispatchMutationTestToolResponse(ctx, server, name)
	if err == nil {
		err = mutationToolResponseError(response)
	}
	results <- err
}

func dispatchMutationTestToolResponse(
	ctx context.Context,
	server *MCPServer,
	name string,
) (*transport.Message, error) {
	params, err := json.Marshal(map[string]any{"name": name, "arguments": map[string]any{}})
	if err != nil {
		return nil, err
	}
	return server.dispatchMCPMessage(&transport.Message{
		JSONRPC: "2.0",
		ID:      json.RawMessage(`1`),
		Method:  "tools/call",
		Params:  params,
		Context: ctx,
	})
}

func mutationToolResponseError(response *transport.Message) error {
	if response == nil {
		return errors.New("nil tool response")
	}
	if response.Error != nil {
		return fmt.Errorf("JSON-RPC error %d: %s", response.Error.Code, response.Error.Message)
	}
	var result ToolResult
	if err := json.Unmarshal(response.Result, &result); err != nil {
		return fmt.Errorf("decode tool result: %w", err)
	}
	if result.IsError {
		return fmt.Errorf("tool error: %s", mutationToolResultText(&result))
	}
	return nil
}

func assertMutationToolResult(t *testing.T, response *transport.Message, wantError bool, textContains string) {
	t.Helper()
	if response == nil {
		t.Fatal("nil tool response")
	}
	if response.Error != nil {
		t.Fatalf("JSON-RPC error %d: %s", response.Error.Code, response.Error.Message)
	}
	var result ToolResult
	if err := json.Unmarshal(response.Result, &result); err != nil {
		t.Fatalf("decode tool result: %v", err)
	}
	if result.IsError != wantError {
		t.Fatalf("tool IsError=%t, want %t", result.IsError, wantError)
	}
	if text := mutationToolResultText(&result); !strings.Contains(text, textContains) {
		t.Fatalf("tool result text=%q, want substring %q", text, textContains)
	}
}

func mutationToolResultText(result *ToolResult) string {
	if result == nil || len(result.Content) == 0 {
		return ""
	}
	return result.Content[0].Text
}

func waitForMutationSignal(t *testing.T, ctx context.Context, signals <-chan string, want string) {
	t.Helper()
	select {
	case got := <-signals:
		if got != want {
			t.Fatalf("mutation signal=%q, want %q", got, want)
		}
	case <-ctx.Done():
		t.Fatalf("mutation signal %q not observed: %v", want, ctx.Err())
	}
}

func waitForMutationPending(t *testing.T, ctx context.Context, executor *mutationExecutor, want int) {
	t.Helper()
	ticker := time.NewTicker(time.Millisecond)
	defer ticker.Stop()
	for {
		if executor.pending() == want {
			return
		}
		select {
		case <-ticker.C:
		case <-ctx.Done():
			t.Fatalf("pending mutations=%d, want %d: %v", executor.pending(), want, ctx.Err())
		}
	}
}
