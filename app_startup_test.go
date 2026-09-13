package main

import "testing"

func TestStartupLaunch(t *testing.T) {
	for _, tc := range []struct {
		name string
		args []string
		want bool
	}{
		{"normal launch", nil, false},
		{"Windows startup", []string{"--startup"}, true},
		{"legacy startup flag", []string{"-startup"}, true},
		{"second-instance arguments", []string{"MirrorMe.exe", "--startup"}, true},
		{"unrelated argument", []string{"--help"}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := isStartupLaunch(tc.args); got != tc.want {
				t.Fatalf("isStartupLaunch() = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestReceiverLaunchPolicy(t *testing.T) {
	for _, tc := range []struct {
		name      string
		firstRun  bool
		automatic bool
		want      bool
	}{
		{"wait for onboarding", true, true, false},
		{"automatic receiving after setup", false, true, true},
		{"respect manual receiving", false, false, false},
		{"manual receiving on first run", true, false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			config := Config{FirstRun: tc.firstRun, AutoStartMirroring: tc.automatic}
			if got := shouldStartReceiverOnLaunch(config); got != tc.want {
				t.Fatalf("shouldStartReceiverOnLaunch() = %v, want %v", got, tc.want)
			}
		})
	}
}
