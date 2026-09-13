package main

import (
	"runtime/debug"
	"strings"
)

const developmentVersion = "Development"

// buildInfoVersion is the cross-platform fallback used when the Win32
// file-version resource can't be read (e.g. running via `go run`/`wails
// dev`, where the binary has no embedded VERSIONINFO yet).
func buildInfoVersion() string {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return developmentVersion
	}

	version := strings.TrimPrefix(strings.TrimSpace(info.Main.Version), "v")
	if version == "" || version == "(devel)" {
		return developmentVersion
	}
	return version
}
