//go:build !windows

package main

import (
	"os/exec"
)

// File-list tests exercise the portable supervisor without loading the Windows
// Wails shell. Windows contract tests use the real job-object implementation.
func configureCommand(cmd *exec.Cmd) {}

func superviseChild(pid uint32) (func(), error) { return func() {}, nil }
