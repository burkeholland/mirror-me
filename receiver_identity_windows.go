//go:build windows

package main

import (
	"os"

	"golang.org/x/sys/windows"
)

func openReceiverIdentity(path string) (*os.File, error) {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	// A rename becomes visible before MoveFileEx closes its delete-access
	// handle. Share that access so simultaneous first launches can read it.
	handle, err := windows.CreateFile(name, windows.GENERIC_READ,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE,
		nil, windows.OPEN_EXISTING, windows.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		return nil, &os.PathError{Op: "open", Path: path, Err: err}
	}
	return os.NewFile(uintptr(handle), path), nil
}

func publishReceiverIdentity(source, destination string) error {
	from, err := windows.UTF16PtrFromString(source)
	if err != nil {
		return err
	}
	to, err := windows.UTF16PtrFromString(destination)
	if err != nil {
		return err
	}
	// Do not replace an identity won by another process. Readers must never
	// observe a partially written address or two different successful IDs.
	return windows.MoveFileEx(from, to, windows.MOVEFILE_WRITE_THROUGH)
}
