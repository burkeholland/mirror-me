package main

import (
	"testing"
	"time"
)

func TestParseLogLineIgnoresIrrelevantLines(t *testing.T) {
	lines := []string{
		"",
		"2024-06-01T12:00:00.000 [DEBUG] gst pipeline state change",
		"some random noise that matches nothing",
		"video_reset: type = on_video_play",
		"Begin streaming to GStreamer video pipeline",
		"pipeline state is PLAYING",
	}
	for _, line := range lines {
		if _, ok := parseLogLine(line); ok {
			t.Errorf("parseLogLine(%q) matched unexpectedly", line)
		}
	}
}

func TestParseLogLineEngineReady(t *testing.T) {
	line := "MIRRORME_RECEIVER_READY port=7000"
	fact, ok := parseLogLine(line)
	if !ok {
		t.Fatalf("expected a match")
	}
	if fact.kind != factEngineReady {
		t.Errorf("kind = %v, want factEngineReady", fact.kind)
	}
}

func TestParseLogLineDoesNotTreatBannerAsReady(t *testing.T) {
	line := "UxPlay 1.71: An Open-Source AirPlay mirroring and audio-streaming server."
	if _, ok := parseLogLine(line); ok {
		t.Fatal("a startup banner does not prove service registration succeeded")
	}
}

func TestExtractLogTimestamp(t *testing.T) {
	timestamp, ok := extractLogTimestamp("2024-06-01T12:00:01.123 [INFO] message")
	if !ok {
		t.Fatal("expected timestamp to be extracted")
	}
	wantTime := time.Date(2024, 6, 1, 12, 0, 1, 123000000, time.Local)
	if !timestamp.Equal(wantTime) {
		t.Errorf("timestamp = %v, want %v", timestamp, wantTime)
	}
}

func TestParseLogLineConnectionRequest(t *testing.T) {
	line := `2024-06-01T12:00:02.000 [INFO] connection request from John's iPhone (iPhone14,5) with deviceID = AA:BB:CC:DD:EE:FF`
	fact, ok := parseLogLine(line)
	if !ok {
		t.Fatalf("expected a match")
	}
	if fact.kind != factConnectionRequest {
		t.Errorf("kind = %v, want factConnectionRequest", fact.kind)
	}
	if fact.deviceName != "John's iPhone" {
		t.Errorf("deviceName = %q, want %q", fact.deviceName, "John's iPhone")
	}
	if fact.deviceModel != "iPhone14,5" {
		t.Errorf("deviceModel = %q, want %q", fact.deviceModel, "iPhone14,5")
	}
}

func TestParseLogLineOpenConnections(t *testing.T) {
	cases := []struct {
		line string
		want int
	}{
		{"2024-06-01T12:00:03.000 [DEBUG] Open connections: 1", 1},
		{"2024-06-01T12:00:04.000 [DEBUG] Open connections: 0", 0},
		{"2024-06-01T12:00:04.000 [DEBUG] Open connections: 3", 3},
	}
	for _, tc := range cases {
		fact, ok := parseLogLine(tc.line)
		if !ok {
			t.Fatalf("expected a match for %q", tc.line)
		}
		if fact.kind != factOpenConnections {
			t.Errorf("kind = %v, want factOpenConnections", fact.kind)
		}
		if fact.openConnections != tc.want {
			t.Errorf("openConnections = %d, want %d", fact.openConnections, tc.want)
		}
	}
}

func TestParseLogLineStreaming(t *testing.T) {
	line := "MIRRORME_STREAMING"
	fact, ok := parseLogLine(line)
	if !ok {
		t.Fatalf("expected a match")
	}
	if fact.kind != factStreaming {
		t.Errorf("kind = %v, want factStreaming", fact.kind)
	}
}

