//go:build !windows

package main

import "os"

func openReceiverIdentity(path string) (*os.File, error) {
	return os.Open(path)
}

func publishReceiverIdentity(source, destination string) error {
	return os.Link(source, destination)
}
