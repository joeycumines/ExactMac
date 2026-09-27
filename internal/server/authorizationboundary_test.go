// Copyright 2025 Joseph Cumines
//
// What the Go layer can and cannot do about authorization.

package server

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// TestTheGoLayerCannotReachACapabilityTheServerRefuses is the property that makes the Go
// layer a proxy rather than a second policy.
//
// Every MCP handler ends in a gRPC call, so the server is the only thing that can say no.
// This drives a handler against a client that refuses, and asserts the refusal REACHES THE
// CALLER as an error rather than being flattened into a success with empty output — which
// is the failure a proxy layer produces when it treats an error as an empty result.
func TestTheGoLayerCannotReachACapabilityTheServerRefuses(t *testing.T) {
	server := newTestServer()
	// The feature switch ON, so the request REACHES the server and the refusal under test
	// is the server's rather than the switch's.
	server.cfg.ShellCommandsEnabled = true
	server.client = denyingClient(reasonRef("denied: reducedUnauthenticatedPosture"))

	result, err := server.handleRun(&ToolCall{
		Name:      "run",
		Arguments: json.RawMessage(`{"type":"shell","command":"/bin/echo hi"}`),
	})
	if err != nil {
		t.Fatalf("handler returned a transport error rather than a tool result: %v", err)
	}
	if !resultIsError(result) {
		t.Fatal("a refused capability came back as a successful result")
	}
	text := resultText(result)
	if !strings.Contains(text, "reducedUnauthenticatedPosture") {
		t.Errorf("the refusal did not reach the caller verbatim: %q", text)
	}
}

// TestTheRefusalIsNotFlattenedIntoAnEmptyResult is the same property from the other side.
// A proxy that turns "denied" into an empty answer is worse than one that errors, because
// the agent cannot tell "it was refused" from "it did nothing", and will retry or assume
// success.
func TestTheRefusalIsNotFlattenedIntoAnEmptyResult(t *testing.T) {
	server := newTestServer()
	server.client = denyingClient(reasonRef("denied: notPermitted"))

	result, err := server.handleClipboard(&ToolCall{
		Name:      "clipboard",
		Arguments: json.RawMessage(`{"action":"get"}`),
	})
	if err != nil {
		t.Fatalf("handler returned a transport error: %v", err)
	}
	if !resultIsError(result) {
		t.Fatal("a refused clipboard read came back as a success with empty content")
	}
	if strings.Contains(resultText(result), "Clipboard is empty") {
		t.Error("a refusal was reported to the agent as an empty clipboard")
	}
}

// TestTheFeatureSwitchIsNotTheSecurityControl separates the two questions the shell gate and
// the authorization model were being read as answering.
//
// The switch decides whether the feature is OFFERED. The control is per request and lives on
// the server. If the message on refusal implies the switch is what grants access, an operator
// reads the flag as the control and the consent system as a formality — which inverts both.
func TestTheFeatureSwitchIsNotTheSecurityControl(t *testing.T) {
	server := newTestServer()
	server.cfg.ShellCommandsEnabled = false

	result, err := server.handleRun(&ToolCall{
		Name:      "run",
		Arguments: json.RawMessage(`{"type":"shell","command":"/bin/echo hi"}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	text := resultText(result)
	for _, clause := range []string{"not offered", "decided separately"} {
		if !strings.Contains(text, clause) {
			t.Errorf("the refusal does not say %q, so it still reads as though the flag is the control: %q", clause, text)
		}
	}
	// And with the switch on, the request still goes to the server — the switch does not
	// short-circuit the control, it removes the offer.
	server.cfg.ShellCommandsEnabled = true
	server.client = denyingClient(reasonRef("denied: notPermitted"))
	enabled, err := server.handleRun(&ToolCall{
		Name:      "run",
		Arguments: json.RawMessage(`{"type":"shell","command":"/bin/echo hi"}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	if !resultIsError(enabled) {
		t.Error("enabling the feature switch bypassed the server's control")
	}
}

// denyingClient refuses the two calls these tests drive, with a gRPC permission error,
// the way the real server does when authorization denies. It is the existing suite's mock
// rather than a second one, because a second full implementation of a 68-method client
// interface is a second thing that can fall behind the interface.
func denyingClient(reason *string) *mockExactMacClient {
	denied := func(context.Context, *pb.ExecuteShellCommandRequest) (*pb.ExecuteShellCommandResponse, error) {
		return nil, status.Error(codes.PermissionDenied, *reason)
	}
	emptyClipboard := func(context.Context, *pb.GetClipboardRequest) (*pb.Clipboard, error) {
		return nil, status.Error(codes.PermissionDenied, *reason)
	}
	return &mockExactMacClient{
		executeShellCommandFunc: denied,
		getClipboardFunc:        emptyClipboard,
	}
}

func reasonRef(reason string) *string { return &reason }
