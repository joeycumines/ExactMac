// Copyright 2025 Joseph Cumines
//
// The agent-facing half of consent: the reason, and the guidance that makes it worth giving.

package server

import (
	"context"
	"encoding/json"
	"strings"

	"google.golang.org/grpc/metadata"
)

// AgentReasonMetadataKey carries the agent's stated reason for a request.
//
// IT IS METADATA, NOT A PROTO FIELD, and that is deliberate. The reason is CALLER-SUPPLIED
// TEXT: it is shown to the operator inside a field that says, in the product's own words, that
// it is not verified. Putting it in the request message would make it look like part of the
// request being authorized rather than a claim about it, and the design's whole safety
// argument for the prompt rests on that distinction. Metadata also means adding the reason
// does not change any request message, so it cannot change what a grant is scoped to.
// The key is suffixed "-bin" AND IT MUST STAY THAT WAY, because a plain metadata value is
// restricted to printable ASCII by gRPC itself.
//
// `ValidatePair` in google.golang.org/grpc@v1.79.3/internal/metadata/metadata.go requires
// every byte of a non-"-bin" value to be in [0x20-0x7E] and returns early WITHOUT validating
// the value when the key ends in "-bin". The check runs in the client before the request is
// written, so a plain key does not carry this text imperfectly — it REJECTS the call outright,
// reporting `Internal - header key "..." contains value with non-printable ASCII characters`.
// An em-dash, a curly quote, an accent, an emoji or a CJK character is enough, and the error
// names an internal server fault that did not happen and tells the agent nothing actionable.
//
// The "-bin" suffix makes gRPC treat the value as BINARY and base64-encode it on the wire
// (internal/transport/http_util.go:140 encodeMetadataHeader), so the reason crosses intact
// and the Swift server reads it back through `Metadata[binaryValues:]`, which decodes the
// base64 for us. The alternative — stripping non-ASCII before sending — is worse than a
// crash: it would put text in the operator's prompt that the agent never wrote, and this
// reason is displayed precisely so the operator can judge the agent's own words.
const AgentReasonMetadataKey = "exactmac-agent-reason-bin"

// OriginMetadataKey announces that a request arrived through the Go MCP layer.
//
// IT IS A CLAIM AND NOT AN IDENTITY, and the server treats it as one: the engine raises
// the risk class for a request it cannot attribute, and the peer identity the operator
// judges comes from the socket rather than from anything a caller says about itself. A
// caller can claim to be the MCP layer, and claiming so buys it nothing except the
// slightly higher friction of an attributed-but-unverified origin.
const OriginMetadataKey = "exactmac-origin"

// MaxAgentReasonLength bounds the reason.
//
// It is bounded because the reason is rendered in a fixed-height prompt beside a 236pt
// scroll region, and an unbounded string is a way to push the operator's actual decision
// controls off the bottom of the window. 500 characters is roughly four sentences, which is
// more than a reason needs and less than a payload.
//
// The unit is CHARACTERS and not bytes, deliberately. It was bytes before, and a byte bound
// is a latent corruption: cutting a multi-byte character at the limit leaves an incomplete
// UTF-8 sequence, which is not merely ugly — once the value rides on a "-bin" key it would
// base64-decode to a replacement character, and the operator would read a mangled reason as
// the agent's own words. That is a silent rewrite of the operator's evidence, so the bound is
// applied on a rune boundary and the tool schema's maxLength means the same thing it means
// to a client.
const MaxAgentReasonLength = 500

// agentReasonSchema is the property every tool carries.
//
// It is added to EVERY tool rather than to the twenty-odd that can trigger consent, because
// the agent cannot know in advance which of its calls will need one — the server derives
// the capability from the request bytes — and a property that appears only sometimes is a
// property an agent learns to omit.
var agentReasonSchema = map[string]any{
	"type":      "string",
	"maxLength": MaxAgentReasonLength,
	"description": "WHY you are making this request, in your own words, for the person who " +
		"will read it. This is REQUIRED on anything that needs consent and it is shown " +
		"verbatim, marked as unverified, in the approval prompt. An unexplained request is " +
		"one the operator should decline, and one without a reason is escalated rather than " +
		"treated as routine. Say what you are about to do and why, not what you were asked.",
}

