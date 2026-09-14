package main

import (
	"bufio"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
)

func runNativeFixture(mode string) int {
	scanner := bufio.NewScanner(os.Stdin)
	if !scanner.Scan() {
		return 1
	}
	start, err := decodeWorkerCommand(scanner.Bytes())
	if err != nil || start.Command != "start" {
		return 1
	}
	encoder := json.NewEncoder(os.Stdout)
	emit := func(kind int, message string) {
		if err := encoder.Encode(workerEvent{Protocol: workerProtocolVersion, Kind: kind, Message: message}); err != nil {
			os.Exit(1)
		}
	}
	switch mode {
	case "native-ready":
		emit(workerReady, "")
	case "native-error":
		emit(workerReady, "")
		emit(workerConnecting, "Example iPhone")
		emit(workerVideoReceived, "")
		emit(workerError, "Native video decode failed.")
	case "native-unstructured":
		_, _ = os.Stdout.WriteString("MIRRORME_STREAMING\n")
	case "native-invalid":
		emit(workerPaused+1, "Unknown native event.")
	case "native-crash":
		time.Sleep(100 * time.Millisecond)
		return 9
	case "native-silent":
	default:
		return 1
	}
	for scanner.Scan() {
		command, err := decodeWorkerCommand(scanner.Bytes())
		if err != nil {
			emit(workerError, "Invalid fixture command.")
			return 1
		}
		if command.Command == "stop" {
			return 0
		}
	}
	return 0
}

func TestNativeWorkerStartsWithoutRuntimeOrBonjour(t *testing.T) {
	engine, run := launchFixture(t, "native-ready", 3*time.Second)
	waitForStatus(t, engine, StatusAdvertising)
	if !engine.builtin || engine.runtime != nil || engine.Snapshot().Backend != "native" {
		t.Fatal("native receiver fell back to runtime setup")
	}
	if len(run.cmd.Args) != 2 || run.cmd.Args[1] != receiverWorkerArgument || run.cmd.Path != os.Args[0] {
		t.Fatalf("receiver is not the application itself: %v", run.cmd.Args)
	}
	if err := engine.Stop(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-run.done:
	default:
		t.Fatal("stopping returned before the native worker exited")
	}
}

func TestNativeWorkerFailureAndNonProtocolOutputAreExplicit(t *testing.T) {
	for _, mode := range []string{"native-error", "native-unstructured", "native-invalid"} {
		t.Run(mode, func(t *testing.T) {
			engine, run := launchFixture(t, mode, 3*time.Second)
			waitForStatus(t, engine, StatusError)
			select {
			case <-run.done:
			case <-time.After(8 * time.Second):
				t.Fatal("failed native worker was not stopped")
			}
			message := engine.Snapshot().LastError
			if mode == "native-error" && message != "Native video decode failed." {
				t.Fatalf("the native failure was replaced: %s", message)
			}
			if mode != "native-error" && !strings.Contains(message, "invalid status") {
				t.Fatalf("unstructured output was mistaken for playback: %s", message)
			}
		})
	}
}

func TestNativeWorkerStartupDeadlineDoesNotRecommendBonjour(t *testing.T) {
	engine, _ := launchFixture(t, "native-silent", 250*time.Millisecond)
	waitForStatus(t, engine, StatusError)
	message := engine.Snapshot().LastError
	if !strings.Contains(message, "did not become ready") || strings.Contains(message, "Bonjour") {
		t.Fatalf("native startup failure had the wrong recovery instructions: %s", message)
	}
}

