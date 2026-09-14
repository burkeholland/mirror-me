package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

const (
	receiverWorkerArgument = "--receiver-worker"
	workerProtocolVersion  = 1
	workerMessageLimit     = 4096
	workerShutdownDeadline = 5 * time.Second
)

type workerOptions struct {
	Name               string `json:"name"`
	DeviceID           string `json:"deviceId"`
	KeyPath            string `json:"keyPath"`
	Width              uint32 `json:"width"`
	Height             uint32 `json:"height"`
	MaxFPS             uint32 `json:"maxFps"`
	IdleTimeoutSeconds uint32 `json:"idleTimeoutSeconds"`
	Pin                uint32 `json:"pin"`
	RequirePin         bool   `json:"requirePin"`
	PreferNewest       bool   `json:"preferNewest"`
	HardwareDecode     bool   `json:"hardwareDecode"`
	AllowH265          bool   `json:"allowH265"`
	AudioEnabled       bool   `json:"audioEnabled"`
}

type workerCommand struct {
	Protocol int            `json:"protocol"`
	Command  string         `json:"command"`
	Options  *workerOptions `json:"options,omitempty"`
}

type workerEvent struct {
	Protocol int    `json:"protocol"`
	Kind     int    `json:"kind"`
	Message  string `json:"message,omitempty"`
}

const (
	workerReady = 1 + iota
	workerConnecting
	workerVideoReceived
	workerStreaming
	workerSessionEnded
	workerError
	workerNotice
	workerPaused
)

func makeWorkerOptions(config Config, deviceID, keyPath string) (workerOptions, error) {
	options := workerOptions{
		Name: config.DeviceName, DeviceID: deviceID, KeyPath: keyPath,
		MaxFPS: uint32(config.MaxFPS), IdleTimeoutSeconds: uint32(config.IdleTimeoutSeconds),
		RequirePin: config.RequirePin, PreferNewest: config.PreferNewestConnection,
		HardwareDecode: config.HardwareDecode, AllowH265: config.H265,
		AudioEnabled: config.AudioEnabled,
	}
	switch config.Resolution {
	case Resolution720:
		options.Width, options.Height = 1280, 720
	case ResolutionAuto, Resolution1080:
		options.Width, options.Height = 1920, 1080
	case Resolution4K:
		options.Width, options.Height = 3840, 2160
	default:
		return workerOptions{}, errors.New("unsupported mirroring resolution")
	}
	if options.MaxFPS == 0 {
		options.MaxFPS = 60
	}
	if config.RequirePin {
		if len(config.PinCode) != 4 || strings.IndexFunc(config.PinCode, func(r rune) bool { return r < '0' || r > '9' }) >= 0 {
			return workerOptions{}, errors.New("the pairing code must contain four digits")
		}
		pin, err := strconv.ParseUint(config.PinCode, 10, 32)
		if err != nil {
			return workerOptions{}, fmt.Errorf("read pairing code: %w", err)
		}
		options.Pin = uint32(pin)
	}
	return options, options.validate()
}

func (o workerOptions) validate() error {
	if !utf8.ValidString(o.Name) || strings.TrimSpace(o.Name) == "" || len(o.Name) > maxReceiverNameBytes ||
		strings.IndexFunc(o.Name, func(r rune) bool { return r < 32 || r == 127 }) >= 0 {
		return errors.New("the receiver name must be printable text within the 50-byte discovery limit")
	}
	if !validReceiverDeviceID(o.DeviceID) {
		return errors.New("the receiver identity is invalid")
	}
	if !filepath.IsAbs(o.KeyPath) || strings.ContainsRune(o.KeyPath, 0) {
		return errors.New("the receiver key path must be an absolute local path")
	}
	if !((o.Width == 1280 && o.Height == 720) ||
		(o.Width == 1920 && o.Height == 1080) || (o.Width == 3840 && o.Height == 2160)) {
		return errors.New("the receiver resolution is invalid")
	}
	if o.MaxFPS == 0 || o.MaxFPS > 120 || o.IdleTimeoutSeconds > 3600 || o.Pin > 9999 {
		return errors.New("the receiver limits are invalid")
	}
	return nil
}

