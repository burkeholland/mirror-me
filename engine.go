package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type EngineStatus string

const (
	StatusStopped     EngineStatus = "stopped"
	StatusStarting    EngineStatus = "starting"
	StatusNeedsSetup  EngineStatus = "needs-setup"
	StatusAdvertising EngineStatus = "advertising"
	StatusConnecting  EngineStatus = "connecting"
	StatusMirroring   EngineStatus = "mirroring"
	StatusPaused      EngineStatus = "paused"
	StatusError       EngineStatus = "error"

	receiverExecutable = "mirrorme-receiver.exe"
	startupDeadline    = 20 * time.Second
	stopGracePeriod    = 2 * time.Second
)

type EngineSnapshot struct {
	Status        EngineStatus `json:"status"`
	DeviceName    string       `json:"deviceName,omitempty"`
	DeviceModel   string       `json:"deviceModel,omitempty"`
	ConnectedAt   *time.Time   `json:"connectedAt,omitempty"`
	VideoReceived bool         `json:"videoReceived"`
	SetupKind     string       `json:"setupKind,omitempty"`
	SetupProgress int          `json:"setupProgress"`
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

// Lifecycle operations are serialized separately from status/log updates.
// Exactly one goroutine calls Wait for each child, including during Stop.
type Engine struct {
	exePath        string
	engineDir      string
	cacheDir       string
	onEvent        EngineEventHandler
	builtin        bool
	nativeDeviceID string
	nativeKeyPath  string

	operations      sync.Mutex
	mu              sync.Mutex
	run             *receiverProcess
	setupCancel     context.CancelFunc
	status          EngineStatus
	deviceName      string
	deviceModel     string
	connectedAt     *time.Time
	videoReceived   bool
	setupKind       string
	setupProgress   int
	lastError       string
	lastOutput      string
	pinCode         string
	openConns       int
	desiredRunning  bool
	generation      uint64
	restartAttempts int
	startupTimeout  time.Duration
	checkBonjour    func() (bool, error)
	installBonjour  func(context.Context, string) error
	runtime         *runtimeInstaller
}

var ErrEngineMissing = errors.New("the background mirroring receiver is missing; rebuild or reinstall MirrorMe with its engine folder")

func NewEngine(onEvent EngineEventHandler) (*Engine, error) {
	if selfContainedReceiver {
		return newSelfContainedEngine(onEvent)
	}
	dir, exe, err := locateEngine()
	if err != nil {
		return nil, err
	}
	cacheRoot, err := os.UserCacheDir()
	if err != nil {
		return nil, fmt.Errorf("find receiver cache directory: %w", err)
	}
	cacheDir := filepath.Join(cacheRoot, "MirrorMe", "receiver")
	if err := os.MkdirAll(cacheDir, 0o700); err != nil {
		return nil, fmt.Errorf("create receiver cache directory: %w", err)
	}
	installer, err := newRuntimeInstaller(exe, cacheDir)
	if err != nil {
		return nil, err
	}
	if !runtimeFilesPresent(dir) && installer.ready() {
		dir = installer.target
		exe = filepath.Join(dir, receiverExecutable)
	}
	return &Engine{
		exePath: exe, engineDir: dir, cacheDir: cacheDir, onEvent: onEvent,
		status: StatusStopped, startupTimeout: startupDeadline, runtime: installer,
	}, nil
}

func locateEngine() (dir, exePath string, err error) {
	var candidates []string
	if exe, exeErr := os.Executable(); exeErr == nil {
		candidates = append(candidates, filepath.Join(filepath.Dir(exe), "engine"))
	}
	if cwd, cwdErr := os.Getwd(); cwdErr == nil {
		candidates = append(candidates, filepath.Join(cwd, "engine"))
	}
	return findEngineIn(candidates)
}

func findEngineIn(candidates []string) (dir, exePath string, err error) {
	for _, candidate := range candidates {
		full := filepath.Join(candidate, receiverExecutable)
		if info, statErr := os.Stat(full); statErr == nil && !info.IsDir() {
			return candidate, full, nil
		}
	}
	return "", "", ErrEngineMissing
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
		VideoReceived: e.videoReceived,
		SetupKind:     e.setupKind, SetupProgress: e.setupProgress,
		Backend: "legacy",
	}
	if e.builtin {
		snap.Backend = "native"
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
	if e.builtin {
		return e.launch(config)
	}
	if e.runtime != nil && !runtimeFilesPresent(e.engineDir) {
		e.mu.Lock()
		e.status, e.setupKind, e.setupProgress = StatusNeedsSetup, "runtime", 0
		e.lastError = ""
		e.mu.Unlock()
		e.emit("Download receiver files once from GitHub to enable mirroring.")
		return nil
	}
	check := e.checkBonjour
	if check == nil {
		check = bonjourReady
	}
	ready, err := check()
	if err != nil {
		e.setError(err)
		return err
	}
	if !ready {
		e.mu.Lock()
		e.status = StatusNeedsSetup
		e.setupKind = "bonjour"
		e.lastError = ""
		e.mu.Unlock()
		e.emit("Bonjour needs to be installed or started. Choose Allow discovery.")
		return nil
	}
	return e.launch(config)
}

// Setup is explicitly requested by the user. Cancelling it prevents a late
// installer completion from restarting mirroring after the user pressed Stop.
func (e *Engine) ConfirmSetupAndStart(config Config) error {
	if e.builtin {
		return e.Start(config)
	}
	e.operations.Lock()
	defer e.operations.Unlock()
	if err := e.stopLocked(false); err != nil {
		return err
	}

	installRuntime := e.runtime != nil && !runtimeFilesPresent(e.engineDir)
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Minute)
	e.mu.Lock()
	e.setupCancel = cancel
	e.desiredRunning = true
	e.status = StatusStarting
	e.lastError = ""
	e.setupProgress = 0
	if installRuntime {
		e.setupKind = "runtime"
	} else {
		e.setupKind = "bonjour"
	}
	generation := e.generation
	e.mu.Unlock()
	if installRuntime {
		e.emit("Downloading receiver files from GitHub. You can cancel at any time.")
	} else {
		e.emit("Setting up Bonjour. Approve the Windows permission prompt to continue.")
	}

	go func() {
		defer cancel()
		var directory string
		var err error
		if installRuntime {
			directory, err = e.runtime.install(ctx, func(progress int) {
				e.mu.Lock()
				current := e.generation == generation && e.desiredRunning
				if current {
					e.setupProgress = progress
				}
				e.mu.Unlock()
				if current {
					e.emit("")
				}
			})
		} else {
			install := e.installBonjour
			if install == nil {
				install = setupBonjour
			}
			err = install(ctx, e.engineDir)
		}
		e.operations.Lock()
		defer e.operations.Unlock()
		e.mu.Lock()
		current := e.generation == generation && e.desiredRunning
		if current {
			e.setupCancel = nil
		}
		e.mu.Unlock()
		if !current {
			return
		}
		if err != nil {
			e.setError(fmt.Errorf("Mirroring setup did not finish: %w", err))
			return
		}
		if installRuntime {
			e.engineDir, e.exePath = directory, filepath.Join(directory, receiverExecutable)
		}
		_ = e.startLocked(config) // startLocked publishes any failure.
	}()
	return nil
}

