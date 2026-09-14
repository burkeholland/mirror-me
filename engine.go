package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
	"time"
)

type EngineStatus string

const (
	StatusStopped     EngineStatus = "stopped"
	StatusStarting    EngineStatus = "starting"
	StatusAdvertising EngineStatus = "advertising"
	StatusConnecting  EngineStatus = "connecting"
	StatusMirroring   EngineStatus = "mirroring"
	StatusPaused      EngineStatus = "paused"
	StatusError       EngineStatus = "error"

	startupDeadline = 20 * time.Second
	stopGracePeriod = 2 * time.Second
)

type EngineSnapshot struct {
	Status        EngineStatus `json:"status"`
	DeviceName    string       `json:"deviceName,omitempty"`
	DeviceModel   string       `json:"deviceModel,omitempty"`
	ConnectedAt   *time.Time   `json:"connectedAt,omitempty"`
	VideoReceived bool         `json:"videoReceived"`
	LastError     string       `json:"lastError,omitempty"`
	PinCode       string       `json:"pinCode,omitempty"`
	Backend       string       `json:"backend"`
}

type EngineEvent struct {
	Snapshot EngineSnapshot
	Activity string
}

type EngineEventHandler func(EngineEvent)

type receiverProcess struct {
	cmd         *exec.Cmd
	input       io.WriteCloser
	output      *receiverOutput
	diagnostics *receiverOutput
	inputMu     sync.Mutex
	done        chan struct{}
	ready       chan struct{}
	readyOnce   sync.Once
	generation  uint64
	startedAt   time.Time
}

// Lifecycle operations are serialized separately from status updates.
// Exactly one goroutine calls Wait for each child, including during Stop.
type Engine struct {
	exePath        string
	engineDir      string
	onEvent        EngineEventHandler
	nativeDeviceID string
	nativeKeyPath  string

	operations      sync.Mutex
	mu              sync.Mutex
	run             *receiverProcess
	status          EngineStatus
	deviceName      string
	deviceModel     string
	connectedAt     *time.Time
	videoReceived   bool
	lastError       string
	lastOutput      string
	pinCode         string
	desiredRunning  bool
	generation      uint64
	restartAttempts int
	startupTimeout  time.Duration
}

func (e *Engine) Snapshot() EngineSnapshot {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.snapshotLocked()
}

func (e *Engine) snapshotLocked() EngineSnapshot {
	snap := EngineSnapshot{
		Status: e.status, DeviceName: e.deviceName, DeviceModel: e.deviceModel,
		LastError: e.lastError, PinCode: e.pinCode,
		VideoReceived: e.videoReceived, Backend: "native",
	}
	if e.connectedAt != nil {
		connected := *e.connectedAt
		snap.ConnectedAt = &connected
	}
	return snap
}

func (e *Engine) emit(activity string) {
	if e.onEvent != nil {
		e.onEvent(EngineEvent{Snapshot: e.Snapshot(), Activity: activity})
	}
}

func (e *Engine) setError(err error) {
	e.mu.Lock()
	e.status = StatusError
	e.lastError = err.Error()
	e.desiredRunning = false
	e.mu.Unlock()
	e.emit(err.Error())
}

func (e *Engine) Start(config Config) error {
	e.operations.Lock()
	defer e.operations.Unlock()
	e.restartAttempts = 0
	return e.startLocked(config)
}

func (e *Engine) startLocked(config Config) error {
	if err := e.stopLocked(false); err != nil {
		return err
	}
	return e.launch(config)
}

func (e *Engine) launch(config Config) error {
	if info, err := os.Stat(e.exePath); err != nil || info.IsDir() {
		missing := errors.New("the installed MirrorMe executable is no longer available; reopen the application from its current location")
		e.setError(missing)
		return missing
	}
	options, err := makeWorkerOptions(config, e.nativeDeviceID, e.nativeKeyPath)
	if err != nil {
		e.setError(err)
		return err
	}
	cmd := exec.Command(e.exePath, receiverWorkerArgument)
	cmd.Dir = e.engineDir
	cmd.Env = os.Environ()
	cmd.WaitDelay = stopGracePeriod
	configureCommand(cmd)
	input, err := cmd.StdinPipe()
	if err != nil {
		e.setError(fmt.Errorf("open receiver control pipe: %w", err))
		return err
	}

	e.mu.Lock()
	e.generation++
	run := &receiverProcess{
		cmd: cmd, input: input, done: make(chan struct{}), ready: make(chan struct{}),
		generation: e.generation, startedAt: time.Now(),
	}
	run.output = &receiverOutput{onLine: func(line string) { e.handleWorkerLine(run.generation, line) }}
	run.diagnostics = &receiverOutput{onLine: func(line string) { e.handleWorkerDiagnostic(run.generation, line) }}
	cmd.Stdout, cmd.Stderr = run.output, run.diagnostics
	e.run = run
	e.status = StatusStarting
	e.deviceName, e.deviceModel, e.lastError, e.lastOutput = "", "", "", ""
	e.connectedAt = nil
	e.videoReceived = false
	e.pinCode = config.PinCode
	e.desiredRunning = true
	e.mu.Unlock()
	e.emit("Starting the built-in mirroring receiver...")

	if err := cmd.Start(); err != nil {
		_ = input.Close()
		e.mu.Lock()
		e.run = nil
		e.mu.Unlock()
		e.setError(fmt.Errorf("start mirroring receiver: %w", err))
		return err
	}
	releaseJob, err := superviseChild(uint32(cmd.Process.Pid))
	if err != nil {
		_ = cmd.Process.Kill()
		_ = input.Close()
		_ = cmd.Wait()
		e.mu.Lock()
		e.run = nil
		e.mu.Unlock()
		e.setError(fmt.Errorf("supervise mirroring receiver: %w", err))
		return err
	}
	go e.monitorExit(run, config, releaseJob)
	go e.watchStartup(run)
	if err := run.sendCommand(workerCommand{Command: "start", Options: &options}); err != nil {
		message := fmt.Errorf("send receiver startup options: %w", err)
		if stopErr := e.stopLocked(false); stopErr != nil {
			message = errors.Join(message, stopErr)
		}
		e.setError(message)
		return message
	}
	return nil
}

