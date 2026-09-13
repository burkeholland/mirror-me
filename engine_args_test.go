package main

import (
	"testing"
)

func containsSeq(args []string, seq ...string) bool {
	if len(seq) == 0 || len(seq) > len(args) {
		return false
	}
	for i := 0; i+len(seq) <= len(args); i++ {
		match := true
		for j, s := range seq {
			if args[i+j] != s {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}

func TestBuildEngineArgsIncludesNameAndDebugFlag(t *testing.T) {
	c := DefaultConfig()
	c.DeviceName = "Office PC"
	args := buildEngineArgs(c)

	if !containsSeq(args, "-n", "Office PC") {
		t.Errorf("expected -n \"Office PC\" in args: %v", args)
	}
	if !containsSeq(args, "-nh") {
		t.Errorf("expected -nh in args: %v", args)
	}
	if !containsSeq(args, "-d", "1") {
		t.Errorf("expected -d 1 in args: %v", args)
	}
}

func TestBuildEngineArgsResolutionAutoOmitsFlag(t *testing.T) {
	c := DefaultConfig()
	c.Resolution = ResolutionAuto
	args := buildEngineArgs(c)
	for _, a := range args {
		if a == "-s" {
			t.Errorf("did not expect -s flag when resolution is auto: %v", args)
		}
	}
}

func TestBuildEngineArgsResolutionSetsFlag(t *testing.T) {
	c := DefaultConfig()
	c.Resolution = Resolution1080
	args := buildEngineArgs(c)
	if !containsSeq(args, "-s", Resolution1080) {
		t.Errorf("expected -s %s in args: %v", Resolution1080, args)
	}
}

func TestBuildEngineArgsAudioDisabled(t *testing.T) {
	c := DefaultConfig()
	c.AudioEnabled = false
	args := buildEngineArgs(c)
	if !containsSeq(args, "-as", "0") {
		t.Errorf("expected -as 0 in args: %v", args)
	}
}

func TestBuildEngineArgsSoftwareDecode(t *testing.T) {
	c := DefaultConfig()
	c.HardwareDecode = false
	args := buildEngineArgs(c)
	if !containsSeq(args, "-avdec") {
		t.Errorf("expected -avdec in args: %v", args)
	}
}

func TestBuildEngineArgsPinAppendsCodeToFlag(t *testing.T) {
	c := DefaultConfig()
	c.RequirePin = true
	c.PinCode = "4821"
	args := buildEngineArgs(c)
	if !containsSeq(args, "-pin4821") {
		t.Errorf("expected -pin4821 as a single token in args: %v", args)
	}
}

func TestBuildEngineArgsIdleTimeoutZeroIsPreserved(t *testing.T) {
	c := DefaultConfig()
	c.IdleTimeoutSeconds = 0
	args := buildEngineArgs(c)
	if !containsSeq(args, "-reset", "0") {
		t.Errorf("expected -reset 0 to be preserved (not dropped): %v", args)
	}
}

func TestBuildEngineArgsNeverEmitsVideoSinkFlag(t *testing.T) {
	// The receiver lets GStreamer select an available video sink.
	c := DefaultConfig()
	args := buildEngineArgs(c)
	for _, a := range args {
		if a == "-vs" {
			t.Errorf("did not expect -vs in generated args: %v", args)
		}
	}
}

func TestBuildEngineArgsPreservesNamesAsOneArgument(t *testing.T) {
	for _, name := range []string{"Living Room PC", `Office "PC"\`, "Café Übermensch"} {
		c := DefaultConfig()
		c.DeviceName = name
		if args := buildEngineArgs(c); !containsSeq(args, "-n", name) {
			t.Errorf("device name was changed or split: %q", args)
		}
	}
}

func TestBuildEngineArgsDisablesExternalConfiguration(t *testing.T) {
	if args := buildEngineArgs(DefaultConfig()); !containsSeq(args, "-rc", "NUL") {
		t.Errorf("external uxplayrc was not disabled: %q", args)
	}
}

func TestConfigAffectsEngineArgsFalseForIdenticalEngineRelevantFields(t *testing.T) {
	a := DefaultConfig()
	b := DefaultConfig()
	// UI-only fields differing should NOT be treated as engine-relevant.
	b.Theme = "dark"
	b.LaunchAtStartup = true
	b.AlwaysOnTop = true
	b.StartMinimized = true
	b.AutoStartMirroring = false
	b.FirstRun = false

	if configAffectsEngineArgs(a, b) {
		t.Errorf("expected UI-only field changes to not affect engine args")
	}
}

func TestConfigAffectsEngineArgsTrueForDeviceNameChange(t *testing.T) {
	a := DefaultConfig()
	b := DefaultConfig()
	b.DeviceName = "Different Name"

	if !configAffectsEngineArgs(a, b) {
		t.Errorf("expected device name change to affect engine args")
	}
}

func TestConfigAffectsEngineArgsTrueForResolutionChange(t *testing.T) {
	a := DefaultConfig()
	b := DefaultConfig()
	b.Resolution = Resolution1080

	if !configAffectsEngineArgs(a, b) {
		t.Errorf("expected resolution change to affect engine args")
	}
}

func TestConfigAffectsEngineArgsTrueForPinChange(t *testing.T) {
	a := DefaultConfig()
	a.RequirePin = true
	a.PinCode = "1234"
	b := a
	b.PinCode = "5678"

	if !configAffectsEngineArgs(a, b) {
		t.Errorf("expected pin code change to affect engine args")
	}
}
