package main

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

func validReceiverDeviceID(id string) bool {
	parts := strings.Split(id, ":")
	if len(parts) != 6 {
		return false
	}
	for _, part := range parts {
		if len(part) != 2 {
			return false
		}
		if _, err := hex.DecodeString(part); err != nil {
			return false
		}
	}
	return true
}

func receiverIdentity(directory string) (deviceID, keyPath string, err error) {
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return "", "", fmt.Errorf("create receiver identity directory: %w", err)
	}
	path := filepath.Join(directory, "device-id")
	read := func() (string, error) {
		file, err := openReceiverIdentity(path)
		if err != nil {
			return "", err
		}
		defer file.Close()
		content, err := io.ReadAll(io.LimitReader(file, 64))
		if err != nil {
			return "", fmt.Errorf("read receiver identity: %w", err)
		}
		id := strings.TrimSpace(string(content))
		if len(content) == 64 || !validReceiverDeviceID(id) {
			return "", errors.New("the saved receiver identity is invalid")
		}
		return id, nil
	}
	id, err := read()
	if err == nil {
		return id, filepath.Join(directory, "pairing.key"), nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return "", "", err
	}
	var address [6]byte
	if _, err := rand.Read(address[:]); err != nil {
		return "", "", fmt.Errorf("generate receiver identity: %w", err)
	}
	address[0] = (address[0] | 2) & 0xfe
	id = fmt.Sprintf("%02X:%02X:%02X:%02X:%02X:%02X",
		address[0], address[1], address[2], address[3], address[4], address[5])
	file, err := os.CreateTemp(directory, ".device-id-")
	if err != nil {
		return "", "", fmt.Errorf("save receiver identity: %w", err)
	}
	defer os.Remove(file.Name())
	_, writeErr := file.WriteString(id + "\n")
	if err := errors.Join(writeErr, file.Sync(), file.Close()); err != nil {
		return "", "", fmt.Errorf("save receiver identity: %w", err)
	}
	if err := publishReceiverIdentity(file.Name(), path); err != nil {
		if errors.Is(err, os.ErrExist) {
			existing, readErr := read()
			return existing, filepath.Join(directory, "pairing.key"), readErr
		}
		return "", "", fmt.Errorf("publish receiver identity: %w", err)
	}
	return id, filepath.Join(directory, "pairing.key"), nil
}
