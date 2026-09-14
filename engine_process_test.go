package main

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Re-executing the test binary exercises actual Windows process pipes and
// cleanup without needing an iPhone or altering the machine's Bonjour service.
func TestMain(m *testing.M) {
	if mode := os.Getenv("MIRRORME_TEST_RECEIVER"); mode != "" {
		if strings.HasPrefix(mode, "native-") {
			os.Exit(runNativeFixture(mode))
		}
		switch mode {
		case "ready":
			fmt.Println("MIRRORME_RECEIVER_READY port=7000")
		case "banner-only":
			fmt.Println("UxPlay 1.71: An Open-Source AirPlay mirroring and audio-streaming server.")
		case "fatal":
			fmt.Fprintln(os.Stderr, "MIRRORME_RECEIVER_ERROR: fixture initialization failed")
		case "video-error":
			fmt.Println("MIRRORME_RECEIVER_READY port=7000")
			fmt.Println("MIRRORME_VIDEO_RECEIVED")
			fmt.Fprintln(os.Stderr, "*** ERROR: MIRRORME_RECEIVER_ERROR: Video output failed: decoder error")
		case "crash":
			time.Sleep(100 * time.Millisecond)
			os.Exit(9)
		}
		scanner := bufio.NewScanner(os.Stdin)
		for scanner.Scan() {
			if scanner.Text() == "stop" {
				os.Exit(0)
			}
		}
		os.Exit(0)
	}
	if len(os.Args) == 2 && os.Args[1] == receiverWorkerArgument {
		os.Exit(runReceiverWorker(os.Stdin, os.Stdout, createNativeReceiver))
	}
	os.Exit(m.Run())
}

func launchFixture(t *testing.T, mode string, timeout time.Duration) (*Engine, *receiverProcess) {
	t.Helper()
	t.Setenv("MIRRORME_TEST_RECEIVER", mode)
	e := &Engine{
		exePath: os.Args[0], engineDir: t.TempDir(),
		status: StatusStopped, startupTimeout: timeout,
		checkBonjour: func() (bool, error) { return true, nil },
	}
	if strings.HasPrefix(mode, "native-") {
		e.builtin = true
		e.nativeDeviceID = "02:12:34:56:78:90"
		e.nativeKeyPath = filepath.Join(e.engineDir, "pairing.key")
	}
	t.Cleanup(func() {
		if err := e.Stop(); err != nil {
			t.Error(err)
		}
	})
	e.operations.Lock()
	err := e.launch(DefaultConfig())
	e.operations.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	e.mu.Lock()
	run := e.run
	e.mu.Unlock()
	return e, run
}

func waitForStatus(t *testing.T, e *Engine, want EngineStatus) {
	t.Helper()
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		if e.Snapshot().Status == want {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("status = %+v, want %s", e.Snapshot(), want)
}

func TestReceiverProcessReadyAndGracefulStop(t *testing.T) {
	e, run := launchFixture(t, "ready", 3*time.Second)
	waitForStatus(t, e, StatusAdvertising)
	if err := e.Stop(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-run.done:
	default:
		t.Fatal("Stop returned before the receiver exited")
	}
	if e.IsRunning() || e.Snapshot().Status != StatusStopped {
		t.Fatalf("unexpected stop state: %+v", e.Snapshot())
	}
}

func TestReceiverProcessStartupDeadline(t *testing.T) {
	e, run := launchFixture(t, "banner-only", 250*time.Millisecond)
	waitForStatus(t, e, StatusError)
	if !strings.Contains(e.Snapshot().LastError, "did not become ready") {
		t.Fatalf("missing timeout explanation: %+v", e.Snapshot())
	}
	select {
	case <-run.done:
	default:
		t.Fatal("timed-out receiver was left running")
	}
}

func TestReceiverProcessFatalOutputStopsChild(t *testing.T) {
	e, run := launchFixture(t, "fatal", 3*time.Second)
	waitForStatus(t, e, StatusError)
	select {
	case <-run.done:
	case <-time.After(5 * time.Second):
		t.Fatal("failed receiver was left running")
	}
	if !strings.Contains(e.Snapshot().LastError, "fixture initialization failed") {
		t.Fatalf("receiver error was hidden: %+v", e.Snapshot())
	}
}

func TestReceiverProcessProductionVideoErrorStopsChild(t *testing.T) {
	e, run := launchFixture(t, "video-error", 3*time.Second)
	waitForStatus(t, e, StatusError)
	select {
	case <-run.done:
	case <-time.After(5 * time.Second):
		t.Fatal("receiver kept running after a fatal video error")
	}
	if e.Snapshot().LastError != "Video output failed: decoder error" {
		t.Fatalf("real native logger prefix hid the video error: %+v", e.Snapshot())
	}
}

func TestReceiverProcessCancelDoesNotRestart(t *testing.T) {
	e, _ := launchFixture(t, "banner-only", 200*time.Millisecond)
	if err := e.Stop(); err != nil {
		t.Fatal(err)
	}
	time.Sleep(300 * time.Millisecond)
	if e.IsRunning() || e.Snapshot().Status != StatusStopped {
		t.Fatalf("cancelled startup changed state later: %+v", e.Snapshot())
	}
}

func TestReceiverProcessCancelDuringRetry(t *testing.T) {
	e, run := launchFixture(t, "crash", 3*time.Second)
	select {
	case <-run.done:
	case <-time.After(4 * time.Second):
		t.Fatal("fixture did not exit")
	}
	if err := e.Stop(); err != nil {
		t.Fatal(err)
	}
	time.Sleep(1200 * time.Millisecond)
	if e.IsRunning() || e.Snapshot().Status != StatusStopped {
		t.Fatalf("delayed retry restarted after Stop: %+v", e.Snapshot())
	}
}

func TestReceiverProcessRepeatedCrashesAreBounded(t *testing.T) {
	e, _ := launchFixture(t, "crash", 3*time.Second)
	waitForStatus(t, e, StatusError)
	if e.IsRunning() || !strings.Contains(e.Snapshot().LastError, "exited repeatedly") {
		t.Fatalf("receiver did not stop retrying: %+v", e.Snapshot())
	}
}

func TestReceiverSetupCancellationDoesNotLaunchLater(t *testing.T) {
	started := make(chan struct{})
	finished := make(chan struct{})
	e := &Engine{
		status: StatusStopped,
		installBonjour: func(ctx context.Context, _ string) error {
			close(started)
			<-ctx.Done()
			close(finished)
			return ctx.Err()
		},
	}
	if err := e.ConfirmSetupAndStart(DefaultConfig()); err != nil {
		t.Fatal(err)
	}
	<-started
	if err := e.Stop(); err != nil {
		t.Fatal(err)
	}
	<-finished
	time.Sleep(30 * time.Millisecond)
	if e.IsRunning() || e.Snapshot().Status != StatusStopped {
		t.Fatalf("cancelled setup changed state later: %+v", e.Snapshot())
	}
}
