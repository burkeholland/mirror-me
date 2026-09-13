package main

import "testing"

func TestNormalizeConfigRepairsInvalidResolution(t *testing.T) {
	fallback := DefaultConfig()
	next := fallback
	next.Resolution = "9999x9999"

	got, err := NormalizeConfig(next, fallback)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.Resolution != ResolutionAuto {
		t.Errorf("Resolution = %q, want %q", got.Resolution, ResolutionAuto)
	}
}

func TestNormalizeConfigClampsFPS(t *testing.T) {
	fallback := DefaultConfig()

	cases := []struct {
		name  string
		input int
		want  int
	}{
		{"negative", -30, 0},
		{"way too high", 10000, maxFPS},
		{"in range", 60, 60},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			next := fallback
			next.MaxFPS = tc.input
			got, err := NormalizeConfig(next, fallback)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got.MaxFPS != tc.want {
				t.Errorf("MaxFPS = %d, want %d", got.MaxFPS, tc.want)
			}
		})
	}
}

func TestNormalizeConfigEmptyDeviceNameFallsBack(t *testing.T) {
	fallback := DefaultConfig()
	fallback.DeviceName = "Fallback PC"
	next := fallback
	next.DeviceName = "   "

	got, err := NormalizeConfig(next, fallback)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.DeviceName != "Fallback PC" {
		t.Errorf("DeviceName = %q, want %q", got.DeviceName, "Fallback PC")
	}
}

func TestNormalizeConfigStripsControlCharactersFromDeviceName(t *testing.T) {
	fallback := DefaultConfig()
	next := fallback
	next.DeviceName = "Living\nRoom\t\"PC\""

	got, err := NormalizeConfig(next, fallback)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.DeviceName != "LivingRoomPC" {
		t.Errorf("DeviceName = %q, want %q", got.DeviceName, "LivingRoomPC")
	}
}

func TestNormalizeConfigRequirePinGeneratesCode(t *testing.T) {
	fallback := DefaultConfig()
	next := fallback
	next.RequirePin = true
	next.PinCode = ""

	got, err := NormalizeConfig(next, fallback)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got.PinCode) != 4 {
		t.Errorf("expected a 4-digit PIN to be generated, got %q", got.PinCode)
	}
}

func TestNormalizeConfigDisablingPinClearsCode(t *testing.T) {
	fallback := DefaultConfig()
	next := fallback
	next.RequirePin = false
	next.PinCode = "1234"

	got, err := NormalizeConfig(next, fallback)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.PinCode != "" {
		t.Errorf("expected PinCode to be cleared when RequirePin is false, got %q", got.PinCode)
	}
}

func TestNormalizeConfigRejectsNonNumericPin(t *testing.T) {
	fallback := DefaultConfig()
	next := fallback
	next.RequirePin = true
	next.PinCode = "abcd"

	got, err := NormalizeConfig(next, fallback)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.PinCode == "abcd" {
		t.Errorf("non-numeric PIN should have been replaced, got %q", got.PinCode)
	}
	if len(got.PinCode) != 4 {
		t.Errorf("expected a regenerated 4-digit PIN, got %q", got.PinCode)
	}
}

func TestNormalizeConfigInvalidThemeFallsBackToSystem(t *testing.T) {
	fallback := DefaultConfig()
	next := fallback
	next.Theme = "solarized"

	got, err := NormalizeConfig(next, fallback)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.Theme != "system" {
		t.Errorf("Theme = %q, want %q", got.Theme, "system")
	}
}

func TestNormalizeConfigThemeIsCaseInsensitive(t *testing.T) {
	fallback := DefaultConfig()
	next := fallback
	next.Theme = "DARK"

	got, err := NormalizeConfig(next, fallback)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.Theme != "dark" {
		t.Errorf("Theme = %q, want %q", got.Theme, "dark")
	}
}
