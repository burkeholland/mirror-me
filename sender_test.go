package main

import (
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

// The portable file-list runner and the full Windows test binary both execute
// this helper before their test entry points. It never performs network capture.
func init() {
	if mode := os.Getenv("MIRRORME_CAST_DISCOVERY_FIXTURE"); mode != "" {
		var command castCommand
		if err := json.NewDecoder(os.Stdin).Decode(&command); err != nil || command.CommandName != "discover" {
			os.Exit(2)
		}
		if mode == "error" {
			_ = json.NewEncoder(os.Stdout).Encode(castEvent{Protocol: 1, Status: "error", Error: "Discovery unavailable"})
			os.Exit(1)
		}
		if mode == "silent" {
			_, _ = io.Copy(io.Discard, os.Stdin)
			os.Exit(0)
		}
		if mode != "ready" {
			os.Exit(2)
		}
		target := testCastTarget()
		target.Address = "192.168.1.21"
		_ = json.NewEncoder(os.Stdout).Encode(castEvent{Protocol: 1, Status: "ready", Targets: []CastTarget{target}})
		os.Exit(0)
	}
}

func testCastTarget() CastTarget {
	return CastTarget{ID: "AABBCCDDEEFF", Name: "Living Room", Model: "AppleTV11,1",
		Address: "192.168.1.20", Port: 7000, CanMirror: true, SupportsTransientPairing: true}
}

func testDesktopSender() *DesktopSender {
	return &DesktopSender{snapshot: CastSnapshot{
		Status: "ready", Available: true, Targets: []CastTarget{testCastTarget()},
	}, discovered: time.Now()}
}

func TestCastTargetsValidateEndpoints(t *testing.T) {
	target := testCastTarget()
	if !validCastTarget(target) {
		t.Fatal("valid local target rejected")
	}
	for _, address := range []string{"", "127.0.0.1", "0.0.0.0", "224.0.0.251", "255.255.255.255", "::1", "example.com"} {
		target.Address = address
		if validCastTarget(target) {
			t.Errorf("accepted invalid target address %q", address)
		}
	}
}

func TestCastSnapshotsDoNotShareMutableTargets(t *testing.T) {
	s := testDesktopSender()
	target := testCastTarget()
	s.snapshot.Target = &target
	snapshot := s.Snapshot()
	snapshot.Targets[0].Name = "modified"
	snapshot.Target.Name = "modified"
	if s.Snapshot().Targets[0].Name != target.Name || s.Snapshot().Target.Name != target.Name {
		t.Fatal("snapshot exposed mutable sender state")
	}
	if !s.Snapshot().Targets[0].SupportsTransientPairing {
		t.Fatal("snapshot dropped the discovered pairing capability")
	}
}

func TestCastStartRequiresFreshDiscoveredScreenTarget(t *testing.T) {
	s := testDesktopSender()
	for _, id := range []string{"", "192.168.1.20", "../../outside"} {
		if err := s.Start(id, s.Snapshot().Revision); err == nil {
			t.Errorf("accepted undiscovered id %q", id)
		}
	}
	s.snapshot.Targets[0].CanMirror = false
	if err := s.Start(testCastTarget().ID, s.Snapshot().Revision); err == nil {
		t.Fatal("accepted audio-only target")
	}
	s.snapshot.Targets[0].CanMirror = true
	s.discovered = time.Now().Add(-2 * time.Minute)
	if err := s.Start(testCastTarget().ID, s.Snapshot().Revision); err == nil {
		t.Fatal("accepted stale discovery")
	}
}

func TestCastPINRequiresPairingAndFourASCIIDigits(t *testing.T) {
	s := testDesktopSender()
	for _, pin := range []string{"", "123", "12345", "abcd", "１２３４", "12\n4", "1234"} {
		if err := s.SubmitPIN(pin, s.Snapshot().Revision); err == nil {
			t.Errorf("accepted PIN outside pairing: %q", pin)
		}
	}
}

func TestCastTypedStatesAndLateEvents(t *testing.T) {
	s := testDesktopSender()
	run := &castProcess{mode: "start"}
	s.run = run
	s.snapshot.Status = "connecting"
	for _, status := range []string{"pairing", "connecting", "streaming"} {
		event, _ := json.Marshal(castEvent{Protocol: 1, Status: status})
		s.accept(run, string(event))
		if s.Snapshot().Status != status {
			t.Fatalf("did not accept %s: %+v", status, s.Snapshot())
		}
	}
	if run.timer != nil {
		t.Fatal("streaming retained a connection timeout")
	}
	s.run = nil
	s.snapshot.Status = "stopped"
	s.accept(run, `{"protocol":1,"status":"streaming"}`)
	if s.Snapshot().Status != "stopped" {
		t.Fatal("late worker event resurrected capture")
	}
}

func TestCastDiscoveryWaitsForWorkerExit(t *testing.T) {
	s := testDesktopSender()
	run := &castProcess{mode: "discover"}
	s.run = run
	s.snapshot.Status = "discovering"
	event, _ := json.Marshal(castEvent{Protocol: 1, Status: "ready", Targets: []CastTarget{testCastTarget()}})
	s.accept(run, string(event))
	if !run.finish || s.Snapshot().Status != "discovering" {
		t.Fatal("discovery became idle before the worker exited")
	}
	if err := s.Start(testCastTarget().ID, s.Snapshot().Revision); err == nil {
		t.Fatal("started a second worker during discovery")
	}
}

func TestCastStopInvalidatesPendingStartConsent(t *testing.T) {
	s := testDesktopSender()
	revision := s.Snapshot().Revision
	if err := s.Stop(); err != nil {
		t.Fatal(err)
	}
	if err := s.Start(testCastTarget().ID, revision); err == nil {
		t.Fatal("a delayed Start overtook Stop")
	}
	if s.Snapshot().Status != "stopped" {
		t.Fatal("stale consent changed the sender state")
	}
}

func TestCastPipeCommandKeepsPINOutOfArguments(t *testing.T) {
	input, output := io.Pipe()
	defer input.Close()
	defer output.Close()
	run := &castProcess{input: output, done: make(chan struct{}), cmd: exec.Command("sender")}
	result := make(chan castCommand, 1)
	go func() {
		var command castCommand
		_ = json.NewDecoder(input).Decode(&command)
		result <- command
	}()
	if err := sendCastCommand(run, castCommand{CommandName: "pin", Pin: "1234"}); err != nil {
		t.Fatal(err)
	}
	command := <-result
	if command.Protocol != 1 || command.Pin != "1234" || !reflect.DeepEqual(run.cmd.Args, []string{"sender"}) {
		t.Fatal("PIN command did not use the private versioned pipe")
	}
}

func TestCastStopKillsUnresponsiveProcessAndIgnoresLateState(t *testing.T) {
	cmd := exec.Command(os.Args[0], "-test.run=^TestCastBlockingHelper$")
	cmd.Env = append(os.Environ(), "MIRRORME_CAST_TEST_HELPER=1")
	input, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cmd.Process.Kill() })
	s := testDesktopSender()
	run := &castProcess{cmd: cmd, input: input, done: make(chan struct{}), mode: "start"}
	s.run = run
	s.snapshot.Status = "streaming"
	output := &receiverOutput{onLine: func(string) {}}
	go s.monitor(run, output, func() {})
	if err := s.Stop(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-run.done:
	default:
		t.Fatal("reported stopped before the capture process exited")
	}
	s.accept(run, `{"protocol":1,"status":"streaming"}`)
	if s.Snapshot().Status != "stopped" {
		t.Fatal("a late event restarted capture")
	}
}