// Called with operations held. The receiver accepts real argv and writes
// directly to our pipes: there are no shared Qt settings or guessed log paths.
func (e *Engine) launch(config Config) error {
	if info, err := os.Stat(e.exePath); err != nil || info.IsDir() {
		missing := ErrEngineMissing
		if e.builtin {
			missing = errors.New("the installed MirrorMe executable is no longer available; reopen the application from its current location")
		}
		e.setError(missing)
		return missing
	}
	args := buildEngineArgs(config)
	var nativeOptions workerOptions
	if e.builtin {
		var err error
		nativeOptions, err = makeWorkerOptions(config, e.nativeDeviceID, e.nativeKeyPath)
		if err != nil {
			e.setError(err)
			return err
		}
		args = []string{receiverWorkerArgument}
	}
	cmd := exec.Command(e.exePath, args...)
	cmd.Dir = e.engineDir
	if e.builtin {
		cmd.Env = os.Environ()
	} else {
		cmd.Env = receiverEnvironment(e.engineDir, e.cacheDir)
	}
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
	run.output = &receiverOutput{onLine: func(line string) {
		if e.builtin {
			e.handleWorkerLine(run.generation, line)
		} else {
			e.handleLogLine(run.generation, line)
		}
	}}
	cmd.Stdout, cmd.Stderr = run.output, run.output
	if e.builtin {
		run.diagnostics = &receiverOutput{onLine: func(line string) { e.handleWorkerDiagnostic(run.generation, line) }}
		cmd.Stderr = run.diagnostics
	}
	e.run = run
	e.status = StatusStarting
	e.setupKind, e.setupProgress = "", 0
	e.deviceName, e.deviceModel, e.lastError, e.lastOutput = "", "", "", ""
	e.connectedAt = nil
	e.videoReceived = false
	e.pinCode = config.PinCode
	e.openConns = 0
	e.desiredRunning = true
	e.mu.Unlock()
	e.emit("Starting the background mirroring receiver...")

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
	if e.builtin {
		if err := run.sendCommand(workerCommand{Command: "start", Options: &nativeOptions}); err != nil {
			message := fmt.Errorf("send receiver startup options: %w", err)
			if stopErr := e.stopLocked(false); stopErr != nil {
				message = errors.Join(message, stopErr)
			}
			e.setError(message)
			return message
		}
	}
	return nil
}

