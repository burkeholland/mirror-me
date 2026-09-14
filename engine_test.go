package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestFindEngineInReturnsFirstMatchingCandidate(t *testing.T) {
	dir := t.TempDir()
	missing, present := filepath.Join(dir, "missing"), filepath.Join(dir, "present")
	if err := os.MkdirAll(present, 0o755); err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(present, receiverExecutable)
	if err := os.WriteFile(want, []byte("fake"), 0o600); err != nil {
		t.Fatal(err)
	}
	gotDir, gotExe, err := findEngineIn([]string{missing, present})
	if err != nil || gotDir != present || gotExe != want {
		t.Fatalf("findEngineIn = %q, %q, %v", gotDir, gotExe, err)
	}
}

func TestFindEngineInRejectsOldDesktopHelper(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "uxplay-windows.exe"), []byte("old GUI"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := findEngineIn([]string{dir}); err != ErrEngineMissing {
		t.Fatalf("must not fall back to the second desktop app: %v", err)
	}
}

func TestFindEngineInReturnsErrorWhenMissing(t *testing.T) {
	if _, _, err := findEngineIn([]string{t.TempDir()}); err != ErrEngineMissing {
		t.Fatalf("error = %v, want ErrEngineMissing", err)
	}
}

func newTestEngine() (*Engine, *[]EngineEvent) {
	var events []EngineEvent
	e := &Engine{
		status: StatusStopped, desiredRunning: true, generation: 1,
		onEvent: func(ev EngineEvent) { events = append(events, ev) },
	}
	return e, &events
}

func TestHandleLogLineEngineReadyTransitionsStartingToAdvertising(t *testing.T) {
	e, _ := newTestEngine()
	e.status = StatusStarting
	e.handleLogLine(1, "MIRRORME_RECEIVER_READY port=7000")
	if e.status != StatusAdvertising {
		t.Fatalf("status = %v, want advertising", e.status)
	}
}

func TestHandleLogLineBannerDoesNotReportReadiness(t *testing.T) {
	e, _ := newTestEngine()
	e.status = StatusStarting
	e.handleLogLine(1, "UxPlay 1.71: An Open-Source AirPlay mirroring and audio-streaming server.")
	if e.status != StatusStarting {
		t.Fatal("banner alone changed startup status")
	}
}

func TestHandleLogLineIgnoresSupersededProcess(t *testing.T) {
	e, events := newTestEngine()
	e.generation = 2
	e.status = StatusStopped
	for _, line := range []string{"MIRRORME_RECEIVER_READY port=7000", "Open connections: 1", "MIRRORME_STREAMING", "dnssd_register_raop failed"} {
		e.handleLogLine(1, line)
	}
	if e.status != StatusStopped || len(*events) != 0 {
		t.Fatalf("old process changed new state: %+v", e.Snapshot())
	}
}

func TestHandleLogLineConnectionRequestSetsConnecting(t *testing.T) {
	e, _ := newTestEngine()
	e.status = StatusAdvertising
	e.handleLogLine(1, `connection request from John's iPhone (iPhone14,5) with deviceID = AA:BB:CC`)
	if e.status != StatusConnecting || e.deviceName != "John's iPhone" || e.deviceModel != "iPhone14,5" {
		t.Fatalf("unexpected connecting snapshot: %+v", e.Snapshot())
	}
}

func TestHandleLogLineControlSocketDoesNotMeanMirroring(t *testing.T) {
	e, _ := newTestEngine()
	e.status = StatusConnecting
	e.handleLogLine(1, "Open connections: 1")
	if e.status != StatusConnecting || e.connectedAt != nil {
		t.Fatal("a control connection was reported as a mirrored screen")
	}
}

func TestHandleLogLineStreamingStartsTimerOnce(t *testing.T) {
	e, _ := newTestEngine()
	e.status = StatusConnecting
	e.handleLogLine(1, "Open connections: 1")
	e.handleLogLine(1, "MIRRORME_STREAMING")
	if e.status != StatusMirroring || e.connectedAt == nil {
		t.Fatalf("unexpected streaming snapshot: %+v", e.Snapshot())
	}
	first := *e.connectedAt
	e.handleLogLine(1, "Open connections: 2")
	e.handleLogLine(1, "MIRRORME_STREAMING")
	if !e.connectedAt.Equal(first) {
		t.Fatal("additional sockets or frames reset the session timer")
	}
}