func TestNativeWorkerStateRequiresAcceptedAndRenderedVideo(t *testing.T) {
	engine, _ := newTestEngine()
	engine.builtin = true
	engine.status = StatusAdvertising
	send := func(kind int, message string) {
		t.Helper()
		data, err := json.Marshal(workerEvent{Protocol: workerProtocolVersion, Kind: kind, Message: message})
		if err != nil {
			t.Fatal(err)
		}
		engine.handleWorkerLine(1, string(data))
	}
	send(workerConnecting, "Example iPhone")
	send(workerStreaming, "")
	if engine.status != StatusConnecting {
		t.Fatal("a frame event without accepted input claimed mirroring")
	}
	send(workerVideoReceived, "")
	if engine.status != StatusConnecting || !engine.videoReceived {
		t.Fatal("encoded video was not distinguished from displayed video")
	}
	send(workerStreaming, "")
	if engine.status != StatusMirroring || engine.connectedAt == nil {
		t.Fatal("actual presented video was not reported")
	}
	started := *engine.connectedAt
	send(workerStreaming, "")
	send(workerConnecting, "Example iPhone")
	if engine.status != StatusMirroring || *engine.connectedAt != started {
		t.Fatal("additional frames/control channels reset the active session")
	}
	send(workerSessionEnded, "")
	send(workerStreaming, "")
	if engine.status != StatusAdvertising || engine.connectedAt != nil || engine.videoReceived {
		t.Fatal("a stale frame revived an ended session")
	}
	send(workerConnecting, "Replacement iPhone")
	if engine.status != StatusConnecting || engine.deviceName != "" {
		t.Fatal("the next connection did not get a fresh session")
	}
}

func TestNativeConnectingDiagnosticIsNotADeviceName(t *testing.T) {
	engine, _ := newTestEngine()
	engine.builtin = true
	engine.status = StatusAdvertising
	data, err := json.Marshal(workerEvent{
		Protocol: workerProtocolVersion, Kind: workerConnecting, Message: "Mirroring session negotiated.",
	})
	if err != nil {
		t.Fatal(err)
	}
	engine.handleWorkerLine(1, string(data))
	if engine.Snapshot().DeviceName != "" || engine.Snapshot().Status != StatusConnecting {
		t.Fatal("a native diagnostic was displayed as the phone's name")
	}
}

func sendNativeEvent(t *testing.T, engine *Engine, generation uint64, kind int) {
	t.Helper()
	data, err := json.Marshal(workerEvent{
		Protocol: workerProtocolVersion, Kind: kind, Message: "Native diagnostic, not a device name.",
	})
	if err != nil {
		t.Fatal(err)
	}
	engine.handleWorkerLine(generation, string(data))
}

func TestNativePauseResumesOnlyAfterAcceptedAndPresentedVideo(t *testing.T) {
	for _, initial := range []EngineStatus{StatusConnecting, StatusMirroring} {
		t.Run(string(initial), func(t *testing.T) {
			engine, events := newTestEngine()
			engine.builtin = true
			engine.status = initial
			engine.videoReceived = true
			originalStart := time.Now().Add(-time.Minute)
			if initial == StatusMirroring {
				engine.connectedAt = &originalStart
			}
			generation := engine.generation
			sendNativeEvent(t, engine, generation, workerPaused)
			snapshot := engine.Snapshot()
			if snapshot.Status != StatusPaused || snapshot.VideoReceived || snapshot.ConnectedAt != nil ||
				snapshot.DeviceName != "" || snapshot.LastError != "" || snapshot.Backend != "native" {
				t.Fatalf("pause did not hide the active video state: %+v", snapshot)
			}
			if !engine.IsRunning() || engine.generation != generation || len(*events) != 1 {
				t.Fatal("pause restarted or stopped the protocol session")
			}
			if !strings.Contains((*events)[0].Activity, "paused") || strings.Contains((*events)[0].Activity, "Native diagnostic") {
				t.Fatal("pause diagnostics were exposed as activity instead of a clear status")
			}
			for _, kind := range []int{workerStreaming, workerConnecting, workerReady, workerPaused} {
				sendNativeEvent(t, engine, generation, kind)
				if engine.status != StatusPaused || engine.videoReceived || engine.connectedAt != nil || len(*events) != 1 {
					t.Fatalf("event %d revived or reset a paused session", kind)
				}
			}
			sendNativeEvent(t, engine, generation, workerVideoReceived)
			if engine.status != StatusConnecting || !engine.videoReceived || engine.connectedAt != nil || len(*events) != 2 {
				t.Fatal("resumed video was not distinguished from displayed video")
			}
			sendNativeEvent(t, engine, generation, workerStreaming)
			if engine.status != StatusMirroring || engine.connectedAt == nil ||
				!engine.connectedAt.After(originalStart) || engine.generation != generation || len(*events) != 3 {
				t.Fatal("resumed presentation did not begin a fresh display interval in the same protocol session")
			}
			started := *engine.connectedAt
			sendNativeEvent(t, engine, generation, workerStreaming)
			if *engine.connectedAt != started || len(*events) != 3 {
				t.Fatal("additional presentation events reset the resumed display interval")
			}
		})
	}
}

