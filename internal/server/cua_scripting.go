// Copyright 2025 Joseph Cumines
//
// Scripting tool handler — unified run with type discriminator

package server

import (
	"context"
	"encoding/json"
	"time"

	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"google.golang.org/protobuf/types/known/durationpb"
)

// handleRun handles the run tool — execute scripts/commands.
// Type discriminator: shell (default), applescript, javascript.
func (s *MCPServer) handleRun(call *ToolCall) (*ToolResult, error) {
	var params struct {
		Command string `json:"command"`
		Type    string `json:"type"`
		Timeout int32  `json:"timeout"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}

	if params.Command == "" {
		return errorResult("command parameter is required"), nil
	}

	if errResult := validateInputLen(params.Command, maxInputTextLen, "command"); errResult != nil {
		return errResult, nil
	}

	// Default type is shell
	if params.Type == "" {
		params.Type = "shell"
	}

	// Default timeout
	timeout := params.Timeout
	if timeout <= 0 {
		timeout = defaultScriptTimeout
	}

	// Use the shorter of script-specific timeout and request timeout (M6 follow-up).
	// This prevents a long-running script from consuming the full request budget.
	scriptTimeout := time.Duration(timeout) * time.Second
	requestTimeout := time.Duration(s.cfg.RequestTimeout) * time.Second
	effectiveTimeout := requestTimeout
	if scriptTimeout > 0 && scriptTimeout < requestTimeout {
		effectiveTimeout = scriptTimeout
	}
	ctx, cancel := context.WithTimeout(s.toolCallContext(call), effectiveTimeout)
	defer cancel()

	switch params.Type {
	case "shell":
		return s.runShell(ctx, params.Command, timeout, effectiveTimeout)
	case "applescript":
		return s.runAppleScript(ctx, params.Command, timeout, effectiveTimeout)
	case "javascript":
		return s.runJavaScript(ctx, params.Command, timeout, effectiveTimeout)
	default:
		return errorResultf("Unknown type: %s. Valid: shell, applescript, javascript", params.Type), nil
	}
}

// runShell executes a shell command.
func (s *MCPServer) runShell(ctx context.Context, command string, timeout int32, effectiveTimeout time.Duration) (*ToolResult, error) {
	// This is a FEATURE SWITCH, not the security control, and the distinction is the whole
	// point of the line.
	//
	// The control is on the server: whatever this layer allows is still authorized per
	// request by a person, and setting the switch on buys an agent the ability to ASK, not
	// the ability to run. The previous message said "set MCP_SHELL_COMMANDS_ENABLED=true to
	// enable", which reads as though turning it on were the thing standing between the agent
	// and a shell — so an operator reading it would believe the flag was the control and
	// that the consent system was a formality. It is the other way round.
	if !s.cfg.ShellCommandsEnabled {
		return errorResult(
			"Shell command execution is not offered by this configuration " +
				"(MCP_SHELL_COMMANDS_ENABLED). This switch decides whether the feature is " +
				"available at all; permission to run a command is decided separately, per " +
				"request, by the person operating the machine.",
		), nil
	}

	resp, err := s.client.ExecuteShellCommand(ctx, &pb.ExecuteShellCommandRequest{
		Command: command,
		Timeout: durationpb.New(time.Duration(timeout) * time.Second),
	})
	if err != nil {
		return grpcErrorResultWithTimeout(err, "run", effectiveTimeout), nil
	}

	if resp.Error != "" {
		return errorResultf("Shell execution error: %s", resp.Error), nil
	}

	output := resp.Stdout
	if resp.Stderr != "" {
		if output != "" {
			output += "\n\nSTDERR:\n" + resp.Stderr
		} else {
			output = "STDERR:\n" + resp.Stderr
		}
	}

	if resp.ExitCode != 0 {
		return errorResultf("Command exited with code %d\n%s", resp.ExitCode, output), nil
	}

	if output == "" {
		return textResult("Command executed (no output)"), nil
	}

	return textResult(output), nil
}

// runAppleScript executes an AppleScript.
func (s *MCPServer) runAppleScript(ctx context.Context, script string, timeout int32, effectiveTimeout time.Duration) (*ToolResult, error) {
	resp, err := s.client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
		Script:  script,
		Timeout: durationpb.New(time.Duration(timeout) * time.Second),
	})
	if err != nil {
		return grpcErrorResultWithTimeout(err, "run", effectiveTimeout), nil
	}

	if !resp.Success || resp.Error != "" {
		return errorResultf("AppleScript error: %s", resp.Error), nil
	}

	if resp.Output == "" {
		return textResult("Script executed (no output)"), nil
	}

	return textResultf("AppleScript result: %s", resp.Output), nil
}

// runJavaScript executes a JXA script.
func (s *MCPServer) runJavaScript(ctx context.Context, script string, timeout int32, effectiveTimeout time.Duration) (*ToolResult, error) {
	resp, err := s.client.ExecuteJavaScript(ctx, &pb.ExecuteJavaScriptRequest{
		Script:  script,
		Timeout: durationpb.New(time.Duration(timeout) * time.Second),
	})
	if err != nil {
		return grpcErrorResultWithTimeout(err, "run", effectiveTimeout), nil
	}

	if !resp.Success || resp.Error != "" {
		return errorResultf("JavaScript error: %s", resp.Error), nil
	}

	if resp.Output == "" {
		return textResult("Script executed (no output)"), nil
	}

	return textResultf("JavaScript result: %s", resp.Output), nil
}
