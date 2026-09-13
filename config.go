package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// Resolution presets that map to the engine's "-s WxH" flag. "auto" omits
// the flag entirely and lets the engine negotiate the client's preferred
// resolution, which is the safest default for compatibility.
const (
	ResolutionAuto = "auto"
	Resolution720  = "1280x720"
	Resolution1080 = "1920x1080"
	Resolution4K   = "3840x2160"
)

// Config is MirrorMe's persisted user configuration. It is intentionally a
// flat, JSON-serialisable struct so it can be safely round-tripped through
// disk and normalised without surprises.
type Config struct {
	// Identity
	DeviceName string `json:"deviceName"`

	// Streaming quality
	Resolution     string `json:"resolution"`
	MaxFPS         int    `json:"maxFps"`
	AudioEnabled   bool   `json:"audioEnabled"`
	HardwareDecode bool   `json:"hardwareDecode"`
	H265           bool   `json:"h265"`

	// Connection behaviour
	PreferNewestConnection bool `json:"preferNewestConnection"`
	IdleTimeoutSeconds      int  `json:"idleTimeoutSeconds"`

	// Security
	RequirePin bool   `json:"requirePin"`
	PinCode    string `json:"pinCode"`

	// App behaviour
	LaunchAtStartup     bool   `json:"launchAtStartup"`
	StartMinimized      bool   `json:"startMinimized"`
	AutoStartMirroring  bool   `json:"autoStartMirroring"`
	AlwaysOnTop         bool   `json:"alwaysOnTop"`
	Theme               string `json:"theme"`
	FirstRun            bool   `json:"firstRun"`

	// Transient, never persisted: surfaced to the UI when the settings
	// file could not be loaded so the user knows defaults were applied.
	// ConfigStore.Save always clears this before writing to disk.
	LoadError string `json:"loadError,omitempty"`
}

// Clone returns a deep copy. Config has no reference types today, but Clone
// exists so callers never have to reason about aliasing as the struct grows.
func (c Config) Clone() Config {
	return c
}

// DefaultConfig returns the out-of-the-box configuration for a fresh install.
func DefaultConfig() Config {
	name, err := os.Hostname()
	if err != nil || name == "" {
		name = "MirrorMe"
	}
	return Config{
		DeviceName:              name,
		Resolution:              ResolutionAuto,
		MaxFPS:                  0,
		AudioEnabled:            true,
		HardwareDecode:          true,
		H265:                    false,
		PreferNewestConnection:  true,
		IdleTimeoutSeconds:      15,
		RequirePin:              false,
		PinCode:                 "",
		LaunchAtStartup:         false,
		StartMinimized:          false,
		AutoStartMirroring:      true,
		AlwaysOnTop:             false,
		Theme:                   "system",
		FirstRun:                true,
	}
}

// ConfigStore persists Config as JSON under the user's roaming AppData
// directory, matching the convention used by resize-me.
type ConfigStore struct {
	path string
}

// NewConfigStore builds a store pointed at %APPDATA%\MirrorMe\settings.json.
func NewConfigStore() *ConfigStore {
	dir, err := os.UserConfigDir()
	if err != nil || dir == "" {
		dir = "."
	}
	return &ConfigStore{path: filepath.Join(dir, "MirrorMe", "settings.json")}
}

// Path returns the on-disk location of the settings file.
func (s *ConfigStore) Path() string {
	return s.path
}

// Load reads settings from disk, normalising the result against defaults.
// If the file does not exist, defaults are returned with no error (first
// run). If the file exists but is corrupt/invalid, defaults are returned
// along with an error describing what went wrong so the caller can surface
// it to the user without ever crashing the app on bad state.
func (s *ConfigStore) Load() (Config, error) {
	fallback := DefaultConfig()

	data, err := os.ReadFile(s.path)
	if err != nil {
		if os.IsNotExist(err) {
			return fallback, nil
		}
		return fallback, fmt.Errorf("read settings: %w", err)
	}

	var loaded Config
	if err := json.Unmarshal(data, &loaded); err != nil {
		return fallback, fmt.Errorf("parse settings: %w", err)
	}

	normalized, err := NormalizeConfig(loaded, fallback)
	if err != nil {
		return fallback, fmt.Errorf("normalize settings: %w", err)
	}
	return normalized, nil
}

// Save writes settings to disk atomically: it writes to a temp file in the
// same directory, then renames over the destination. This avoids ever
// leaving a truncated/corrupt settings file behind if the process is
// killed mid-write.
func (s *ConfigStore) Save(config Config) error {
	dir := filepath.Dir(s.path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("create settings directory: %w", err)
	}

	// LoadError is a transient, UI-only signal and must never be persisted.
	config.LoadError = ""

	data, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return fmt.Errorf("encode settings: %w", err)
	}

	tmp, err := os.CreateTemp(dir, "settings-*.json.tmp")
	if err != nil {
		return fmt.Errorf("create temp settings file: %w", err)
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath) // no-op once the rename below succeeds

	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return fmt.Errorf("write temp settings file: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close temp settings file: %w", err)
	}

	if err := os.Rename(tmpPath, s.path); err != nil {
		return fmt.Errorf("replace settings file: %w", err)
	}
	return nil
}
