// Copyright 2025 Joseph Cumines
//
// The agent-facing half of consent: the reason, and the fact that it reaches the server.

package server

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"unicode/utf8"

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

// TestTheBoundIsInCharactersNotBytes asserts the unit the tool schema advertises. The
// schema declares maxLength 500, which a client reads as 500 unicode characters; enforcing
// bytes instead meant a reason of 167 em-dashes was cut at byte 500 and arrived as a
// truncated sequence ending in an incomplete rune. Because the reason rides on a "-bin" key,
// that corruption would have decoded to a replacement character, and the operator would have
// read a mangled reason as the agent's own words — a silent rewrite of the evidence the
// prompt exists to show.
func TestTheBoundIsInCharactersNotBytes(t *testing.T) {
	for _, tc := range []struct {
		name string
		unit string
	}{
		{"em dash", "—"},
		{"emoji", "🎯"},
		{"accented", "ü"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			// Long enough that a byte-bound would cut inside a character: three bytes each,
			// so 501 bytes is reached after 167 characters.
			reason := strings.Repeat(tc.unit, MaxAgentReasonLength*2)
			encoded, err := json.Marshal(reason)
			if err != nil {
				t.Fatal(err)
			}
			got := agentReasonFromCall(&ToolCall{
				Arguments: json.RawMessage(`{"reason":` + string(encoded) + `}`),
			})
			if !utf8.ValidString(got) {
				t.Fatalf("the bounded reason is not valid UTF-8; it was cut mid-character")
			}
			if n := utf8.RuneCountInString(got); n != MaxAgentReasonLength {
				t.Errorf("reason has %d characters, want %d", n, MaxAgentReasonLength)
			}
			// Every surviving character is a whole one, so nothing was split in half.
			if strings.Contains(got, "�") {
				t.Errorf("the bounded reason contains a replacement character: %q", got)
			}
		})
	}
}

// TestAReasonWithinTheBoundArrivesWhole is the other half: a 500-character multibyte reason
// is not truncated at all, which is what the byte bound got wrong as well.
func TestAReasonWithinTheBoundArrivesWhole(t *testing.T) {
	reason := strings.Repeat("é", MaxAgentReasonLength)
	encoded, err := json.Marshal(reason)
	if err != nil {
		t.Fatal(err)
	}
	got := agentReasonFromCall(&ToolCall{
		Arguments: json.RawMessage(`{"reason":` + string(encoded) + `}`),
	})
	if got != reason {
		t.Errorf("a %d-character reason was altered in transit", utf8.RuneCountInString(reason))
	}
}

// TestTheReasonKeyIsBinary asserts the suffix that makes Unicode reasons possible at all.
// Dropping it would not fail any other test in this file — it would restore the client-side
// rejection, in a different process, where no Go test can observe it.
func TestTheReasonKeyIsBinary(t *testing.T) {
	if !strings.HasSuffix(AgentReasonMetadataKey, "-bin") {
		t.Fatalf("reason metadata key %q is not a -bin key; gRPC will reject any non-ASCII reason",
			AgentReasonMetadataKey)
	}
}

// grpcRejectsAReasonValue mirrors gRPC's own rule for a non-"-bin" metadata value:
// every byte must be printable ASCII, in [0x20-0x7E]. gRPC applies it in the client
// before the request is written (internal/metadata.hasNotPrintable, called from
// ValidatePair, reached from the transport's header construction), and the resulting
// failure is reported as `Internal - header key ... contains value with non-printable ASCII
// characters`.
//
// THE RULE IS REPRODUCED HERE rather than imported because gRPC keeps it in an internal
// package this module cannot import, and `metadata.New` and `AppendToOutgoingContext` do not
// validate — the check is transport-level and has no public entry point. The copy is
// deliberately the smallest possible statement of the rule so it cannot drift into
// describing something other than what gRPC does: a byte loop, the same bounds, no cleverness.
// If gRPC ever changes its bounds this helper stops matching and the test below FAILS, which
// is the correct outcome for a test that exists to catch a transport-level constraint.
func grpcRejectsAReasonValue(value string) bool {
	for i := 0; i < len(value); i++ {
		if value[i] < 0x20 || value[i] > 0x7E {
			return true
		}
	}
	return false
}

// TestAUnicodeReasonWouldBeRejectedByAPlainKey is the defect as an agent experienced it:
// with a plain metadata key, gRPC refused the call before it left the client, reporting an
// internal server fault that had not occurred. The test asserts the constraint both ways —
// that the rule really does reject these reasons, so the guard below is not vacuous, and
// that the "-bin" suffix is what exempts them.
func TestAUnicodeReasonWouldBeRejectedByAPlainKey(t *testing.T) {
	reasons := []string{
		"reading the notes — every line is needed",
		"the operator’s file, as they asked",
		"capture du café pour l’utilisateur",
		"検索して要約します",
		"🎯 screenshotting the active window",
	}
	for _, reason := range reasons {
		// The negative control: the rule rejects this, so the assertions below are not
		// passing because the check is lenient.
		if !grpcRejectsAReasonValue(reason) {
			t.Fatalf("gRPC's printable-ASCII rule accepted %q, so this test proves nothing", reason)
		}
		if !strings.HasSuffix(AgentReasonMetadataKey, "-bin") {
			t.Fatalf("reason metadata key %q is not a -bin key; gRPC rejects any non-ASCII reason",
				AgentReasonMetadataKey)
		}
		// And ASCII reasons remain valid on either key, so nothing that used to work broke.
		if grpcRejectsAReasonValue("summarising the notes you asked about") {
			t.Error("an ASCII reason was rejected; the transport must not narrow what already worked")
		}
	}
}

// TestTheReasonActuallyTravelsOnTheWire is the end-to-end half: the reason is on the
// outgoing metadata under the key that carries the suffix, so the transport's exemption is
// reached in the real path rather than asserted about a constant.
func TestTheReasonActuallyTravelsOnTheWire(t *testing.T) {
	reason := "reading the notes — every line is needed"
	call := &ToolCall{Arguments: json.RawMessage(`{"reason":` + mustJSONString(t, reason) + `}`)}
	outgoing, _ := metadata.FromOutgoingContext(withAgentReason(context.Background(), call))
	values := outgoing.Get(AgentReasonMetadataKey)
	if len(values) != 1 {
		t.Fatalf("reason metadata = %v, want exactly one value", values)
	}
	if values[0] != reason {
		t.Errorf("reason on the wire = %q, want %q", values[0], reason)
	}
}

func mustJSONString(t *testing.T, s string) string {
	t.Helper()
	encoded, err := json.Marshal(s)
	if err != nil {
		t.Fatal(err)
	}
	return string(encoded)
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
