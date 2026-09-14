package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

func NewEngine(onEvent EngineEventHandler) (*Engine, error) {
	if !nativeReceiverAvailable {
		return nil, errors.New("the built-in receiver is unavailable in this build; use a Windows x64 production build")
	}
	executable, err := os.Executable()
	if err != nil {
		return nil, fmt.Errorf("locate the installed application: %w", err)
	}
	configDirectory, err := os.UserConfigDir()
	if err != nil {
		return nil, fmt.Errorf("locate the receiver identity directory: %w", err)
	}
	deviceID, keyPath, err := receiverIdentity(filepath.Join(configDirectory, "MirrorMe", "identity"))
	if err != nil {
		return nil, err
	}
	return &Engine{
		exePath: executable, engineDir: filepath.Dir(executable), onEvent: onEvent,
		status: StatusStopped, startupTimeout: startupDeadline,
		nativeDeviceID: deviceID, nativeKeyPath: keyPath,
	}, nil
}

func (run *receiverProcess) sendCommand(command workerCommand) error {
	command.Protocol = workerProtocolVersion
	encoded, err := json.Marshal(command)
	if err != nil {
		return fmt.Errorf("encode receiver command: %w", err)
	}
	if len(encoded) >= maxReceiverLine {
		return errors.New("the receiver command exceeds its size limit")
	}
	completed := make(chan error, 1)
	go func() {
		run.inputMu.Lock()
		defer run.inputMu.Unlock()
		_, err := run.input.Write(append(encoded, '\n'))
		completed <- err
	}()
	timer := time.NewTimer(stopGracePeriod)
	defer timer.Stop()
	select {
	case err := <-completed:
		return err
	case <-run.done:
		return errors.New("the receiver closed before accepting its command")
	case <-timer.C:
		// Closing an OS pipe interrupts the write. Do not strand a goroutine
		// or hold lifecycle operations behind an unresponsive worker.
		_ = run.input.Close()
		return errors.New("the receiver did not accept its control command")
	}
}

func (e *Engine) handleWorkerLine(generation uint64, line string) {
	event, err := decodeWorkerEvent(line)
	if err != nil {
		event = workerEvent{Kind: workerError, Message: "The built-in receiver sent an invalid status message."}
	}
	e.mu.Lock()
	if e.generation != generation || !e.desiredRunning {
		e.mu.Unlock()
		return
	}
	activity := ""
	switch event.Kind {
	case workerReady:
		if e.run != nil {
			e.run.readyOnce.Do(func() { close(e.run.ready) })
		}
		if e.status == StatusStarting {
			e.status = StatusAdvertising
			activity = "Ready. Open Screen Mirroring on your iPhone to connect."
		}
	case workerConnecting:
		if e.status == StatusPaused {
			break
		}
		if e.status != StatusMirroring {
			e.status = StatusConnecting
			e.videoReceived = false
			e.connectedAt = nil
		}
		e.deviceName = ""
		activity = "Your iPhone is connecting."
	case workerVideoReceived:
		if e.status == StatusAdvertising || e.status == StatusConnecting || e.status == StatusPaused {
			e.status = StatusConnecting
			if !e.videoReceived {
				e.videoReceived = true
				activity = "Video received. Opening the mirrored screen."
			}
		}
	case workerStreaming:
		if e.status == StatusConnecting && e.videoReceived {
			now := time.Now()
			e.status, e.connectedAt = StatusMirroring, &now
			activity = "Streaming mirrored screen."
		}
	case workerSessionEnded:
		if e.status == StatusConnecting || e.status == StatusMirroring || e.status == StatusPaused {
			e.status = StatusAdvertising
			e.videoReceived, e.connectedAt = false, nil
			e.deviceName, e.deviceModel = "", ""
			activity = "Mirroring ended. Ready for another connection."
		}
	case workerPaused:
		if e.status == StatusConnecting || e.status == StatusMirroring {
			e.status = StatusPaused
			e.videoReceived, e.connectedAt = false, nil
			activity = "Mirroring is paused. Unlock your iPhone to resume."
		}
	case workerError:
		e.status, e.desiredRunning = StatusError, false
		e.lastError = event.Message
		if e.lastError == "" {
			e.lastError = "The built-in receiver reported an error."
		}
		activity = e.lastError
	case workerNotice:
		activity = event.Message
	}
	e.mu.Unlock()
	if activity != "" {
		e.emit(activity)
	}
	if event.Kind == workerError {
		go e.failRun(generation, activity, false)
	}
}

func (e *Engine) handleWorkerDiagnostic(generation uint64, _ string) {
	e.mu.Lock()
	if e.generation != generation || !e.desiredRunning {
		e.mu.Unlock()
		return
	}
	first := e.lastOutput == ""
	e.lastOutput = "The native receiver reported diagnostic output."
	e.mu.Unlock()
	if first {
		e.emit("The native receiver reported a diagnostic. Any playback failure will appear here.")
	}
}

func closeWorkerInput(run *receiverProcess) {
	_ = run.sendCommand(workerCommand{Command: "stop"})
	_ = run.input.Close()
}
