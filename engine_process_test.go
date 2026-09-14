package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Re-executing the test binary exercises process pipes without a real phone.
func TestMain(m *testing.M) {
	if mode := os.Getenv("MIRRORME_TEST_RECEIVER"); mode != "" {
		os.Exit(runNativeFixture(mode))
	}
	if len(os.Args) == 2 && os.Args[1] == receiverWorkerArgument {
		os.Exit(runReceiverWorker(os.Stdin, os.Stdout, createNativeReceiver))
	}
	os.Exit(m.Run())
}

func launchFixture(t *testing.T, mode string, timeout time.Duration) (*Engine, *receiverProcess) {
	t.Helper()
	t.Setenv("MIRRORME_TEST_RECEIVER", mode)
	directory := t.TempDir()
	e := &Engine{
		exePath: os.Args[0], engineDir: directory,
		status: StatusStopped, startupTimeout: timeout,
		nativeDeviceID: "02:12:34:56:78:90",
		nativeKeyPath:  filepath.Join(directory, "pairing.key"),
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

func TestReceiverProcessCancelDoesNotRestart(t *testing.T) {
	e, _ := launchFixture(t, "native-silent", 200*time.Millisecond)
	if err := e.Stop(); err != nil {
		t.Fatal(err)
	}
	time.Sleep(300 * time.Millisecond)
	if e.IsRunning() || e.Snapshot().Status != StatusStopped {
		t.Fatalf("cancelled startup changed state later: %+v", e.Snapshot())
	}
}

func TestReceiverProcessCancelDuringRetry(t *testing.T) {
	e, run := launchFixture(t, "native-crash", 3*time.Second)
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
	e, _ := launchFixture(t, "native-crash", 3*time.Second)
	waitForStatus(t, e, StatusError)
	if e.IsRunning() || !strings.Contains(e.Snapshot().LastError, "exited repeatedly") {
		t.Fatalf("receiver did not stop retrying: %+v", e.Snapshot())
	}
}
