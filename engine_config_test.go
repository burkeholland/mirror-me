package main

import "testing"

func TestAppPreferencesDoNotRestartReceiver(t *testing.T) {
	current := DefaultConfig()
	next := current
	next.Theme = "dark"
	next.LaunchAtStartup = true
	next.AlwaysOnTop = true
	next.StartMinimized = true
	next.AutoStartMirroring = false
	next.FirstRun = false
	next.VerboseLogging = true
	next.PinCode = "1234"
	if configAffectsReceiver(current, next) {
		t.Fatal("app-only preferences or a disabled pairing code would restart the receiver")
	}
}

func TestReceiverSettingsRestartReceiver(t *testing.T) {
	for name, change := range map[string]func(*Config){
		"name":       func(c *Config) { c.DeviceName += " changed" },
		"resolution": func(c *Config) { c.Resolution = Resolution720 },
		"frame rate": func(c *Config) { c.MaxFPS = 30 },
		"audio":      func(c *Config) { c.AudioEnabled = !c.AudioEnabled },
		"decoder":    func(c *Config) { c.HardwareDecode = !c.HardwareDecode },
		"codec":      func(c *Config) { c.H265 = !c.H265 },
		"connection": func(c *Config) { c.PreferNewestConnection = !c.PreferNewestConnection },
		"timeout":    func(c *Config) { c.IdleTimeoutSeconds++ },
		"pairing":    func(c *Config) { c.RequirePin = true; c.PinCode = "1234" },
	} {
		t.Run(name, func(t *testing.T) {
			current := DefaultConfig()
			next := current
			change(&next)
			if !configAffectsReceiver(current, next) {
				t.Fatal("receiver setting change did not require restart")
			}
		})
	}
	current := DefaultConfig()
	current.RequirePin, current.PinCode = true, "1234"
	next := current
	next.PinCode = "5678"
	if !configAffectsReceiver(current, next) {
		t.Fatal("changing an active pairing code did not require restart")
	}
}
