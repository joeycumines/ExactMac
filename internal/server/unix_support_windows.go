//go:build windows

package server

import (
	"fmt"
	"os"
)

func checkUnixSocketOwnershipAndPermissions(info os.FileInfo, path string) error {
	return nil
}

func checkDirectoryOwnership(info os.FileInfo, directory string) error {
	return nil
}

func bindUnixSocketName(fd int, name string) error {
	return fmt.Errorf("unix domain socket bind is not supported on Windows")
}
