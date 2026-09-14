package main

import "testing"

func TestTrayStatusLabelsAndScreenAvailability(t *testing.T) {
	for _, tc := range []struct {
		status  EngineStatus
		device  string
		tooltip string
		action  string
		show    bool
	}{
		{StatusStopped, "", "MirrorMe - stopped", "Start receiving", false},
		{StatusStarting, "", "MirrorMe - starting…", "Stop receiving", false},
		{StatusNeedsSetup, "", "MirrorMe - setup required", "Stop receiving", false},
		{StatusAdvertising, "", "MirrorMe - ready for a device", "Stop receiving", false},
		{StatusConnecting, "", "MirrorMe - connecting…", "Stop receiving", false},
		{StatusMirroring, "", "MirrorMe - mirroring", "Stop mirroring", true},
		{StatusMirroring, "Known iPhone", "MirrorMe - mirroring Known iPhone", "Stop mirroring", true},
		{StatusPaused, "", "MirrorMe - paused", "Stop mirroring", false},
		{StatusPaused, "Known iPhone", "MirrorMe - paused", "Stop mirroring", false},
		{StatusError, "", "MirrorMe - error", "Start receiving", false},
	} {
		t.Run(string(tc.status)+tc.device, func(t *testing.T) {
			engine, _ := newTestEngine()
			engine.status, engine.deviceName = tc.status, tc.device
			app := &App{engine: engine}
			got := app.trayMenuState()
			if got.Tooltip != tc.tooltip || got.MirroringLabel != tc.action || got.ShowMirroredScreenEnabled != tc.show {
				t.Fatalf("unexpected tray state: %+v", got)
			}
		})
	}
}

func TestTrayCanStopPausedMirroring(t *testing.T) {
	engine, _ := newTestEngine()
	engine.builtin = true
	engine.status = StatusPaused
	app := &App{engine: engine}
	if app.ShowMirroredScreen() {
		t.Fatal("paused mirroring offered a video window")
	}
	app.toggleMirroringFromTray()
	if engine.IsRunning() || app.GetStatus().Status != StatusStopped {
		t.Fatal("the tray did not stop a paused session")
	}
}
