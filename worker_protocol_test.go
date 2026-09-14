package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

func testWorkerOptions(t *testing.T) workerOptions {
	t.Helper()
	options, err := makeWorkerOptions(DefaultConfig(), "02:12:34:56:78:90", filepath.Join(t.TempDir(), "pairing.key"))
	if err != nil {
		t.Fatal(err)
	}
	return options
}

func encodeWorkerCommand(t *testing.T, command string, options *workerOptions) string {
	t.Helper()
	data, err := json.Marshal(workerCommand{Protocol: workerProtocolVersion, Command: command, Options: options})
	if err != nil {
		t.Fatal(err)
	}
	return string(data) + "\n"
}

func TestWorkerAutomaticSettingsResolveBeforeNativeBoundary(t *testing.T) {
	config := DefaultConfig()
	options, err := makeWorkerOptions(config, "02:12:34:56:78:90", filepath.Join(t.TempDir(), "key"))
	if err != nil {
		t.Fatal(err)
	}
	if options.Width != 1920 || options.Height != 1080 || options.MaxFPS != 60 {
		t.Fatalf("automatic settings did not resolve to usable native limits: %+v", options)
	}
	if config.Resolution != ResolutionAuto || config.MaxFPS != 0 {
		t.Fatal("resolving receiver limits changed the user's automatic settings")
	}
}

func TestWorkerOptionsKeepAllReceiverSettingsAndZeroPIN(t *testing.T) {
	config := DefaultConfig()
	config.RequirePin, config.PinCode = true, "0000"
	config.Resolution, config.MaxFPS = Resolution4K, 60
	config.AudioEnabled, config.HardwareDecode = false, false
	config.H265, config.PreferNewestConnection = true, false
	config.IdleTimeoutSeconds = 0
	options, err := makeWorkerOptions(config, "02:12:34:56:78:90", filepath.Join(t.TempDir(), "key"))
	if err != nil {
		t.Fatal(err)
	}
	if !options.RequirePin || options.Pin != 0 || options.Width != 3840 || options.Height != 2160 ||
		options.MaxFPS != 60 || options.AudioEnabled || options.HardwareDecode || !options.AllowH265 ||
		options.PreferNewest || options.IdleTimeoutSeconds != 0 {
		t.Fatalf("receiver settings changed in transit: %+v", options)
	}
}

func TestWorkerOptionsRejectInvalidInput(t *testing.T) {
	valid := testWorkerOptions(t)
	for _, change := range []func(*workerOptions){
		func(o *workerOptions) { o.Name = "   " },
		func(o *workerOptions) { o.Name = "PC\x00name" },
		func(o *workerOptions) { o.Name = strings.Repeat("a", maxReceiverNameBytes+1) },
		func(o *workerOptions) { o.Name = strings.Repeat("\u754c", 17) },
		func(o *workerOptions) { o.DeviceID = "not-a-device" },
		func(o *workerOptions) { o.KeyPath = "relative.key" },
		func(o *workerOptions) { o.MaxFPS = 0xffffffff },
		func(o *workerOptions) { o.MaxFPS = 0 },
		func(o *workerOptions) { o.IdleTimeoutSeconds = 0xffffffff },
		func(o *workerOptions) { o.Width, o.Height = 1, 1 },
		func(o *workerOptions) { o.Width, o.Height = 0, 0 },
		func(o *workerOptions) { o.Pin = 10000 },
	} {
		options := valid
		change(&options)
		if options.validate() == nil {
			t.Fatal("invalid native options were accepted")
		}
	}
}

func TestWorkerStatusIsTypedAndVersioned(t *testing.T) {
	event, err := decodeWorkerEvent(`{"protocol":1,"kind":4}`)
	if err != nil || event.Kind != workerStreaming {
		t.Fatalf("valid frame event was rejected: %+v, %v", event, err)
	}
	if workerProtocolVersion != 1 || workerPaused != 8 {
		t.Fatal("pause changed the existing native protocol numbering")
	}
	event, err = decodeWorkerEvent(`{"protocol":1,"kind":8,"message":"Mirroring paused."}`)
	if err != nil || event.Kind != workerPaused || event.Message != "Mirroring paused." {
		t.Fatalf("valid pause event was rejected: %+v, %v", event, err)
	}
	for _, line := range []string{
		"MIRRORME_STREAMING",
		`{"protocol":2,"kind":4}`,
		`{"protocol":1,"kind":99}`,
		`{"protocol":1,"kind":9}`,
		`{"protocol":1,"kind":0}`,
		`{"protocol":1,"kind":-1}`,
		`{"protocol":1,"kind":4,"unknown":"ignored?"}`,
		`{"protocol":1,"kind":4} {"kind":6}`,
		`{"protocol":1,"kind":4,"message":"` + strings.Repeat("x", 4097) + `"}`,
	} {
		if _, err := decodeWorkerEvent(line); err == nil {
			t.Fatalf("non-protocol output claimed a state: %q", line[:min(len(line), 100)])
		}
	}
}

