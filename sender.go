package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

const castStopGracePeriod = 2 * time.Second

type CastTarget struct {
	ID                       string `json:"id"`
	Name                     string `json:"name"`
	Model                    string `json:"model"`
	Address                  string `json:"address"`
	Port                     int    `json:"port"`
	CanMirror                bool   `json:"canMirror"`
	SupportsTransientPairing bool   `json:"supportsTransientPairing"`
	Reason                   string `json:"reason"`
}

type CastSnapshot struct {
	Revision  uint64       `json:"revision"`
	Status    string       `json:"status"`
	Available bool         `json:"available"`
	Targets   []CastTarget `json:"targets"`
	Target    *CastTarget  `json:"target,omitempty"`
	LastError string       `json:"lastError,omitempty"`
}

type castCommand struct {
	Protocol    int         `json:"protocol"`
	CommandName string      `json:"commandName"`
	Target      *CastTarget `json:"target,omitempty"`
	Pin         string      `json:"pin,omitempty"`
}

type castEvent struct {
	Protocol int          `json:"protocol"`
	Status   string       `json:"status"`
	Targets  []CastTarget `json:"targets"`
	Error    string       `json:"error"`
}

type castProcess struct {
	cmd    *exec.Cmd
	input  io.WriteCloser
	done   chan struct{}
	mode   string
	finish bool
	timer  *time.Timer
}

// Sending has an independent lifecycle: receiving and its settings never start,
// stop, or reconnect a desktop capture. A stopped sender always needs new consent.
type DesktopSender struct {
	operations sync.Mutex
	mu         sync.Mutex
	executable string
	onEvent    func(CastSnapshot)
	snapshot   CastSnapshot
	run        *castProcess
	discovered time.Time
}

func newDesktopSender(onEvent func(CastSnapshot)) *DesktopSender {
	exe, err := os.Executable()
	s := &DesktopSender{onEvent: onEvent}
	s.snapshot = CastSnapshot{Status: "stopped", Targets: []CastTarget{}}
	if err == nil {
		s.executable = filepath.Join(filepath.Dir(exe), "sender", "MirrorMe.Sender.exe")
	}
	info, statErr := os.Stat(s.executable)
	s.snapshot.Available = runtime.GOOS == "windows" && runtime.GOARCH == "amd64" && statErr == nil && !info.IsDir()
	if !s.snapshot.Available {
		s.snapshot.LastError = "Desktop casting needs the Windows x64 sender bundle. Build or extract the complete preview, including its sender folder."
	}
	return s
}

func (s *DesktopSender) Snapshot() CastSnapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	result := s.snapshot
	result.Targets = append([]CastTarget{}, result.Targets...)
	if result.Target != nil {
		target := *result.Target
		result.Target = &target
	}
	return result
}

func (s *DesktopSender) emit() {
	if s.onEvent != nil {
		s.onEvent(s.Snapshot())
	}
}

func (s *DesktopSender) Discover() error {
	s.operations.Lock()
	defer s.operations.Unlock()
	if err := s.checkIdle(); err != nil {
		return err
	}
	s.mu.Lock()
	s.snapshot.Targets = []CastTarget{}
	s.discovered = time.Time{}
	s.mu.Unlock()
	return s.launch(castCommand{CommandName: "discover"}, "discovering")
}

func (s *DesktopSender) checkIdle() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.snapshot.Available {
		return errors.New(s.snapshot.LastError)
	}
	if s.run != nil {
		return errors.New("stop the current desktop casting operation first")
	}
	return nil
}

func (s *DesktopSender) Start(id string, revision uint64) error {
	s.operations.Lock()
	defer s.operations.Unlock()
	if err := s.checkIdle(); err != nil {
		return err
	}
	s.mu.Lock()
	if revision != s.snapshot.Revision {
		s.mu.Unlock()
		return errors.New("desktop casting changed; select Share primary display again")
	}
	if time.Since(s.discovered) > time.Minute {
		s.mu.Unlock()
		return errors.New("refresh AirPlay targets before sharing your desktop")
	}
	var selected *CastTarget
	for _, target := range s.snapshot.Targets {
		if target.ID == id && target.CanMirror {
			copy := target
			selected = &copy
			break
		}
	}
	s.mu.Unlock()
	if selected == nil {
		return errors.New("select a discovered target that supports screen mirroring")
	}
	return s.launch(castCommand{CommandName: "start", Target: selected}, "connecting")
}

