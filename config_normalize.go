package main

import "strings"

// validResolutions is the set of resolution presets the Settings UI can
// produce. Anything else found on disk is repaired back to auto.
var validResolutions = map[string]bool{
	ResolutionAuto: true,
	Resolution720:  true,
	Resolution1080: true,
	Resolution4K:   true,
}

var validThemes = map[string]bool{
	"system": true,
	"light":  true,
	"dark":   true,
}

const (
	minFPS = 0 // 0 means "no cap"
	maxFPS = 120

	minIdleTimeoutSeconds = 0 // 0 means "never reset"
	maxIdleTimeoutSeconds = 3600
)

// NormalizeConfig repairs a config loaded from disk (or submitted from the
// UI) against a known-good fallback. It never returns an error today, but
// keeps the (Config, error) shape so callers don't need to change if a
// future field needs to reject rather than repair. Every field is clamped
// or replaced with the fallback's value rather than left invalid, so a
// corrupt or hand-edited settings.json can never crash or wedge the app.
func NormalizeConfig(next Config, fallback Config) (Config, error) {
	normalized := next

	normalized.DeviceName = normalizeDeviceName(next.DeviceName, fallback.DeviceName)

	if !validResolutions[normalized.Resolution] {
		normalized.Resolution = ResolutionAuto
	}

	normalized.MaxFPS = clampInt(normalized.MaxFPS, minFPS, maxFPS)
	normalized.IdleTimeoutSeconds = clampInt(normalized.IdleTimeoutSeconds, minIdleTimeoutSeconds, maxIdleTimeoutSeconds)

	normalized.PinCode = normalizePinCode(normalized.PinCode)
	if normalized.RequirePin && normalized.PinCode == "" {
		normalized.PinCode = generatePinCode()
	}
	if !normalized.RequirePin {
		normalized.PinCode = ""
	}

	if !validThemes[strings.ToLower(normalized.Theme)] {
		normalized.Theme = "system"
	} else {
		normalized.Theme = strings.ToLower(normalized.Theme)
	}

	normalized.LoadError = ""

	return normalized, nil
}

func normalizeDeviceName(name string, fallback string) string {
	trimmed := strings.TrimSpace(name)
	if trimmed == "" {
		trimmed = strings.TrimSpace(fallback)
	}
	if trimmed == "" {
		trimmed = "MirrorMe"
	}
	// The engine's "-n" value is a single CLI token; strip characters that
	// would corrupt the generated arguments file or an mDNS TXT record.
	trimmed = strings.Map(func(r rune) rune {
		switch r {
		case '\n', '\r', '\t', '"':
			return -1
		default:
			return r
		}
	}, trimmed)
	if len(trimmed) > 64 {
		trimmed = trimmed[:64]
	}
	if trimmed == "" {
		trimmed = "MirrorMe"
	}
	return trimmed
}

func normalizePinCode(pin string) string {
	pin = strings.TrimSpace(pin)
	if len(pin) != 4 {
		return ""
	}
	for _, r := range pin {
		if r < '0' || r > '9' {
			return ""
		}
	}
	return pin
}

func clampInt(value, min, max int) int {
	if value < min {
		return min
	}
	if value > max {
		return max
	}
	return value
}
