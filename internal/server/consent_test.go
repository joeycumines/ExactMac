// Copyright 2025 Joseph Cumines
//
// The agent-facing half of consent: the reason, and the fact that it reaches the server.

package server

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"google.golang.org/grpc/metadata"
)

// TestEveryToolCarriesTheReasonAndTheGuidance is the check that makes the contract a
// property of the REGISTRY rather than a habit. An agent cannot know in advance which of its
// calls will need consent, because the server derives the capability from the request bytes
// and not from anything the agent declares — so a `reason` that appears on only some tools is
// one an agent learns to omit, and the prompt then asks a person to judge a request nobody
// explained.
func TestEveryToolCarriesTheReasonAndTheGuidance(t *testing.T) {
	// A server with the REGISTRY built, because the property under test is a property of
	// the registry and a bare test server has no tools on it.
	server := newTestServer()
	server.registerTools()
	if len(server.tools) == 0 {
		t.Fatal("no tools are registered")
	}
	for name, tool := range server.tools {
		properties, ok := tool.InputSchema["properties"].(map[string]any)
		if !ok {
			t.Errorf("tool %q has no properties object, so it cannot carry a reason", name)
			continue
		}
		if _, present := properties["reason"]; !present {
			t.Errorf("tool %q does not accept a reason", name)
		}
		if !strings.Contains(tool.Description, "CONSENT") {
			t.Errorf("tool %q carries no consent guidance", name)
		}
		for _, clause := range []string{"ALWAYS PASS", "NAME YOUR TARGET", "BATCH INSIDE ONE TRANSACTION", "READ THE NOTE"} {
			if !strings.Contains(tool.Description, clause) {
				t.Errorf("tool %q guidance is missing %q", name, clause)
			}
		}
	}
}

// TestTheReasonReachesTheServerAsMetadata is the half that makes the property real rather
// than declared: the reason has to be on the wire, because that is the only channel the
// server reads it from.
func TestTheReasonReachesTheServerAsMetadata(t *testing.T) {
	call := &ToolCall{Arguments: json.RawMessage(`{"reason":"summarising the notes you asked about"}`)}
	outgoing, _ := metadata.FromOutgoingContext(withAgentReason(context.Background(), call))

	values := outgoing.Get(AgentReasonMetadataKey)
	if len(values) != 1 {
		t.Fatalf("reason metadata = %v, want exactly one value", values)
	}
	if values[0] != "summarising the notes you asked about" {
		t.Errorf("reason on the wire = %q", values[0])
	}
	// And the origin travels with it, so the server can tell this layer apart from a
	// direct gRPC caller.
	if origin := outgoing.Get(OriginMetadataKey); len(origin) != 1 || origin[0] != "mcp" {
		t.Errorf("origin metadata = %v, want [mcp]", origin)
	}
}

// TestABlankReasonIsAbsentRatherThanSatisfyingTheRequirement is the case that a
// length-maximising caller would find first. A reason of "" is not a reason, and treating it
// as one would let the requirement be met by sending nothing.
func TestABlankReasonIsAbsentRatherThanSatisfyingTheRequirement(t *testing.T) {
	for _, arguments := range []string{
		`{}`,
		`{"reason":""}`,
		`{"reason":"   "}`,
		`{"reason":"\n\t "}`,
	} {
		call := &ToolCall{Arguments: json.RawMessage(arguments)}
		if got := agentReasonFromCall(call); got != "" {
			t.Errorf("agentReasonFromCall(%s) = %q, want empty", arguments, got)
		}
		outgoing, _ := metadata.FromOutgoingContext(withAgentReason(context.Background(), call))
		if values := outgoing.Get(AgentReasonMetadataKey); len(values) != 0 {
			t.Errorf("%s sent reason metadata %v; an absent reason sends nothing", arguments, values)
		}
	}
}

// TestALongReasonIsBounded rather than refused, because a long reason is still a reason and
// the bound exists to keep the prompt's decision controls on screen rather than to reject the
// agent's explanation.
func TestALongReasonIsBounded(t *testing.T) {
	long := strings.Repeat("x", MaxAgentReasonLength*2)
	encoded, err := json.Marshal(long)
	if err != nil {
		t.Fatal(err)
	}
	call := &ToolCall{Arguments: json.RawMessage(`{"reason":` + string(encoded) + `}`)}
	got := agentReasonFromCall(call)
	if len(got) != MaxAgentReasonLength {
		t.Errorf("reason length = %d, want %d", len(got), MaxAgentReasonLength)
	}
}

// TestTheReasonIsReadFromTheRawArguments rather than a parsed struct is what lets one seam
// serve every tool. A handler that forgot to parse `reason` would still be covered.
func TestTheReasonIsReadFromTheRawArguments(t *testing.T) {
	call := &ToolCall{Arguments: json.RawMessage(`{"some_other_field":"x","reason":"because"}`)}
	if got := agentReasonFromCall(call); got != "because" {
		t.Errorf("agentReasonFromCall = %q, want %q", got, "because")
	}
	if got := agentReasonFromCall(nil); got != "" {
		t.Errorf("agentReasonFromCall(nil) = %q", got)
	}
	if got := agentReasonFromCall(&ToolCall{}); got != "" {
		t.Errorf("agentReasonFromCall(empty) = %q", got)
	}
	if got := agentReasonFromCall(&ToolCall{Arguments: json.RawMessage(`not json`)}); got != "" {
		t.Errorf("agentReasonFromCall(garbage) = %q", got)
	}
}