// AgentGuidance is appended to the consent-relevant tools' descriptions.
//
// AGENT BEHAVIOUR DETERMINES UX QUALITY, which is why this is written at all. A prompt
// that asks the operator to judge a request in four seconds is only as good as the sentence
// the agent put in it, and the difference between "summarising a document" and "cloning the
// git repo" is one an agent can state and an operator can act on.
const AgentGuidance = `

CONSENT — READ THIS BEFORE CALLING ANYTHING THAT TOUCHES THE SCREEN, THE CLIPBOARD, THE KEYBOARD, OR RUNS CODE.

Every call on this Mac is authorized by a person, not by you. ExactMac derives what a call
needs from the request itself; it does not ask you what you want it to need. When a call
needs consent the person sees a prompt and decides, and you will wait.

1. ALWAYS PASS "reason" ON EVERY CALL. It is the only thing you contribute to their
   decision. Say what you are about to do and why, in one sentence, in the plainest words
   you have. "Summarising the notes file you asked about" is a decision they can make.
   "Processing request" is not.

2. NAME YOUR TARGET PRECISELY. Pass the exact application or window resource name you got
   from list_*, never a guess and never "whichever is focused". A narrow target is a cheap
   approval; a broad one costs the person a fingerprint, and you are spending their
   attention.

3. KEEP PAYLOADS SHORT AND READABLE. Put the thing you need in the argument, not a
   program that fetches it, and not a command whose output you have not looked at.

4. ASK NARROW, NOT BROAD. One application for a known duration, not everything for ever.
   A standing permission is a standing liability for the person who granted it.

5. BATCH INSIDE ONE TRANSACTION. A sequence of steps belongs in one macro or one
   transaction so the person is asked once, not once per step.

6. REUSE AN APPROVED ENVELOPE. If you were pre-authorized for a capability set, work inside
   it. Do not re-ask for what you already hold, and do not step outside it because one call
   is easier — a call outside the envelope opens the prompt again and spends their
   attention a second time.

7. IF YOU ARE DECLINED, READ THE NOTE. The person sends back why. Adjust and ask again
   narrowly, or stop. Repeating the same request after a decline is not persistence.`

// agentReasonFromCall extracts the reason from a tool call's arguments.
//
// It reads the RAW arguments rather than each handler's parsed struct, so every tool gets
// the reason without every handler knowing about it. A missing or blank reason is nil, not an
// empty string: the server distinguishes "no reason given" from a reason that happens to be
// blank, and a blank string that counted as a reason would be a way to satisfy the
// requirement without saying anything.
func agentReasonFromCall(call *ToolCall) string {
	if call == nil || len(call.Arguments) == 0 {
		return ""
	}
	var args struct {
		Reason *string `json:"reason"`
	}
	if err := json.Unmarshal(call.Arguments, &args); err != nil || args.Reason == nil {
		return ""
	}
	trimmed := strings.TrimSpace(*args.Reason)
	if trimmed == "" {
		return ""
	}
	// THE BOUND IS IN CHARACTERS, so it counts and cuts on a rune boundary. A byte slice
	// here would leave an incomplete UTF-8 sequence at the end of a reason written in any
	// language that is not ASCII.
	if runes := []rune(trimmed); len(runes) > MaxAgentReasonLength {
		trimmed = string(runes[:MaxAgentReasonLength])
	}
	return trimmed
}

// withAgentReason attaches the caller's reason to the outgoing gRPC context.
//
// It returns the ORIGINAL context when there is no reason, so a call with no reason
// produces no metadata at all rather than an empty header — the server then knows the
// reason was absent instead of knowing it was blank.
func withAgentReason(ctx context.Context, call *ToolCall) context.Context {
	// The origin goes on unconditionally, so the server always knows which layer a request
	// came through — an unattributed origin is escalated, and that is only meaningful if
	// arriving directly is distinguishable from arriving here.
	outgoing := metadata.AppendToOutgoingContext(ctx, OriginMetadataKey, "mcp")
	reason := agentReasonFromCall(call)
	if reason == "" {
		return outgoing
	}
	return metadata.AppendToOutgoingContext(outgoing, AgentReasonMetadataKey, reason)
}
