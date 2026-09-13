//go:build windows

package main

import (
	"errors"
	"fmt"
	"os"
	"strings"

	"golang.org/x/sys/windows/registry"
)

// runKeyPath is the standard per-user autostart location; writing here
// requires no elevation and only affects the current Windows account.
const runKeyPath = `Software\Microsoft\Windows\CurrentVersion\Run`
const runKeyValueName = "MirrorMe"

// setLaunchAtStartup adds or removes MirrorMe's own executable from the
// current user's HKCU Run key. This only ever points at MirrorMe.exe itself
// (never the bundled engine, which MirrorMe starts on its own).
func setLaunchAtStartup(enabled bool) error {
	key, _, err := registry.CreateKey(registry.CURRENT_USER, runKeyPath, registry.SET_VALUE)
	if err != nil {
		return fmt.Errorf("open startup registration: %w", err)
	}
	defer key.Close()

	if !enabled {
		if err := key.DeleteValue(runKeyValueName); err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("remove startup registration: %w", err)
		}
		return nil
	}

	exePath, err := os.Executable()
	if err != nil {
		return fmt.Errorf("read executable path: %w", err)
	}
	// Launch minimized-to-tray on auto-start, since a login-time popup
	// window would be an unwelcome surprise.
	command := fmt.Sprintf(`"%s" --startup`, strings.Trim(exePath, `"`))
	if err := key.SetStringValue(runKeyValueName, command); err != nil {
		return fmt.Errorf("write startup registration: %w", err)
	}
	return nil
}

// isLaunchAtStartupSet reports whether the Run key currently points at this
// app, used to reconcile the persisted setting with actual registry state
// (e.g. if it was removed externally, or the exe moved).
func isLaunchAtStartupSet() bool {
	key, err := registry.OpenKey(registry.CURRENT_USER, runKeyPath, registry.QUERY_VALUE)
	if err != nil {
		return false
	}
	defer key.Close()

	value, _, err := key.GetStringValue(runKeyValueName)
	return err == nil && value != ""
}