func TestVideoArrivalIsNotDisplayedVideo(t *testing.T) {
	e, _ := newTestEngine()
	e.status = StatusConnecting
	e.handleLogLine(1, "video_reset: type = on_video_play")
	e.handleLogLine(1, "Begin streaming to GStreamer video pipeline")
	e.handleLogLine(1, "MIRRORME_VIDEO_RECEIVED")
	if e.status != StatusConnecting || !e.videoReceived || e.connectedAt != nil {
		t.Fatalf("encoded video was mistaken for displayed video: %+v", e.Snapshot())
	}
	e.handleLogLine(1, "MIRRORME_STREAMING")
	if e.status != StatusMirroring || e.connectedAt == nil {
		t.Fatalf("rendered video did not start the session: %+v", e.Snapshot())
	}
	e.handleLogLine(1, "MIRRORME_VIDEO_STOPPED")
	if e.status != StatusAdvertising || e.videoReceived || e.connectedAt != nil {
		t.Fatalf("closed video window left a stale session: %+v", e.Snapshot())
	}
	e.handleLogLine(1, "MIRRORME_STREAMING")
	if e.status != StatusAdvertising {
		t.Fatal("a delayed frame revived a disconnected session")
	}
}

func TestHandleLogLineOpenConnectionsFallingEdgeSetsAdvertising(t *testing.T) {
	e, events := newTestEngine()
	e.status, e.openConns, e.deviceName = StatusMirroring, 1, "John's iPhone"
	now := time.Now()
	e.connectedAt = &now
	e.handleLogLine(1, "Open connections: 0")
	if e.status != StatusAdvertising || e.connectedAt != nil || e.deviceName != "" {
		t.Fatalf("unexpected disconnected snapshot: %+v", e.Snapshot())
	}
	if len(*events) != 1 || (*events)[0].Activity != "Device disconnected." {
		t.Fatalf("missing disconnect event: %+v", *events)
	}
}

func TestHandleLogLineFatalErrorSetsErrorStatus(t *testing.T) {
	e, _ := newTestEngine()
	e.status = StatusStarting
	e.handleLogLine(1, "dnssd_register_raop failed with error code -1")
	if e.status != StatusError || e.lastError == "" || e.desiredRunning {
		t.Fatalf("unexpected error snapshot: %+v", e.Snapshot())
	}
	e.handleLogLine(1, "MIRRORME_RECEIVER_READY port=7000")
	if e.status != StatusError {
		t.Fatal("later startup output cleared a fatal error")
	}
}

func TestHandleLogLineWarningDoesNotChangeStatus(t *testing.T) {
	e, _ := newTestEngine()
	e.status = StatusMirroring
	e.handleLogLine(1, "*** ERROR lost connection with client (network problem?)")
	if e.status != StatusMirroring {
		t.Fatalf("transient warning changed status: %v", e.status)
	}
}

func TestHandleLogLineReceiverNoticeIsNonfatalAndVisible(t *testing.T) {
	e, events := newTestEngine()
	e.status = StatusMirroring
	e.handleLogLine(1, "MIRRORME_RECEIVER_WARNING: Video window icon unavailable")
	if e.status != StatusMirroring || !e.desiredRunning || e.lastError != "" {
		t.Fatalf("a window-branding warning stopped video: %+v", e.Snapshot())
	}
	if len(*events) != 1 || (*events)[0].Activity != "Video window icon unavailable" {
		t.Fatalf("the window warning was not visible in activity: %+v", *events)
	}
}

func TestHandleLogLineIrrelevantLineIsNoOp(t *testing.T) {
	e, events := newTestEngine()
	e.status = StatusAdvertising
	e.handleLogLine(1, "some unrelated gstreamer debug output")
	if e.status != StatusAdvertising || len(*events) != 0 {
		t.Fatal("irrelevant output changed status")
	}
}

func TestSnapshotDoesNotExposeMutableTimestamp(t *testing.T) {
	e, _ := newTestEngine()
	now := time.Now()
	e.connectedAt = &now
	snap := e.Snapshot()
	*snap.ConnectedAt = time.Time{}
	if e.connectedAt.IsZero() {
		t.Fatal("snapshot aliases engine timestamp")
	}
}