func TestWorkerEmitterPreservesPauseAndRejectsUnknownKinds(t *testing.T) {
	options := testWorkerOptions(t)
	for _, kind := range []int{workerReady, workerConnecting, workerVideoReceived, workerStreaming,
		workerSessionEnded, workerError, workerNotice, workerPaused, -1, 0, workerPaused + 1, 99} {
		var output bytes.Buffer
		session := &testNativeSession{stop: make(chan struct{}), emit: func(int, string) {}}
		code := runReceiverWorker(strings.NewReader(encodeWorkerCommand(t, "start", &options)), &output,
			func(_ workerOptions, emit func(int, string)) (nativeReceiverSession, error) {
				emit(kind, "Native diagnostic.")
				return session, nil
			})
		if code != 0 || !session.closed.Load() {
			t.Fatal("worker did not close cleanly after its input ended")
		}
		event, err := decodeWorkerEvent(strings.TrimSpace(output.String()))
		if err != nil {
			t.Fatalf("emitter returned an invalid event for kind %d: %v", kind, err)
		}
		if kind < workerReady || kind > workerPaused {
			if event.Kind != workerError || !strings.Contains(event.Message, "invalid status") {
				t.Fatalf("unknown kind %d was not rejected: %+v", kind, event)
			}
		} else if event.Kind != kind || event.Message != "Native diagnostic." {
			t.Fatalf("valid event kind %d changed in transit: %+v", kind, event)
		}
	}
}

type testNativeSession struct {
	emit       func(int, string)
	stop       chan struct{}
	stopOnce   sync.Once
	closed     atomic.Bool
	runExited  atomic.Bool
	showCount  atomic.Int32
	result     error
	closeEarly atomic.Bool
}

func (s *testNativeSession) Run() error {
	s.emit(workerReady, "")
	if s.result == nil {
		<-s.stop
	}
	s.runExited.Store(true)
	return s.result
}
func (s *testNativeSession) Stop() { s.stopOnce.Do(func() { close(s.stop) }) }
func (s *testNativeSession) Show() { s.showCount.Add(1) }
func (s *testNativeSession) Close() {
	s.closeEarly.Store(!s.runExited.Load())
	s.closed.Store(true)
}

func TestWorkerCommandsAndEOFAreDeterministic(t *testing.T) {
	for _, stopCommand := range []bool{true, false} {
		t.Run(map[bool]string{true: "stop", false: "eof"}[stopCommand], func(t *testing.T) {
			options := testWorkerOptions(t)
			input := encodeWorkerCommand(t, "start", &options) + encodeWorkerCommand(t, "show", nil)
			if stopCommand {
				input += encodeWorkerCommand(t, "stop", nil)
			}
			var output bytes.Buffer
			session := &testNativeSession{stop: make(chan struct{})}
			code := runReceiverWorker(strings.NewReader(input), &output, func(got workerOptions, emit func(int, string)) (nativeReceiverSession, error) {
				if got != options {
					t.Error("worker options did not round trip")
				}
				session.emit = emit
				return session, nil
			})
			if code != 0 || !session.closed.Load() || session.closeEarly.Load() || session.showCount.Load() != 1 {
				t.Fatalf("worker lifecycle failed: code=%d, closed=%v, early=%v, shows=%d", code, session.closed.Load(), session.closeEarly.Load(), session.showCount.Load())
			}
			if _, err := decodeWorkerEvent(strings.TrimSpace(output.String())); err != nil {
				t.Fatalf("worker emitted an unstructured event: %s", output.String())
			}
		})
	}
}

func TestWorkerRejectsBadStartupWithoutCreatingNativeResources(t *testing.T) {
	for _, input := range []string{"", "not json\n", `{"protocol":1,"command":"start"}` + "\n",
		`{"protocol":1,"command":"stop"}` + "\n", strings.Repeat("x", maxReceiverLine+1)} {
		var output bytes.Buffer
		code := runReceiverWorker(strings.NewReader(input), &output, func(workerOptions, func(int, string)) (nativeReceiverSession, error) {
			t.Fatal("native receiver started before command validation")
			return nil, nil
		})
		if code == 0 {
			t.Fatal("invalid startup reported success")
		}
		event, err := decodeWorkerEvent(strings.TrimSpace(output.String()))
		if err != nil || event.Kind != workerError {
			t.Fatal("invalid startup did not produce an actionable error")
		}
	}
}