func receiverEnvironment(engineDir, cacheDir string) []string {
	plugins := filepath.Join(engineDir, "lib", "gstreamer-1.0")
	env := append(os.Environ(),
		"PATH="+engineDir+";"+os.Getenv("PATH"),
		"GST_PLUGIN_PATH="+plugins,
		"GST_PLUGIN_PATH_1_0="+plugins,
		"GST_PLUGIN_SYSTEM_PATH="+plugins,
		"GST_PLUGIN_SYSTEM_PATH_1_0="+plugins,
		"GST_DEBUG_NO_COLOR=1",
	)
	if cacheDir != "" {
		env = append(env, "GST_REGISTRY="+filepath.Join(cacheDir, "gstreamer-registry.bin"))
	}
	return env
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
		message := fmt.Sprintf("The receiver did not become ready within %s. Check that Bonjour is running, then try again.", timeout)
		if e.builtin {
			message = fmt.Sprintf("The receiver did not become ready within %s. Check your local network and Windows media support, then try again.", timeout)
		}
		e.failRun(run.generation, message, true)
	}
}

func (e *Engine) monitorExit(run *receiverProcess, config Config, releaseJob func()) {
	waitErr := run.cmd.Wait()
	run.output.flush()
	if run.diagnostics != nil {
		run.diagnostics.flush()
	}
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
	if e.setupCancel != nil {
		e.setupCancel()
		e.setupCancel = nil
	}
	e.mu.Unlock()

	if run != nil {
		// EOF is also a shutdown request, so an abrupt parent exit does not
		// leave a receiver behind. The Windows job adds process-tree cleanup.
		closeWorkerInput(run, e.builtin)
		grace := stopGracePeriod
		if e.builtin {
			grace = workerShutdownDeadline + time.Second
		}
		select {
		case <-run.done:
		case <-time.After(grace):
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
	e.openConns = 0
	e.videoReceived = false
	if announce {
		e.status = StatusStopped
		e.setupKind, e.setupProgress = "", 0
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
	return e.run != nil || e.setupCancel != nil || e.desiredRunning
}

func (e *Engine) ShowMirroredScreen() bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.status == StatusPaused || e.run == nil || e.run.cmd.Process == nil {
		return false
	}
	return bringVideoWindowToFront(uint32(e.run.cmd.Process.Pid))
}

func (e *Engine) handleLogLine(generation uint64, line string) {
	line = strings.TrimSpace(line)
	fact, ok := parseLogLine(line)
	e.mu.Lock()
	if e.generation != generation || !e.desiredRunning {
		e.mu.Unlock()
		return
	}
	if line != "" {
		text := []rune(line)
		e.lastOutput = string(text[:min(len(text), 300)])
	}
	if !ok {
		e.mu.Unlock()
		return
	}

	activity := ""
	switch fact.kind {
	case factEngineReady:
		if e.run != nil {
			e.run.readyOnce.Do(func() { close(e.run.ready) })
		}
		if e.status == StatusStarting {
			e.status = StatusAdvertising
			activity = "Ready. Open Screen Mirroring on your iPhone to connect."
		}
	case factConnectionRequest:
		e.deviceName, e.deviceModel = fact.deviceName, fact.deviceModel
		if e.status != StatusMirroring {
			e.status = StatusConnecting
			e.videoReceived = false
		}
		activity = fmt.Sprintf("%s is connecting...", fact.deviceName)
	case factOpenConnections:
		wasConnected := e.openConns > 0
		e.openConns = fact.openConnections
		// AirPlay opens control sockets before there is any video. A socket
		// alone must never make the UI claim the screen is being mirrored.
		if e.openConns == 0 && wasConnected {
			e.connectedAt = nil
			e.videoReceived = false
			e.status = StatusAdvertising
			e.deviceName, e.deviceModel = "", ""
			activity = "Device disconnected."
		}
	case factVideoReceived:
		if e.status == StatusConnecting && !e.videoReceived {
			e.videoReceived = true
			activity = "Video received. Opening the mirrored screen."
		}
	case factStreaming:
		if e.status == StatusConnecting {
			now := time.Now()
			e.connectedAt = &now
			e.status = StatusMirroring
			activity = "Streaming mirrored screen."
		}
	case factVideoStopped:
		if e.status == StatusMirroring || e.status == StatusConnecting {
			e.status = StatusAdvertising
			e.connectedAt = nil
			e.videoReceived = false
			e.deviceName, e.deviceModel = "", ""
			activity = "Video stopped. Ready for another connection."
		}
	case factWarning:
		activity = "Lost contact with the device. Check its Wi-Fi connection."
	case factReceiverNotice:
		activity = fact.message
	case factFatalError:
		e.status = StatusError
		e.lastError = fact.message
		e.desiredRunning = false
		activity = fact.message
	}
	e.mu.Unlock()
	if activity != "" {
		e.emit(activity)
	}
	if fact.kind == factFatalError {
		go e.failRun(generation, fact.message, false)
	}
}