func waitForCastStatus(t *testing.T, s *DesktopSender, status string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if s.Snapshot().Status == status {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("sender status = %+v, want %s", s.Snapshot(), status)
}

func TestCastDisconnectRefreshesAfterCaptureExits(t *testing.T) {
	cmd := exec.Command(os.Args[0], "-test.run=^TestCastBlockingHelper$")
	cmd.Env = append(os.Environ(), "MIRRORME_CAST_TEST_HELPER=1")
	input, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cmd.Process.Kill() })
	t.Setenv("MIRRORME_CAST_DISCOVERY_FIXTURE", "ready")
	s := testDesktopSender()
	s.executable = os.Args[0]
	t.Cleanup(func() { _ = s.Stop() })
	target := testCastTarget()
	s.snapshot.Status, s.snapshot.Target = "streaming", &target
	s.discovered = time.Now().Add(-2 * time.Minute)
	oldRevision := s.Snapshot().Revision
	run := &castProcess{cmd: cmd, input: input, done: make(chan struct{}), mode: "start"}
	s.run = run
	s.onEvent = func(snapshot CastSnapshot) {
		if snapshot.Status == "discovering" {
			select {
			case <-run.done:
			default:
				t.Error("refreshed before capture exited")
			}
		}
	}
	go s.monitor(run, &receiverOutput{onLine: func(string) {}}, func() {})
	disconnectedAt := time.Now()
	if err := s.Disconnect(); err != nil {
		t.Fatal(err)
	}
	waitForCastStatus(t, s, "ready")
	snapshot := s.Snapshot()
	if snapshot.LastError != "" || snapshot.Target != nil || len(snapshot.Targets) != 1 || snapshot.Targets[0].Address != "192.168.1.21" ||
		s.discovered.Before(disconnectedAt) {
		t.Fatalf("disconnect did not return fresh targets: %+v", snapshot)
	}
	s.accept(run, `{"protocol":1,"status":"streaming"}`)
	if err := s.Start(target.ID, oldRevision); err == nil {
		t.Fatal("disconnect refresh re-enabled an old sharing command")
	}
	if s.Snapshot().Status != "ready" {
		t.Fatal("refresh restarted sharing or accepted a late event")
	}
}

