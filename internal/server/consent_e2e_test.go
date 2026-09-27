// Copyright 2025 Joseph Cumines
//
// The agent-facing half of consent, driven end to end: the reason reaches the server, a
// pre-authorization carries exactly what was declared, and the answer reports the life
// GRANTED rather than the life asked for.

package server

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"time"

	"google.golang.org/protobuf/types/known/durationpb"
)

// newConsentServer wires a mock client whose two administrative calls record what reached
// them. The envelope it returns is SHORTER than the one asked for, which is the case a
// client must not get wrong.
func newConsentServer(grantedSeconds int64) (*MCPServer, *struct {
	reason       string
	capabilities []string
	lifetime     int64
}) {
	// The FIELDS rather than the message: a generated protobuf carries a mutex, and copying
	// one is a data race that `go vet` is right to refuse. The test wants to know what
	// arrived, and three strings say that without copying a lock.
	seen := &struct {
		reason       string
		capabilities []string
		lifetime     int64
	}{}
	mock := new(mockExactMacClient)
	mock.preauthorizeEnvelopeFn = func(
		_ context.Context, in *pb.PreauthorizeEnvelopeRequest,
	) (*pb.PreauthorizeEnvelopeResponse, error) {
		seen.reason = in.GetReason()
		seen.capabilities = append([]string(nil), in.GetCapabilities()...)
		seen.lifetime = in.GetRequestedLifetime().GetSeconds()
		return &pb.PreauthorizeEnvelopeResponse{
			Id:               "envelope-1",
			Capabilities:     in.GetCapabilities(),
			Scopes:           in.GetScopes(),
			Lifetime:         durationpb.New(time.Duration(grantedSeconds) * time.Second),
			GlobalPersistent: false,
			Reason:           in.GetReason(),
		}, nil
	}
	mock.listGrantsFunc = func(
		_ context.Context, _ *pb.ListGrantsRequest,
	) (*pb.ListGrantsResponse, error) {
		return &pb.ListGrantsResponse{
			Grants: []*pb.Grant{{
				Name:           "grants/grant-1",
				Capability:     "clipboard.read",
				Scope:          "clipboard.read  ·  TextEdit only  ·  for 5 minutes",
				Holder:         "/usr/local/bin/exactmac",
				HolderIsSigned: false,
				Basis:          "prompt",
				Lifetime:       durationpb.New(3 * 60 * time.Second),
			}},
		}, nil
	}
	server := newTestServer()
	server.client = mock
	return server, seen
}

// TestPreauthorizeReachesTheServerWithItsReasonAndItsDeclaration is the "a Go MCP client
// calls the pre-authorization tool with a reason" half of the acceptance, driven through the
// real tool handler rather than through a stub of it.
func TestPreauthorizeReachesTheServerWithItsReasonAndItsDeclaration(t *testing.T) {
	server, got := newConsentServer(120)

	result, err := server.handlePreauthorize(&ToolCall{
		Name: "preauthorize",
		Arguments: json.RawMessage(`{
			"capabilities": ["clipboard.read", "observation.ax"],
			"reason": "Refactoring the parser, which reads the tree and the clipboard at each step",
			"requested_lifetime": {"seconds": 3600}
		}`),
	})
	if err != nil {
		t.Fatalf("handlePreauthorize returned a transport error: %v", err)
	}
	if resultIsError(result) {
		t.Fatalf("preauthorize refused a well-formed request: %s", resultText(result))
	}
	if got == nil {
		t.Fatal("the server was never called")
	}
	if !strings.Contains(got.reason, "Refactoring the parser") {
		t.Errorf("the reason did not reach the server: %q", got.reason)
	}
	if len(got.capabilities) != 2 {
		t.Errorf("the declared capabilities were altered in flight: %v", got.capabilities)
	}
	if got.lifetime != 3600 {
		t.Errorf("the requested lifetime was altered in flight: %d seconds", got.lifetime)
	}
}

