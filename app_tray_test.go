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

func TestTrayDesktopStopIsIndependentOfReceiving(t *testing.T) {
	engine, _ := newTestEngine()
	engine.status = StatusMirroring
	sender := testDesktopSender()
	app := &App{engine: engine, sender: sender}
	for _, status := range []string{"connecting", "pairing", "streaming", "stopped", "error"} {
		sender.snapshot.Status = status
		menu := app.trayMenuState()
		active := status == "connecting" || status == "pairing" || status == "streaming"
		if menu.StopDesktopCastEnabled != active || menu.MirroringLabel != "Stop mirroring" || !menu.ShowMirroredScreenEnabled {
			t.Fatalf("casting changed receiver controls: %+v", menu)
		}
		if active && menu.Tooltip != "MirrorMe - desktop sharing active" {
			t.Fatal("tray did not indicate desktop sharing")
		}
	}
}