func (s *DesktopSender) launch(command castCommand, status string) error {
	cmd := exec.Command(s.executable)
	cmd.Dir = filepath.Dir(s.executable)
	cmd.WaitDelay = castStopGracePeriod
	configureCommand(cmd)
	input, err := cmd.StdinPipe()
	if err != nil {
		return s.fail(nil, fmt.Errorf("open desktop sender pipe: %w", err))
	}
	run := &castProcess{cmd: cmd, input: input, done: make(chan struct{}), mode: command.CommandName}
	output := &receiverOutput{onLine: func(line string) { s.accept(run, line) }}
	cmd.Stdout = output
	// Runtime diagnostics must not leak keys or screen data into logs. A worker
	// failure without a typed error is reported explicitly by monitor().
	cmd.Stderr = io.Discard
	if err := cmd.Start(); err != nil {
		_ = input.Close()
		return s.fail(nil, fmt.Errorf("start desktop sender: %w", err))
	}
	release, err := superviseChild(uint32(cmd.Process.Pid))
	if err != nil {
		_ = cmd.Process.Kill()
		_ = input.Close()
		_ = cmd.Wait()
		return s.fail(nil, fmt.Errorf("supervise desktop sender: %w", err))
	}
	s.mu.Lock()
	s.run = run
	s.snapshot.Status, s.snapshot.LastError = status, ""
	s.snapshot.Target = command.Target
	s.snapshot.Revision++
	s.armTimeoutLocked(run, 35*time.Second)
	s.mu.Unlock()
	s.emit()
	go s.monitor(run, output, release)
	if err := sendCastCommand(run, command); err != nil {
		return s.fail(run, fmt.Errorf("send desktop sender command: %w", err))
	}
	return nil
}

func sendCastCommand(run *castProcess, command castCommand) error {
	command.Protocol = 1
	data, err := json.Marshal(command)
	if err != nil {
		return err
	}
	done := make(chan error, 1)
	go func() {
		_, err := run.input.Write(append(data, '\n'))
		done <- err
	}()
	timer := time.NewTimer(castStopGracePeriod)
	defer timer.Stop()
	select {
	case err := <-done:
		return err
	case <-run.done:
		return errors.New("desktop sender exited")
	case <-timer.C:
		_ = run.input.Close()
		return errors.New("desktop sender did not accept its command")
	}
}

func (s *DesktopSender) SubmitPIN(pin string, revision uint64) error {
	s.operations.Lock()
	defer s.operations.Unlock()
	if len(pin) != 4 || strings.IndexFunc(pin, func(r rune) bool { return r < '0' || r > '9' }) >= 0 {
		return errors.New("enter the four-digit code shown on the AirPlay target")
	}
	s.mu.Lock()
	run := s.run
	if run == nil || s.snapshot.Status != "pairing" || revision != s.snapshot.Revision {
		s.mu.Unlock()
		return errors.New("the AirPlay target is not waiting for a pairing code")
	}
	s.snapshot.Status = "connecting"
	s.snapshot.Revision++
	s.armTimeoutLocked(run, 60*time.Second)
	s.mu.Unlock()
	s.emit()
	if err := sendCastCommand(run, castCommand{CommandName: "pin", Pin: pin}); err != nil {
		return s.fail(run, err)
	}
	return nil
}

func (s *DesktopSender) armTimeoutLocked(run *castProcess, timeout time.Duration) {
	if run.timer != nil {
		run.timer.Stop()
	}
	// A timer that already fired must not cancel a later stage.
	var timer *time.Timer
	timer = time.AfterFunc(timeout, func() {
		s.mu.Lock()
		if s.run != run || run.timer != timer {
			s.mu.Unlock()
			return
		}
		s.setErrorLocked("Desktop casting timed out. Check the target and network, then try again.")
		run.timer = nil
		_ = run.cmd.Process.Kill()
		s.mu.Unlock()
		s.emit()
	})
	run.timer = timer
}

func (s *DesktopSender) accept(run *castProcess, line string) {
	var event castEvent
	err := json.Unmarshal([]byte(line), &event)
	s.mu.Lock()
	if s.run != run || s.snapshot.Status == "stopping" || s.snapshot.Status == "error" {
		s.mu.Unlock()
		return
	}
	if err != nil || event.Protocol != 1 {
		err = errors.New("the desktop sender returned an invalid status message")
	} else {
		switch event.Status {
		case "ready":
			if run.mode != "discover" || event.Targets == nil || len(event.Targets) > 128 {
				err = errors.New("the desktop sender returned an invalid discovery result")
				break
			}
			seen := make(map[string]bool)
			for _, target := range event.Targets {
				if !validCastTarget(target) || seen[target.ID] {
					err = errors.New("the desktop sender returned an invalid AirPlay target")
					break
				}
				seen[target.ID] = true
			}
			if err == nil {
				s.snapshot.Targets = event.Targets
				s.discovered = time.Now()
				run.finish = true
				// Keep discovering until the process exits so Refresh and Start
				// cannot race with the discovery worker's cleanup.
			}
		case "pairing", "connecting", "streaming":
			if run.mode != "start" || (event.Status == "pairing" && s.snapshot.Status != "connecting") ||
				(event.Status == "streaming" && s.snapshot.Status != "connecting") {
				err = errors.New("the desktop sender returned an unexpected connection state")
				break
			}
			s.snapshot.Status = event.Status
			if event.Status == "pairing" {
				s.armTimeoutLocked(run, 130*time.Second)
			} else if event.Status == "connecting" {
				s.armTimeoutLocked(run, 40*time.Second)
			} else if run.timer != nil {
				run.timer.Stop()
				run.timer = nil
			}
		case "error":
			if event.Error == "" {
				event.Error = "The desktop sender reported an error."
			}
			err = errors.New(event.Error)
		default:
			err = errors.New("the desktop sender ended unexpectedly")
		}
	}
	if err != nil {
		s.setErrorLocked(err.Error())
		_ = run.cmd.Process.Kill()
	} else {
		s.snapshot.Revision++
	}
	s.mu.Unlock()
	s.emit()
}