func decodeWorkerCommand(line []byte) (workerCommand, error) {
	var command workerCommand
	if !utf8.Valid(line) {
		return command, errors.New("invalid receiver command encoding")
	}
	decoder := json.NewDecoder(strings.NewReader(string(line)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&command); err != nil {
		return command, errors.New("invalid receiver command")
	}
	if decoder.Decode(new(any)) != io.EOF || command.Protocol != workerProtocolVersion {
		return command, errors.New("unsupported receiver command protocol")
	}
	switch command.Command {
	case "start":
		if command.Options == nil {
			return command, errors.New("receiver options are missing")
		}
		return command, command.Options.validate()
	case "stop", "show":
		if command.Options != nil {
			return command, errors.New("unexpected receiver command options")
		}
	default:
		return command, errors.New("unknown receiver command")
	}
	return command, nil
}

func decodeWorkerEvent(line string) (workerEvent, error) {
	var event workerEvent
	if !utf8.ValidString(line) || len(line) > maxReceiverLine {
		return event, errors.New("invalid receiver status encoding")
	}
	decoder := json.NewDecoder(strings.NewReader(line))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&event); err != nil {
		return event, errors.New("invalid receiver status message")
	}
	if decoder.Decode(new(any)) != io.EOF || event.Protocol != workerProtocolVersion ||
		event.Kind < workerReady || event.Kind > workerPaused || len(event.Message) > workerMessageLimit {
		return event, errors.New("unsupported receiver status message")
	}
	return event, nil
}

type nativeReceiverSession interface {
	Run() error
	Stop()
	Show()
	Close()
}

type nativeReceiverFactory func(workerOptions, func(int, string)) (nativeReceiverSession, error)

// The worker owns the native threads. Driver faults stay outside the control
// window, but both processes run the same installed executable.
func runReceiverWorker(input io.Reader, output io.Writer, factory nativeReceiverFactory) int {
	if closer, ok := input.(io.Closer); ok {
		defer closer.Close()
	}
	var outputMu sync.Mutex
	outputFailed := make(chan struct{}, 1)
	encoder := json.NewEncoder(output)
	emit := func(kind int, message string) {
		if kind < workerReady || kind > workerPaused {
			message = "The receiver returned an invalid status event."
			kind = workerError
		}
		if len(message) > workerMessageLimit {
			message = "The receiver returned an oversized diagnostic."
			kind = workerError
		}
		outputMu.Lock()
		err := encoder.Encode(workerEvent{Protocol: workerProtocolVersion, Kind: kind, Message: message})
		outputMu.Unlock()
		if err != nil {
			select {
			case outputFailed <- struct{}{}:
			default:
			}
		}
	}

	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 4096), maxReceiverLine)
	if !scanner.Scan() {
		emit(workerError, "The receiver did not receive its startup options.")
		return 1
	}
	command, err := decodeWorkerCommand(scanner.Bytes())
	if err != nil || command.Command != "start" {
		emit(workerError, "The receiver startup options are invalid.")
		return 1
	}
	session, err := factory(*command.Options, emit)
	if err != nil {
		emit(workerError, err.Error())
		return 1
	}
	if session == nil {
		emit(workerError, "The native receiver could not be created.")
		return 1
	}
	finished := make(chan error, 1)
	go func() { finished <- session.Run() }()
	type inputResult struct {
		command workerCommand
		err     error
	}
	commands := make(chan inputResult)
	stopReading := make(chan struct{})
	defer close(stopReading)
	go func() {
		defer close(commands)
		for scanner.Scan() {
			command, err := decodeWorkerCommand(scanner.Bytes())
			select {
			case commands <- inputResult{command, err}:
			case <-stopReading:
				return
			}
			if err != nil || command.Command == "stop" {
				return
			}
		}
		if err := scanner.Err(); err != nil {
			select {
			case commands <- inputResult{err: errors.New("the receiver control pipe could not be read")}:
			case <-stopReading:
			}
		}
	}()

	exitCode := 0
	var stopTimer *time.Timer
	var deadline <-chan time.Time
	requestStop := func() {
		if stopTimer == nil {
			session.Stop()
			stopTimer = time.NewTimer(workerShutdownDeadline)
			deadline = stopTimer.C
		}
	}
	defer func() {
		if stopTimer != nil {
			stopTimer.Stop()
		}
	}()
	for {
		select {
		case err := <-finished:
			session.Close()
			if err != nil {
				emit(workerError, err.Error())
				return 1
			}
			return exitCode
		case result, open := <-commands:
			if !open {
				commands = nil
				requestStop()
			} else if result.err != nil || result.command.Command == "start" {
				emit(workerError, "The receiver control command is invalid.")
				exitCode = 1
				requestStop()
			} else if result.command.Command == "stop" {
				requestStop()
			} else if stopTimer == nil {
				session.Show()
			}
		case <-outputFailed:
			exitCode = 1
			requestStop()
		case <-deadline:
			emit(workerError, "The native receiver did not shut down within its deadline.")
			// main exits the worker process. Do not free memory beneath threads
			// that did not stop; Windows releases the entire worker instead.
			return 1
		}
	}
}
