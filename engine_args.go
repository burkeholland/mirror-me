package main

import (
	"strconv"
)

// buildEngineArgs passes settings directly to the background receiver.
// Disable external uxplayrc files so another installation's preferences
// cannot override MirrorMe or silently change how it starts.
//
// "-d 1" is always included: it enables the engine's debug-level log lines
// (including "Open connections: N", which is how the Engine supervisor
// detects connect/disconnect) while suppressing the much noisier per-packet
// debug dump ("1" = "suppress packet data in debug output", per -d's own
// -help text).
func buildEngineArgs(c Config) []string {
	args := make([]string, 0, 16)

	args = append(args, "-rc", "NUL", "-n", c.DeviceName, "-nh")
	args = append(args, "-d", "1")

	if c.Resolution != "" && c.Resolution != ResolutionAuto {
		args = append(args, "-s", c.Resolution)
	}
	if c.MaxFPS > 0 {
		args = append(args, "-fps", strconv.Itoa(c.MaxFPS))
	}
	if !c.AudioEnabled {
		args = append(args, "-as", "0")
	}
	if !c.HardwareDecode {
		args = append(args, "-avdec")
	}
	if c.H265 {
		args = append(args, "-h265")
	}
	if c.PreferNewestConnection {
		args = append(args, "-nohold")
	}
	if c.RequirePin && len(c.PinCode) == 4 {
		args = append(args, "-pin"+c.PinCode)
	}

	// "-reset 0" means "never reset on missed feedback", which is a valid
	// and meaningful choice, so it must not be dropped like a zero-value
	// would be with omitempty-style handling.
	args = append(args, "-reset", strconv.Itoa(c.IdleTimeoutSeconds))

	// Let GStreamer choose an available video sink for this PC.

	return args
}

// configAffectsEngineArgs reports whether two configs would produce
// different CLI arguments for the engine. Callers use this to avoid
// restarting a running engine for settings changes that don't actually
// affect it (e.g. theme, launch-at-startup, always-on-top). Comparing the
// generated argument lists directly (rather than hand-picking fields) keeps
// this in lockstep with buildEngineArgs as it evolves.
func configAffectsEngineArgs(a, b Config) bool {
	argsA := buildEngineArgs(a)
	argsB := buildEngineArgs(b)
	if len(argsA) != len(argsB) {
		return true
	}
	for i := range argsA {
		if argsA[i] != argsB[i] {
			return true
		}
	}
	return false
}
