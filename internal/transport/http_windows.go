//go:build windows

package transport

import (
	"fmt"
	"net"
)

func (t *HTTPTransport) listenUnixSocket() (net.Listener, error) {
	return nil, fmt.Errorf("unix domain socket transport is not supported on Windows: %q", t.config.SocketPath)
}

func removeUnixSocketIfIdentity(path string, expected unixSocketIdentity) error {
	return nil
}
