package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"
)

const (
	verboseLogMaxBytes = 1 << 20
	verboseLogFileName = "verbose.jsonl"
)

// Only explicit fields are recorded, never raw events, device names, PINs,
// protocol payloads, error text or worker stdout/stderr.
type logRecord struct {
	Time          string       `json:"time"`
	Event         string       `json:"event"`
	Version       string       `json:"version"`
	Status        EngineStatus `json:"status"`
	Backend       string       `json:"backend"`
	VideoReceived bool         `json:"videoReceived"`
	Failure       bool         `json:"failure"`
	Resolution    string       `json:"resolution"`
	MaxFPS        int          `json:"maxFps"`
	AudioEnabled  bool         `json:"audioEnabled"`
	H265          bool         `json:"h265"`
}

func makeLogRecord(event string, config Config, snapshot EngineSnapshot) logRecord {
	return logRecord{
		Time: time.Now().UTC().Format(time.RFC3339Nano), Event: event, Version: applicationVersion(),
		Status: snapshot.Status, Backend: snapshot.Backend, VideoReceived: snapshot.VideoReceived,
		Failure:    snapshot.LastError != "" || snapshot.Status == StatusError,
		Resolution: config.Resolution, MaxFPS: config.MaxFPS, AudioEnabled: config.AudioEnabled, H265: config.H265,
	}
}

type logRequest struct {
	record *logRecord
	enable bool
	close  bool
	result chan error
}

type VerboseLogger struct {
	dir     string
	warn    func(string)
	mu      sync.Mutex
	control sync.Mutex
	enabled bool
	closed  bool
	dropped atomic.Bool
	queue   chan logRequest
	done    chan struct{}
	maxSize int64
}

func newVerboseLogger(dir string, warn func(string)) *VerboseLogger {
	logger := &VerboseLogger{
		dir: dir, warn: warn, queue: make(chan logRequest, 128),
		done: make(chan struct{}), maxSize: verboseLogMaxBytes,
	}
	go logger.run()
	return logger
}

// The writer never holds mu during I/O: receiver events cannot wait on disk.
func (l *VerboseLogger) Log(record logRecord) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if !l.enabled || l.closed {
		return
	}
	select {
	case l.queue <- logRequest{record: &record}:
	default:
		l.dropped.Store(true)
	}
}

func (l *VerboseLogger) SetEnabled(enabled bool) error {
	l.control.Lock()
	defer l.control.Unlock()
	return l.configure(enabled, false)
}

func (l *VerboseLogger) configure(enabled, closeLogger bool) error {
	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		if closeLogger {
			return nil
		}
		return errors.New("verbose logger is closed")
	}
	l.enabled = false
	l.closed = closeLogger
	l.mu.Unlock()
	result := make(chan error, 1)
	l.queue <- logRequest{enable: enabled, close: closeLogger, result: result}
	err := <-result
	l.mu.Lock()
	l.enabled = enabled && err == nil
	l.mu.Unlock()
	return err
}

func (l *VerboseLogger) Close() error {
	l.control.Lock()
	defer l.control.Unlock()
	err := l.configure(false, true)
	<-l.done
	return err
}

func (l *VerboseLogger) warning(message string) {
	if l.warn != nil {
		l.warn(message)
	}
}

func (l *VerboseLogger) run() {
	defer close(l.done)
	var file *os.File
	var size int64
	current := filepath.Join(l.dir, verboseLogFileName)
	closeFile := func() error {
		if file == nil {
			return nil
		}
		err := file.Close()
		file = nil
		return err
	}
	openFile := func() error {
		if err := os.MkdirAll(l.dir, 0o700); err != nil {
			return err
		}
		f, err := os.OpenFile(current, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
		if err != nil {
			return err
		}
		info, err := f.Stat()
		if err != nil {
			return errors.Join(err, f.Close())
		}
		file, size = f, info.Size()
		return nil
	}
	for request := range l.queue {
		if l.dropped.Swap(false) {
			l.warning("Verbose logging skipped entries because its queue was full.")
		}
		if request.result != nil {
			var err error
			if request.enable && file == nil {
				err = openFile()
			} else if !request.enable {
				err = closeFile()
			}
			request.result <- err
			if request.close {
				return
			}
			continue
		}
		if file == nil {
			continue
		}
		data, err := json.Marshal(request.record)
		data = append(data, '\n')
		if err == nil && int64(len(data)) > l.maxSize {
			err = errors.New("log entry exceeds the file size limit")
		}
		if err == nil && size+int64(len(data)) > l.maxSize {
			err = closeFile()
			backup := current + ".1"
			if err == nil {
				if removeErr := os.Remove(backup); removeErr != nil && !errors.Is(removeErr, os.ErrNotExist) {
					err = removeErr
				}
			}
			if err == nil {
				err = os.Rename(current, backup)
			}
			if err == nil {
				err = openFile()
			}
		}
		if err == nil {
			var written int
			written, err = file.Write(data)
			size += int64(written)
			if err == nil && written != len(data) {
				err = io.ErrShortWrite
			}
		}
		if err != nil {
			err = errors.Join(err, closeFile())
			l.mu.Lock()
			l.enabled = false
			l.mu.Unlock()
			l.warning(fmt.Sprintf("Verbose logging stopped: %v. Turn it off and on in Settings to retry.", err))
		}
	}
}