func TestParseVideoLifecycle(t *testing.T) {
	for line, kind := range map[string]logFactKind{
		"MIRRORME_VIDEO_RECEIVED": factVideoReceived,
		"MIRRORME_VIDEO_STOPPED":  factVideoStopped,
	} {
		fact, ok := parseLogLine(line)
		if !ok || fact.kind != kind {
			t.Fatalf("%q: %+v, matched=%v", line, fact, ok)
		}
	}
	fact, ok := parseLogLine("MIRRORME_RECEIVER_ERROR: Video output failed: decoder error")
	if !ok || fact.kind != factFatalError || fact.message != "Video output failed: decoder error" {
		t.Fatalf("video error was not actionable: %+v", fact)
	}
}

func TestParseLogLineWarningLostConnection(t *testing.T) {
	line := `2024-06-01T12:00:06.000 [INFO] *** ERROR lost connection with client (network problem?)`
	fact, ok := parseLogLine(line)
	if !ok {
		t.Fatalf("expected a match")
	}
	if fact.kind != factWarning {
		t.Errorf("kind = %v, want factWarning", fact.kind)
	}
}

func TestParseProductionVideoErrors(t *testing.T) {
	for _, prefix := range []string{"", "*** ERROR: "} {
		line := prefix + "MIRRORME_RECEIVER_ERROR: Video output failed: decoder error"
		fact, ok := parseLogLine(line)
		if !ok || fact.kind != factFatalError || fact.message != "Video output failed: decoder error" {
			t.Fatalf("production error prefix hid the failure: %q => %+v", line, fact)
		}
	}
	if _, ok := parseLogLine("a device named *** ERROR: MIRRORME_RECEIVER_ERROR: example"); ok {
		t.Fatal("an embedded error-looking name is not a native protocol marker")
	}
}

func TestParseReceiverWarningPreservesItsExplanation(t *testing.T) {
	fact, ok := parseLogLine("*** WARNING: MIRRORME_RECEIVER_WARNING: Video window icon unavailable")
	if !ok || fact.kind != factReceiverNotice || fact.message != "Video window icon unavailable" {
		t.Fatalf("receiver warning was lost or mistaken for a network error: %+v", fact)
	}
}

func TestWarningAndErrorPrefixesCannotClaimVideoOrReadiness(t *testing.T) {
	for _, prefix := range []string{"*** ERROR: ", "*** WARNING: "} {
		for _, marker := range []string{
			"MIRRORME_RECEIVER_READY port=7000", "MIRRORME_STREAMING",
			"MIRRORME_VIDEO_RECEIVED", "MIRRORME_VIDEO_STOPPED",
		} {
			if fact, ok := parseLogLine(prefix + marker); ok {
				t.Fatalf("a prefixed log was mistaken for a lifecycle marker: %+v", fact)
			}
		}
	}
}

func TestParseLogLineFatalDNSSDErrors(t *testing.T) {
	lines := []string{
		"MIRRORME_RECEIVER_ERROR: receiver initialization failed",
		`2024-06-01T12:00:07.000 [ERROR] dnssd_register_raop failed with error code -1`,
		`2024-06-01T12:00:07.000 [ERROR] dnssd_register_airplay failed with error code -1`,
		`2024-06-01T12:00:07.000 [ERROR] Could not initialize dnssd library!: error -1`,
		`2024-06-01T12:00:07.000 [ERROR] No DNS-SD Server found (DNSServiceRegister call returned kDNSServiceErr_Unknown)`,
	}
	for _, line := range lines {
		fact, ok := parseLogLine(line)
		if !ok {
			t.Fatalf("expected a match for %q", line)
		}
		if fact.kind != factFatalError {
			t.Errorf("kind for %q = %v, want factFatalError", line, fact.kind)
		}
	}
}

func TestParseLogLineWithoutTimestampStillParses(t *testing.T) {
	line := "Open connections: 1"
	fact, ok := parseLogLine(line)
	if !ok {
		t.Fatalf("expected a match")
	}
	if fact.hasTimestamp {
		t.Errorf("did not expect a timestamp to be found")
	}
	if fact.openConnections != 1 {
		t.Errorf("openConnections = %d, want 1", fact.openConnections)
	}
}