func validCastTarget(target CastTarget) bool {
	ip := net.ParseIP(target.Address)
	return target.ID != "" && len(target.ID) <= 256 && target.Name != "" && len(target.Name) <= 1024 &&
		len(target.Model) <= 512 && len(target.Reason) <= 512 &&
		target.Port > 0 && target.Port <= 65535 && ip != nil && ip.To4() != nil &&
		ip.IsGlobalUnicast() && !ip.IsLoopback()
}

func (s *DesktopSender) monitor(run *castProcess, output *receiverOutput, release func()) {
	err := run.cmd.Wait()
	output.flush()
	release()
	_ = run.input.Close()
	close(run.done)
	s.mu.Lock()
	if s.run == run {
		s.run = nil
		if run.timer != nil {
			run.timer.Stop()
			run.timer = nil
		}
		if s.snapshot.Status != "error" && s.snapshot.Status != "stopping" {
			if run.mode == "discover" && run.finish && err == nil {
				s.snapshot.Status = "ready"
			} else {
				s.setErrorLocked("Desktop casting ended unexpectedly. Check the AirPlay target, graphics driver, and network, then reconnect.")
			}
		}
		s.snapshot.Revision++
	}
	s.mu.Unlock()
	s.emit()
}

func (s *DesktopSender) setErrorLocked(message string) {
	s.snapshot.Status, s.snapshot.LastError = "error", message
	s.snapshot.Revision++
}

func (s *DesktopSender) fail(run *castProcess, err error) error {
	s.mu.Lock()
	if run == nil || s.run == run {
		s.setErrorLocked(err.Error())
		if run != nil {
			_ = run.cmd.Process.Kill()
		}
	}
	s.mu.Unlock()
	s.emit()
	return err
}

func (s *DesktopSender) Stop() error {
	s.operations.Lock()
	defer s.operations.Unlock()
	s.mu.Lock()
	run := s.run
	s.snapshot.Status = "stopping"
	s.snapshot.Revision++
	if run != nil && run.timer != nil {
		run.timer.Stop()
		run.timer = nil
	}
	s.mu.Unlock()
	s.emit()
	if run != nil {
		_ = sendCastCommand(run, castCommand{CommandName: "stop"})
		_ = run.input.Close()
		select {
		case <-run.done:
		case <-time.After(castStopGracePeriod):
			if err := run.cmd.Process.Kill(); err != nil && !errors.Is(err, os.ErrProcessDone) {
				return s.fail(run, fmt.Errorf("stop desktop capture: %w", err))
			}
			select {
			case <-run.done:
			case <-time.After(castStopGracePeriod):
				return s.fail(run, errors.New("desktop capture has not exited; quit MirrorMe to end sharing"))
			}
		}
	}
	s.mu.Lock()
	if s.run == run {
		s.run = nil
	}
	s.snapshot.Status, s.snapshot.LastError, s.snapshot.Target = "stopped", "", nil
	s.snapshot.Revision++
	s.mu.Unlock()
	s.emit()
	return nil
}

func (s *DesktopSender) Forget(id string) error {
	s.operations.Lock()
	defer s.operations.Unlock()
	if err := s.checkIdle(); err != nil {
		return err
	}
	if id == "" || len(id) > 256 {
		return errors.New("select an AirPlay target to forget")
	}
	dir, err := os.UserConfigDir()
	if err != nil {
		return err
	}
	digest := sha256.Sum256([]byte(id))
	path := filepath.Join(dir, "MirrorMe", "sender", strings.ToUpper(hex.EncodeToString(digest[:]))+".dat")
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("forget AirPlay pairing: %w", err)
	}
	return nil
}