func (e *Engine) watchStartup(run *receiverProcess) {
	timeout := e.startupTimeout
	if timeout <= 0 {
		timeout = startupDeadline
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-run.ready:
	case <-run.done:
	case <-timer.C:
		message := fmt.Sprintf("The receiver did not become ready within %s. Check your local network and Windows media support, then try again.", timeout)
		e.failRun(run.generation, message, true)
	}
}

func (e *Engine) monitorExit(run *receiverProcess, config Config, releaseJob func()) {
	waitErr := run.cmd.Wait()
	run.output.flush()
	run.diagnostics.flush()
	releaseJob()
	close(run.done)

	e.operations.Lock()
	e.mu.Lock()
	if e.run != run || e.generation != run.generation {
		e.mu.Unlock()
		e.operations.Unlock()
		return
	}
	e.run = nil
	if !e.desiredRunning || e.status == StatusError {
		e.mu.Unlock()
		e.operations.Unlock()
		return
	}
	detail := e.lastOutput
	e.mu.Unlock()

	if time.Since(run.startedAt) > 30*time.Second {
		e.restartAttempts = 0
	}
	e.restartAttempts++
	if e.restartAttempts >= 3 {
		message := "The receiver exited repeatedly and has been stopped."
		if waitErr != nil {
			message += " " + waitErr.Error() + "."
		}
		if detail != "" {
			message += " Last output: " + detail
		}
		e.setError(errors.New(message))
		e.operations.Unlock()
		return
	}
	e.mu.Lock()
	e.status = StatusStarting
	e.connectedAt = nil
	e.videoReceived = false
	e.mu.Unlock()
	e.emit("The receiver exited unexpectedly; retrying...")
	e.operations.Unlock()

	time.Sleep(time.Second)
	e.operations.Lock()
	defer e.operations.Unlock()
	e.mu.Lock()
	current := e.generation == run.generation && e.desiredRunning
	e.mu.Unlock()
	if current {
		_ = e.startLocked(config) // startLocked publishes any failure.
	}
}

func (e *Engine) failRun(generation uint64, message string, onlyStarting bool) {
	e.operations.Lock()
	defer e.operations.Unlock()
	e.mu.Lock()
	current := e.generation == generation && e.run != nil
	if onlyStarting && current {
		select {
		case <-e.run.ready:
			current = false
		default:
		}
	}
	e.mu.Unlock()
	if !current {
		return
	}
	if err := e.stopLocked(false); err != nil {
		message += " " + err.Error()
	}
	e.setError(errors.New(message))
}

func (e *Engine) Stop() error {
	e.operations.Lock()
	defer e.operations.Unlock()
	return e.stopLocked(true)
}

func (e *Engine) stopLocked(announce bool) error {
	e.mu.Lock()
	run := e.run
	e.desiredRunning = false
	e.generation++
	e.mu.Unlock()

	if run != nil {
		// EOF also requests shutdown. The Windows job handles parent crashes.
		closeWorkerInput(run)
		select {
		case <-run.done:
		case <-time.After(workerShutdownDeadline + time.Second):
			if err := run.cmd.Process.Kill(); err != nil && !errors.Is(err, os.ErrProcessDone) {
				err = fmt.Errorf("stop mirroring receiver: %w", err)
				e.setError(err)
				return err
			}
			select {
			case <-run.done:
			case <-time.After(2 * stopGracePeriod):
				err := errors.New("Windows has not finished stopping the receiver; try Stop again")
				e.setError(err)
				return err
			}
		}
	}
	e.mu.Lock()
	e.run = nil
	e.deviceName, e.deviceModel = "", ""
	e.connectedAt = nil
	e.videoReceived = false
	if announce {
		e.status = StatusStopped
		e.lastError = ""
	}
	e.mu.Unlock()
	if announce {
		e.emit("Mirroring stopped.")
	}
	return nil
}

func (e *Engine) IsRunning() bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.run != nil || e.desiredRunning
}

func (e *Engine) ShowMirroredScreen() bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.status == StatusPaused || e.run == nil || e.run.cmd.Process == nil {
		return false
	}
	return bringVideoWindowToFront(uint32(e.run.cmd.Process.Pid))
}
