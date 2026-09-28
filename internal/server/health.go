// Copyright 2025 Joseph Cumines
//
// The live liveness probe the deployment uses.
//
// IT EXISTS BECAUSE A SOCKET NODE AND A RUNNING LAUNCHD JOB ARE NOT A SERVING SERVER.
// A node left at the pathname by a previous run satisfies every mode, owner and type
// check, and a job in its restart backoff reports `state = running` between attempts, so
// `gmake exactmac.install` reported success against a server that was crash-looping on a
// startup failure. A real request is the only thing that distinguishes them, and this
// command makes that one request: gRPC `Health/Check` over the Unix socket, exiting
// non-zero unless the server answers SERVING.
//
// IT ALSO EXERCISES THE PEER-IDENTITY DIALER, because it builds its client through the
// same options the MCP server uses. A probe that connected some other way would be a probe
// that could pass while the real client could not.

package server

import (
	"context"
	"fmt"
	"time"

	"google.golang.org/grpc"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"

	"github.com/joeycumines/ExactMac/internal/config"
)

// CheckHealth asks the server whether it is serving, over the configured socket.
//
// - Returns: the serving status on success. Every failure is an error, because a probe
//   that cannot tell "not serving" from "could not ask" cannot gate an installation.
func CheckHealth(ctx context.Context, cfg *config.Config, timeout time.Duration) (string, error) {
	if cfg.ServerSocketPath == "" {
		return "", fmt.Errorf(
			"no server socket is configured: set EXACTMAC_SERVER_SOCKET_PATH or run against a TCP address",
		)
	}
	if err := validateUnixSocketEndpoint(cfg.ServerSocketPath); err != nil {
		return "", fmt.Errorf("the server socket is not usable: %w", err)
	}
	opts, err := grpcClientDialOptions(cfg)
	if err != nil {
		return "", err
	}
	// NO CREDENTIALS OPTION IS ADDED HERE, and the reason is that the options already carry
	// exactly one. Appending a second `WithTransportCredentials` on top of
	// `grpcClientDialOptions` produced a client that resolved the `unix` target correctly
	// and then dialled `tcp`, which is a failure with no sensible reading — and the MCP
	// path, which builds its client from the same options without the extra append, is the
	// path that works. The probe uses the product's client construction unchanged, which is
	// also what makes it worth having.
	connection, err := grpc.NewClient("unix://"+cfg.ServerSocketPath, opts...)
	if err != nil {
		return "", fmt.Errorf("could not build a health client: %w", err)
	}
	defer func() {
		_ = connection.Close()
	}()

	callCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	response, err := healthpb.NewHealthClient(connection).Check(callCtx, &healthpb.HealthCheckRequest{})
	if err != nil {
		return "", fmt.Errorf("the server did not answer a health check: %w", err)
	}
	serving := response.GetStatus().String()
	if serving != healthpb.HealthCheckResponse_SERVING.String() {
		return serving, fmt.Errorf("the server reports %s rather than SERVING", serving)
	}
	return serving, nil
}