// TestPreauthorizeReportsTheLifeGrantedNotTheLifeAsked is the property that stops an agent
// believing it holds for longer than it does.
func TestPreauthorizeReportsTheLifeGrantedNotTheLifeAsked(t *testing.T) {
	server, _ := newConsentServer(120)

	result, err := server.handlePreauthorize(&ToolCall{
		Name: "preauthorize",
		Arguments: json.RawMessage(`{
			"capabilities": ["clipboard.read"],
			"reason": "because",
			"requested_lifetime": {"seconds": 3600}
		}`),
	})
	if err != nil || resultIsError(result) {
		t.Fatalf("preauthorize failed: %v %s", err, resultText(result))
	}
	if strings.Contains(resultText(result), "3600") {
		t.Errorf("the response echoes the life ASKED for, so the agent will believe it holds for an hour: %s", resultText(result))
	}
	if !strings.Contains(resultText(result), `"seconds_granted":120`) {
		t.Errorf("the response does not report the life GRANTED: %s", resultText(result))
	}
	// And the envelope is never reported as global, because it can never be.
	if !strings.Contains(resultText(result), `"global_persistent":false`) {
		t.Errorf("the response does not state that the envelope is not global: %s", resultText(result))
	}
}

// TestPreauthorizeIsRefusedWithoutADeclaration is the other half of what makes an envelope
// a declaration rather than a blank cheque, and it is refused HERE as well as on the server
// so the agent learns before a prompt is interrupted.
func TestPreauthorizeIsRefusedWithoutADeclaration(t *testing.T) {
	server := newTestServer()
	for _, arguments := range []string{
		`{"reason":"because","requested_lifetime":{"seconds":60}}`,
		`{"capabilities":["clipboard.read"],"requested_lifetime":{"seconds":0}}`,
		`{"capabilities":["clipboard.read"],"reason":"because"}`,
	} {
		result, err := server.handlePreauthorize(&ToolCall{
			Name: "preauthorize", Arguments: json.RawMessage(arguments),
		})
		if err != nil {
			t.Fatal(err)
		}
		if !resultIsError(result) {
			t.Errorf("%s was accepted; an envelope must declare what it covers", arguments)
		}
	}
}

// TestListGrantsReportsTheBindingAndTheRemainingLife is why the introspection tool exists:
// the agent has to see that the grant binds to a BINARY, so a restart does not lose it and a
// different binary does not inherit it.
func TestListGrantsReportsTheBindingAndTheRemainingLife(t *testing.T) {
	server, _ := newConsentServer(60)

	result, err := server.handleListGrants(&ToolCall{
		Name: "list_grants", Arguments: json.RawMessage(`{}`),
	})
	if err != nil || resultIsError(result) {
		t.Fatalf("list_grants failed: %v %s", err, resultText(result))
	}
	body := resultText(result)
	for _, want := range []string{
		`"name":"grants/grant-1"`,
		`"holder":"/usr/local/bin/exactmac"`,
		`"seconds_left":180`,
		`"holder_is_signed":false`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("the listing does not report %s: %s", want, body)
		}
	}
	// An UNSIGNED holder is reported as unsigned. Presenting it as equivalent would tell the
	// agent its grant is bound to a signature when it is bound to a path.
	if strings.Contains(body, `"holder_is_signed":true`) {
		t.Errorf("an unsigned holder was reported as signed: %s", body)
	}
}

// TestTheReasonTravelsWithAPreauthorization is the join between the two halves: a tool that
// forgets the reason is one that interrupts an operator for nothing.
func TestTheReasonTravelsWithAPreauthorization(t *testing.T) {
	server, got := newConsentServer(60)

	call := &ToolCall{
		Name: "preauthorize",
		Arguments: json.RawMessage(`{
			"capabilities": ["clipboard.read"],
			"reason": "reading the clipboard for the summary you asked for",
			"requested_lifetime": {"seconds": 120}
		}`),
	}
	// The reason reaches the server BOTH as the request field and as the metadata the
	// interceptor reads, and they have to agree — the prompt shows the field and the policy
	// escalates on the metadata.
	if _, err := server.handlePreauthorize(call); err != nil {
		t.Fatal(err)
	}
	if got.reason != "reading the clipboard for the summary you asked for" {
		t.Errorf("the request field lost the reason: %q", got.reason)
	}
	if agentReasonFromCall(call) != "reading the clipboard for the summary you asked for" {
		t.Errorf("the metadata path lost the reason: %q", agentReasonFromCall(call))
	}
}