func TestWorkerRejectsMalformedCommandsAndStops(t *testing.T) {
	options := testWorkerOptions(t)
	for _, command := range []string{"bad command\n", strings.Repeat("x", maxReceiverLine+1),
		encodeWorkerCommand(t, "start", &options)} {
		session := &testNativeSession{stop: make(chan struct{})}
		var output bytes.Buffer
		code := runReceiverWorker(strings.NewReader(encodeWorkerCommand(t, "start", &options)+command), &output,
			func(workerOptions, func(int, string)) (nativeReceiverSession, error) {
				session.emit = func(int, string) {}
				return session, nil
			})
		if code == 0 || !session.closed.Load() || session.closeEarly.Load() {
			t.Fatal("invalid command left native resources running or freed them prematurely")
		}
	}
}

type failingWorkerOutput struct{}

func (failingWorkerOutput) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }

func TestWorkerStopsWhenControlAppClosesItsOutputPipe(t *testing.T) {
	options := testWorkerOptions(t)
	reader, writer := io.Pipe()
	defer writer.Close()
	go func() {
		_, _ = io.WriteString(writer, encodeWorkerCommand(t, "start", &options))
	}()
	session := &testNativeSession{stop: make(chan struct{})}
	code := runReceiverWorker(reader, failingWorkerOutput{}, func(_ workerOptions, emit func(int, string)) (nativeReceiverSession, error) {
		session.emit = emit
		return session, nil
	})
	if code == 0 || !session.closed.Load() || session.closeEarly.Load() {
		t.Fatal("the receiver survived loss of its controlling process")
	}
}

func TestWorkerCreationAndRunErrorsAreVisible(t *testing.T) {
	options := testWorkerOptions(t)
	for _, failCreate := range []bool{true, false} {
		var output bytes.Buffer
		session := &testNativeSession{stop: make(chan struct{}), result: errors.New("native media failed")}
		code := runReceiverWorker(strings.NewReader(encodeWorkerCommand(t, "start", &options)), &output,
			func(_ workerOptions, emit func(int, string)) (nativeReceiverSession, error) {
				if failCreate {
					return nil, errors.New("native media failed")
				}
				session.emit = emit
				return session, nil
			})
		if code == 0 || !strings.Contains(output.String(), "native media failed") {
			t.Fatal("the native failure was hidden")
		}
	}
}

func TestReceiverIdentityPersistsAndRejectsCorruption(t *testing.T) {
	directory := t.TempDir()
	first, key, err := receiverIdentity(directory)
	if err != nil || !validReceiverDeviceID(first) || !filepath.IsAbs(key) {
		t.Fatalf("could not create identity: %v", err)
	}

	second, secondKey, err := receiverIdentity(directory)
	if err != nil || first != second || key != secondKey {
		t.Fatal("reopening the receiver changed its pairing identity")
	}
	if err := os.WriteFile(filepath.Join(directory, "device-id"), []byte("corrupt"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := receiverIdentity(directory); err == nil {
		t.Fatal("a corrupt identity was silently replaced")
	}
}

func TestConcurrentReceiverIdentityCreationHasOneWinner(t *testing.T) {
	directory := t.TempDir()
	const readers = 16
	type result struct {
		id  string
		err error
	}
	results := make(chan result, readers)
	for index := 0; index < readers; index++ {
		go func() {
			id, _, err := receiverIdentity(directory)
			results <- result{id, err}
		}()
	}
	first := ""
	for index := 0; index < readers; index++ {
		result := <-results
		if result.err != nil {
			t.Error(result.err)
			continue
		}
		if first == "" {
			first = result.id
		}
		if result.id != first {
			t.Error("concurrent starts received different pairing identities")
		}
	}
	entries, err := os.ReadDir(directory)
	if err != nil || len(entries) != 1 || entries[0].Name() != "device-id" {
		t.Fatalf("temporary identity files were left behind: %v, %v", entries, err)
	}
}

func TestReceiverIdentityRejectsOversizedFile(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "device-id")
	if err := os.WriteFile(path, []byte("02:12:34:56:78:90"+strings.Repeat(" ", 128)), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := receiverIdentity(directory); err == nil {
		t.Fatal("accepted an oversized identity file")
	}
}