func TestCastDisconnectAfterPairingOrErrorRefreshes(t *testing.T) {
	for _, status := range []string{"connecting", "pairing", "error"} {
		t.Run(status, func(t *testing.T) {
			t.Setenv("MIRRORME_CAST_DISCOVERY_FIXTURE", "ready")
			s := testDesktopSender()
			s.executable = os.Args[0]
			t.Cleanup(func() { _ = s.Stop() })
			target := testCastTarget()
			s.snapshot.Status, s.snapshot.Target, s.snapshot.LastError = status, &target, "Previous warning"
			if err := s.Disconnect(); err != nil {
				t.Fatal(err)
			}
			waitForCastStatus(t, s, "ready")
			if s.Snapshot().LastError != "" {
				t.Fatal("disconnect left an old warning visible")
			}
		})
	}
}

func TestCastDiscoveryCancelAndShutdownDoNotRefresh(t *testing.T) {
	t.Setenv("MIRRORME_CAST_DISCOVERY_FIXTURE", "silent")
	for _, automatic := range []bool{false, true} {
		s := testDesktopSender()
		s.executable = os.Args[0]
		t.Cleanup(func() { _ = s.Stop() })
		if automatic {
			target := testCastTarget()
			s.snapshot.Target = &target
			if err := s.Disconnect(); err != nil {
				t.Fatal(err)
			}
		} else if err := s.Discover(); err != nil {
			t.Fatal(err)
		}
		if s.Snapshot().Status != "discovering" {
			t.Fatal("discovery did not start")
		}
		if err := s.Disconnect(); err != nil {
			t.Fatal(err)
		}
		if s.Snapshot().Status != "stopped" {
			t.Fatal("cancelling discovery started another scan")
		}
	}
	s := testDesktopSender()
	s.executable = os.Args[0]
	t.Cleanup(func() { _ = s.Stop() })
	target := testCastTarget()
	s.snapshot.Target = &target
	s.snapshot.Status = "streaming"
	if err := s.Stop(); err != nil {
		t.Fatal(err)
	}
	if s.Snapshot().Status != "stopped" {
		t.Fatal("shutdown started discovery")
	}
}

func TestCastDisconnectSurfacesRefreshFailure(t *testing.T) {
	t.Setenv("MIRRORME_CAST_DISCOVERY_FIXTURE", "error")
	s := testDesktopSender()
	s.executable = os.Args[0]
	t.Cleanup(func() { _ = s.Stop() })
	target := testCastTarget()
	s.snapshot.Target = &target
	if err := s.Disconnect(); err != nil {
		t.Fatal(err)
	}
	waitForCastStatus(t, s, "error")
	if !strings.Contains(s.Snapshot().LastError, "Discovery unavailable") {
		t.Fatalf("refresh failure was hidden: %+v", s.Snapshot())
	}
}

func TestCastBlockingHelper(t *testing.T) {
	if os.Getenv("MIRRORME_CAST_TEST_HELPER") != "1" {
		return
	}
	time.Sleep(time.Minute)
	os.Exit(0)
}

func TestCastConcurrentSnapshots(t *testing.T) {
	s := testDesktopSender()
	var wg sync.WaitGroup
	for range 10 {
		wg.Go(func() {
			for range 100 {
				_ = s.Snapshot()
			}
		})
	}
	wg.Wait()
}

func TestCastMalformedEventsFailClosed(t *testing.T) {
	for _, event := range []string{
		`invalid`, `{"protocol":2,"status":"streaming"}`, `{"protocol":1,"status":"unknown"}`,
		`{"protocol":1,"status":"ready","targets":null}`, `{"protocol":1,"status":"error","error":"Pairing rejected"}`,
		`{"protocol":1,"status":"ready","targets":[{"id":"same","name":"TV","address":"192.168.1.20","port":7000},{"id":"same","name":"TV","address":"192.168.1.21","port":7000}]}`,
	} {
		t.Run(event, func(t *testing.T) {
			cmd := exec.Command(os.Args[0], "-test.run=^TestCastBlockingHelper$")
			cmd.Env = append(os.Environ(), "MIRRORME_CAST_TEST_HELPER=1")
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			defer cmd.Wait()
			defer cmd.Process.Kill()
			s := testDesktopSender()
			run := &castProcess{cmd: cmd, mode: "discover"}
			s.run = run
			s.snapshot.Status = "discovering"
			s.accept(run, event)
			if s.Snapshot().Status != "error" || s.Snapshot().LastError == "" {
				t.Fatal("invalid event was not surfaced")
			}
		})
	}
}

func TestCastDiscoveryKeepsSameNamesWithDifferentIDs(t *testing.T) {
	target := testCastTarget()
	target.ID = "112233445566"
	target.Address = "192.168.1.40"
	s := testDesktopSender()
	run := &castProcess{mode: "discover"}
	s.run = run
	s.snapshot.Status = "discovering"
	event, _ := json.Marshal(castEvent{Protocol: 1, Status: "ready", Targets: []CastTarget{testCastTarget(), target}})
	s.accept(run, string(event))
	snapshot := s.Snapshot()
	if !run.finish || len(snapshot.Targets) != 2 || snapshot.Targets[0].ID == snapshot.Targets[1].ID ||
		snapshot.Targets[0].Name != snapshot.Targets[1].Name {
		t.Fatal("discovery did not preserve distinct devices with the same name")
	}
}
