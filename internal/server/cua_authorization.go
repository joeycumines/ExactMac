// Copyright 2025 Joseph Cumines
//
// The tools an agent needs to work INSIDE the consent model rather than against it.

package server

import (
	"context"
	"encoding/json"
	"strings"
	"time"

	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"google.golang.org/protobuf/types/known/durationpb"
)

// maxFilterLength bounds the filter parameter length.
const maxFilterLength = 4096

// maxPageTokenLength bounds the page_token parameter length.
const maxPageTokenLength = 4096

// maxRequestedLifetimeSeconds is the maximum duration in seconds that can be safely
// converted to time.Duration without integer overflow (fits within int64 nanoseconds).
const maxRequestedLifetimeSeconds = int64((1<<63 - 1) / int64(time.Second))

// handleListGrants lists the permissions the caller currently holds.
//
// AN AGENT THAT CANNOT SEE WHAT IT HOLDS CANNOT WORK INSIDE A GRANT, so it asks again — and
// asking again costs the operator a prompt they have already answered. This is the tool that
// makes the difference between one prompt for a task and one per step.
func durationpbNew(seconds int64) *durationpb.Duration {
	if seconds <= 0 {
		return durationpb.New(0)
	}
	if seconds > maxRequestedLifetimeSeconds {
		seconds = maxRequestedLifetimeSeconds
	}
	return durationpb.New(time.Duration(seconds) * time.Second)
}

func (s *MCPServer) handleListGrants(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(
		s.toolCallContext(call),
		time.Duration(s.cfg.RequestTimeout)*time.Second,
	)
	defer cancel()

	var params struct {
		PageToken string `json:"page_token"`
		Filter    string `json:"filter"`
	}
	if len(call.Arguments) > 0 {
		if err := json.Unmarshal(call.Arguments, &params); err != nil {
			return errorResultf("Invalid parameters: %v", err), nil
		}
	}
	if len(params.PageToken) > maxPageTokenLength {
		return errorResult("page_token exceeds maximum allowed length of 4096 bytes"), nil
	}
	if len(params.Filter) > maxFilterLength {
		return errorResult("filter exceeds maximum allowed length of 4096 bytes"), nil
	}
	// The filter is passed through VERBATIM so the server owns its grammar. Splitting it here
	// would be a second dialect for the same string, and the two would disagree on the first
	// unusual capability id.
	response, err := s.client.ListGrants(ctx, &pb.ListGrantsRequest{
		PageToken: params.PageToken,
		Filter:    params.Filter,
	})
	if err != nil {
		return grpcErrorResult(err, "list_grants"), nil
	}
	grants := make([]map[string]any, 0, len(response.GetGrants()))
	for _, grant := range response.GetGrants() {
		grants = append(grants, map[string]any{
			"name":                          grant.GetName(),
			"capability":                    grant.GetCapability(),
			"scope":                         grant.GetScope(),
			"holder":                        grant.GetHolder(),
			"holder_is_signed":              grant.GetHolderIsSigned(),
			"holder_designated_requirement": grant.GetHolderDesignatedRequirement(),
			"basis":                         grant.GetBasis(),
			"reason":                        grant.GetReason(),
			"seconds_left":                  grant.GetLifetime().GetSeconds(),
		})
	}
	// A ZERO RESULT IS A LIST, not prose, so an agent can tell "you hold nothing" from "the
	// call failed" — a distinction a sentence loses.
	payload := map[string]any{
		"grants":          grants,
		"next_page_token": response.GetNextPageToken(),
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return errorResultf("Could not encode the grants: %v", err), nil
	}
	return textResult(string(encoded)), nil
}

// handlePreauthorize is the ANTICIPATION TOOL, and it is what makes a long agentic session
// possible: an agent that knows it will need the clipboard and the accessibility tree across
// a refactor says so ONCE, at the start, rather than interrupting its own work at every step.
//
// What it may not do is ask for more than it declared, and the server enforces that: an
// envelope may not cover an undeclared capability, can never be global, and never outlives
// the life it was granted for.
//
// The REASON IS REQUIRED and the refusal says why in the product's words rather than naming
// a missing field, because a pre-authorization is a standing permission and the operator is
// entitled to know why one is being asked for.
func (s *MCPServer) handlePreauthorize(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(
		s.toolCallContext(call),
		time.Duration(s.cfg.RequestTimeout)*time.Second,
	)
	defer cancel()

	var params struct {
		Reason            string   `json:"reason"`
		Capabilities      []string `json:"capabilities"`
		Scopes            []string `json:"scopes"`
		RequestedLifetime *struct {
			Seconds int64 `json:"seconds"`
		} `json:"requested_lifetime"`
	}
	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}
	trimmedReason := strings.TrimSpace(params.Reason)
	if trimmedReason == "" {
		return errorResult(
			"reason is required: a pre-authorization is a standing permission and the " +
				"operator must know why it is being requested",
		), nil
	}
	if runes := []rune(trimmedReason); len(runes) > MaxAgentReasonLength {
		trimmedReason = string(runes[:MaxAgentReasonLength])
	}
	if len(params.Capabilities) == 0 {
		return errorResult(
			"capabilities is required: a pre-authorization must declare what it covers, " +
				"because an envelope may not cover anything you have not named",
		), nil
	}
	if params.RequestedLifetime == nil || params.RequestedLifetime.Seconds <= 0 {
		return errorResult(
			"requested_lifetime is required and must be positive: an envelope that " +
				"expires immediately is not pre-authorization",
		), nil
	}

	envelope, err := s.client.PreauthorizeEnvelope(ctx, &pb.PreauthorizeEnvelopeRequest{
		Reason:            trimmedReason,
		Capabilities:      params.Capabilities,
		Scopes:            params.Scopes,
		RequestedLifetime: durationpbNew(params.RequestedLifetime.Seconds),
	})
	if err != nil {
		return grpcErrorResult(err, "preauthorize"), nil
	}
	// The response reports the life GRANTED, which is the server's ceiling applied rather
	// than the duration asked for. Echoing the request back would let an agent believe it
	// holds for longer than it does.
	payload := map[string]any{
		"id":                envelope.GetId(),
		"capabilities":      envelope.GetCapabilities(),
		"scopes":            envelope.GetScopes(),
		"seconds_granted":   envelope.GetLifetime().GetSeconds(),
		"global_persistent": envelope.GetGlobalPersistent(),
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return errorResultf("Could not encode the envelope: %v", err), nil
	}
	return textResult(string(encoded)), nil
}