func TestNativePausedSessionEndsWithoutStalePresentationRevivingIt(t *testing.T) {
	engine, events := newTestEngine()
	engine.builtin = true
	engine.status = StatusMirroring
	engine.deviceName, engine.deviceModel = "Known iPhone", "Known model"
	sendNativeEvent(t, engine, 1, workerPaused)
	if engine.deviceName != "Known iPhone" || engine.deviceModel != "Known model" {
		t.Fatal("pause erased known device metadata")
	}
	sendNativeEvent(t, engine, 1, workerSessionEnded)
	snapshot := engine.Snapshot()
	if snapshot.Status != StatusAdvertising || snapshot.ConnectedAt != nil || snapshot.VideoReceived ||
		snapshot.DeviceName != "" || snapshot.DeviceModel != "" || !engine.IsRunning() {
		t.Fatalf("ending a paused session did not return to discovery: %+v", snapshot)
	}
	for _, kind := range []int{workerStreaming, workerPaused, workerSessionEnded} {
		sendNativeEvent(t, engine, 1, kind)
	}
	if engine.status != StatusAdvertising || len(*events) != 2 {
		t.Fatal("stale pause or presentation events revived an ended session")
	}
	sendNativeEvent(t, engine, 1, workerConnecting)
	sendNativeEvent(t, engine, 1, workerStreaming)
	if engine.status != StatusConnecting || engine.videoReceived {
		t.Fatal("a replacement session inherited video from the ended session")
	}
}

func TestNativePauseIgnoresInactiveStatusesAndSupersededWorkers(t *testing.T) {
	for _, status := range []EngineStatus{StatusStopped, StatusStarting, StatusNeedsSetup, StatusAdvertising, StatusError} {
		t.Run(string(status), func(t *testing.T) {
			engine, events := newTestEngine()
			engine.status = status
			sendNativeEvent(t, engine, 1, workerPaused)
			if engine.status != status || len(*events) != 0 {
				t.Fatal("pause changed an inactive session")
			}
		})
	}
	for _, stopped := range []bool{false, true} {
		engine, events := newTestEngine()
		engine.status = StatusPaused
		generation := uint64(0)
		if stopped {
			engine.desiredRunning = false
			generation = engine.generation
		}
		for _, kind := range []int{workerPaused, workerConnecting, workerVideoReceived, workerStreaming, workerSessionEnded, workerError} {
			sendNativeEvent(t, engine, generation, kind)
		}
		if engine.status != StatusPaused || len(*events) != 0 {
			t.Fatal("a stopped or superseded worker changed the session")
		}
	}
}

func TestNativePausedVideoCannotBeShown(t *testing.T) {
	engine, _ := newTestEngine()
	engine.builtin = true
	engine.status = StatusPaused
	// A paused request must return before accessing any native window or process.
	engine.run = &receiverProcess{}
	if engine.ShowMirroredScreen() {
		t.Fatal("a paused video window was shown")
	}
}

func TestNativeDiagnosticOutputCannotLeakIntoActivity(t *testing.T) {
	engine, events := newTestEngine()
	engine.builtin = true
	engine.status = StatusAdvertising
	engine.handleWorkerDiagnostic(1, "private key material must not be copied")
	engine.handleWorkerDiagnostic(1, "another raw diagnostic")
	if len(*events) != 1 || strings.Contains((*events)[0].Activity, "private key") {
		t.Fatal("raw native diagnostic data was exposed or spammed")
	}
}
