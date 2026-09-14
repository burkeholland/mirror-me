//go:build !windows || !amd64 || native_contracts

package main

import (
	"strings"
	"testing"
)

func TestUnavailableNativeBuildDoesNotCreateAnotherReceiver(t *testing.T) {
	engine, err := NewEngine(nil)
	if engine != nil || err == nil || !strings.Contains(err.Error(), "Windows x64 production build") {
		t.Fatalf("unavailable native host did not fail explicitly: %v, %v", engine, err)
	}
	receiver, err := createNativeReceiver(workerOptions{}, func(int, string) {})
	if receiver != nil || err == nil {
		t.Fatalf("native stub returned a working receiver: %v, %v", receiver, err)
	}
}
