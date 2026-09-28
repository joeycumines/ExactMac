// Copyright 2025 Joseph Cumines
//
// ExactMac CLI - one Go binary. `exactmac mcp` serves the 29 CUA-aligned
// macOS automation tools over MCP on stdio; `exactmac http` serves Streamable
// HTTP.

package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/joeycumines/ExactMac/internal/config"
	"github.com/joeycumines/ExactMac/internal/server"
	"github.com/joeycumines/ExactMac/internal/transport"
)

const usageText = `Usage: exactmac <command>

Commands:
  mcp         Run the MCP server over stdio
  http        Run the MCP server over Streamable HTTP
  health      Ask the server whether it is serving, and exit non-zero if it is not
  help        Show this help
  version     Show version
`

func main() {
	if err := run(os.Args[1:]); err != nil {
		log.Printf("Server error: %v", err)
		os.Exit(1)
	}
}

// run dispatches the CLI. args is os.Args without the program name, so tests
// can drive dispatch without spawning a process.
func run(args []string) error {
	if len(args) == 0 {
		fmt.Fprint(os.Stderr, usageText)
		return errors.New("no command provided")
	}
	switch args[0] {
	case "mcp":
		if len(args) > 1 {
			return fmt.Errorf("unknown arguments for mcp: %v", args[1:])
		}
		return runMCP(config.TransportStdio)
	case "http":
		if len(args) > 1 {
			return fmt.Errorf("unknown arguments for http: %v", args[1:])
		}
		return runMCP(config.TransportHTTP)
	case "health":
		return runHealth(args[1:])
	case "help", "-h", "--help":
		fmt.Fprint(os.Stderr, usageText)
		return nil
	case "version", "-v", "--version":
		fmt.Fprintln(os.Stderr, "exactmac 0.1.0")
		return nil
	default:
		fmt.Fprint(os.Stderr, usageText)
		return fmt.Errorf("unknown command: %q", args[0])
	}
}

// runHealth is the deployment's liveness probe. It exists because a socket node and a
// loaded launchd job are not a serving server: a node left by a previous run satisfies
// every mode and ownership check, and a job in its restart backoff reports
// `state = running` between attempts. An installation that cannot tell those apart reports
// success against a server that is crash-looping.
func runHealth(args []string) error {
	if len(args) > 0 {
		return fmt.Errorf("unknown arguments for health: %v", args)
	}
	cfg, err := config.Load(config.TransportStdio)
	if err != nil {
		return fmt.Errorf("could not read the configuration: %w", err)
	}
	serving, err := server.CheckHealth(context.Background(), cfg, 5*time.Second)
	if err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "server health: %s\n", serving)
	return nil
}

func runMCP(transportType config.TransportType) error {
	cfg, err := config.Load(transportType)
	if err != nil {
		return fmt.Errorf("failed to load configuration: %w", err)
	}

	mcpServer, err := server.NewMCPServer(cfg)
	if err != nil {
		return fmt.Errorf("failed to create MCP server: %w", err)
	}

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(sigChan)

	serve := func() error {
		switch transportType {
		case config.TransportHTTP:
			return runHTTPTransport(cfg, mcpServer)
		default:
			return runStdioTransport(cfg, mcpServer)
		}
	}
	return supervise(serve, mcpServer.Shutdown, sigChan)
}

func supervise(serve func() error, shutdown func() error, signals <-chan os.Signal) error {
	serveDone := make(chan error, 1)
	go func() {
		serveDone <- serve()
	}()

	select {
	case sig := <-signals:
		log.Printf("Received signal %v, shutting down...", sig)
		shutdownErr := shutdown()
		select {
		case serveErr := <-serveDone:
			log.Println("Server shutdown complete")
			return errors.Join(serveErr, shutdownErr)
		case <-signals:
			log.Println("Forced shutdown")
			return shutdownErr
		}
	case serveErr := <-serveDone:
		if serveErr == nil {
			log.Println("Transport closed, shutting down...")
		}
		shutdownErr := shutdown()
		log.Println("Server shutdown complete")
		return errors.Join(serveErr, shutdownErr)
	}
}

// runStdioTransport runs the MCP server with stdio transport
func runStdioTransport(_ *config.Config, mcpServer *server.MCPServer) error {
	tr := transport.NewStdioTransport(os.Stdin, os.Stdout)
	return mcpServer.Serve(tr)
}

// runHTTPTransport runs the MCP server with Streamable HTTP transport.
func runHTTPTransport(cfg *config.Config, mcpServer *server.MCPServer) error {
	tr := transport.NewHTTPTransport(httpTransportConfig(cfg))
	return mcpServer.ServeHTTP(tr)
}

func httpTransportConfig(cfg *config.Config) *transport.HTTPTransportConfig {
	return &transport.HTTPTransportConfig{
		Address:      cfg.HTTPAddress,
		SocketPath:   cfg.HTTPSocketPath,
		CORSOrigin:   cfg.CORSOrigin,
		ReadTimeout:  cfg.HTTPReadTimeout,
		WriteTimeout: cfg.HTTPWriteTimeout,
		TLSCertFile:  cfg.TLSCertFile,
		TLSKeyFile:   cfg.TLSKeyFile,
		APIKey:       cfg.APIKey,
		RateLimit:    cfg.RateLimit,
	}
}
