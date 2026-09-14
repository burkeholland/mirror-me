package main

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestVerboseLoggingLifecycleAndPrivacy(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "logs")
	logger := newVerboseLogger(dir, func(message string) { t.Errorf("unexpected warning: %s", message) })
	t.Cleanup(func() { _ = logger.Close() })
	config := DefaultConfig()
	config.DeviceName, config.PinCode = "private-name", "secret-pin"
	event := makeLogRecord("receiver_event", config, EngineSnapshot{
		Status: StatusMirroring, Backend: "native", VideoReceived: true,
		DeviceName: "private-phone", DeviceModel: "private-model", PinCode: "secret-pin", LastError: "raw-private-error",
	})
	logger.Log(event)
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatal("disabled logger created files")
	}
	if err := logger.SetEnabled(true); err != nil {
		t.Fatal(err)
	}
	logger.Log(event)
	if err := logger.SetEnabled(false); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, verboseLogFileName)
	first, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	logger.Log(event)
	if err := logger.Close(); err != nil {
		t.Fatal(err)
	}
	second, _ := os.ReadFile(path)
	if string(first) != string(second) || strings.Count(string(first), "\n") != 1 {
		t.Fatal("disable did not drain accepted entries or continued writing")
	}
	for _, secret := range []string{"private-name", "secret-pin", "private-phone", "private-model", "raw-private-error"} {
		if strings.Contains(string(first), secret) {
			t.Fatalf("log contains excluded text: %s", secret)
		}
	}
	var decoded logRecord
	if err := json.Unmarshal(first, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.Status != StatusMirroring || !decoded.VideoReceived || !decoded.Failure || decoded.Time == "" {
		t.Fatalf("missing structured fields: %+v", decoded)
	}
	if _, err := time.Parse(time.RFC3339Nano, decoded.Time); err != nil {
		t.Fatal(err)
	}
}

func TestVerboseLoggingRotationAndFailure(t *testing.T) {
	dir := t.TempDir()
	warnings := make(chan string, 4)
	logger := newVerboseLogger(dir, func(message string) { warnings <- message })
	logger.maxSize = 1024
	t.Cleanup(func() { _ = logger.Close() })
	if err := logger.SetEnabled(true); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 30; i++ {
		logger.Log(makeLogRecord("receiver_event", DefaultConfig(), EngineSnapshot{Status: StatusAdvertising}))
	}
	if err := logger.SetEnabled(false); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{verboseLogFileName, verboseLogFileName + ".1"} {
		data, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil || len(data) > 1024 {
			t.Fatalf("invalid rotated file %s: bytes=%d, err=%v", name, len(data), err)
		}
		scanner := bufio.NewScanner(strings.NewReader(string(data)))
		for scanner.Scan() {
			if !json.Valid(scanner.Bytes()) {
				t.Fatal("rotation split a JSON record")
			}
		}
	}
	backup := filepath.Join(dir, verboseLogFileName+".1")
	if err := os.Remove(backup); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(backup, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(backup, "block"), []byte("test"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := logger.SetEnabled(true); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 10; i++ {
		logger.Log(makeLogRecord("receiver_event", DefaultConfig(), EngineSnapshot{}))
	}
	select {
	case warning := <-warnings:
		if !strings.Contains(warning, "logging stopped") {
			t.Fatal(warning)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("rotation failure was not surfaced")
	}
}

func TestVerboseLoggingConcurrentControl(t *testing.T) {
	logger := newVerboseLogger(t.TempDir(), func(string) {})
	if err := logger.SetEnabled(true); err != nil {
		t.Fatal(err)
	}
	var producers sync.WaitGroup
	for i := 0; i < 4; i++ {
		producers.Add(1)
		go func() {
			defer producers.Done()
			for j := 0; j < 500; j++ {
				logger.Log(makeLogRecord("receiver_event", DefaultConfig(), EngineSnapshot{}))
			}
		}()
	}
	for i := 0; i < 5; i++ {
		if err := logger.SetEnabled(i%2 == 0); err != nil {
			t.Fatal(err)
		}
	}
	producers.Wait()
	if err := logger.Close(); err != nil {
		t.Fatal(err)
	}
	if err := logger.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestVerboseSettingPersistenceAndSaveFailure(t *testing.T) {
	dir := t.TempDir()
	config := DefaultConfig()
	if config.VerboseLogging {
		t.Fatal("logging must be off by default")
	}
	store := &ConfigStore{path: filepath.Join(dir, "settings.json")}
	app := &App{store: store, config: config}
	app.logger = newVerboseLogger(app.GetLogsFolder(), app.setLogWarning)
	t.Cleanup(func() { _ = app.logger.Close() })
	next := config
	next.VerboseLogging = true
	next.LogWarning = "transient"
	if configAffectsEngineArgs(config, next) {
		t.Fatal("logging must not restart the receiver")
	}
	if _, err := app.SaveSettings(next); err != nil {
		t.Fatal(err)
	}
	loaded, err := store.Load()
	if err != nil || !loaded.VerboseLogging || loaded.LogWarning != "" {
		t.Fatalf("incorrect saved settings: %+v, %v", loaded, err)
	}
	before := app.currentConfig()
	// A directory at settings.json forces an atomic-save failure.
	if err := os.Remove(store.path); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(store.path, 0o700); err != nil {
		t.Fatal(err)
	}
	next.VerboseLogging = false
	if _, err := app.SaveSettings(next); err == nil {
		t.Fatal("expected save failure")
	}
	if app.currentConfig() != before {
		t.Fatal("save failure changed active settings")
	}
	app.logger.mu.Lock()
	enabled := app.logger.enabled
	app.logger.mu.Unlock()
	if !enabled {
		t.Fatal("save failure did not restore logging mode")
	}
}

func TestVerboseEnableFailureIsVisible(t *testing.T) {
	dir := t.TempDir()
	blocked := filepath.Join(dir, "not-a-directory")
	if err := os.WriteFile(blocked, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	app := &App{store: &ConfigStore{path: filepath.Join(dir, "settings.json")}, config: DefaultConfig()}
	app.logger = newVerboseLogger(blocked, app.setLogWarning)
	t.Cleanup(func() { _ = app.logger.Close() })
	next := app.currentConfig()
	next.VerboseLogging = true
	if _, err := app.SaveSettings(next); err == nil {
		t.Fatal("expected log initialization failure")
	}
	if app.GetSettings().LogWarning == "" || app.GetSettings().VerboseLogging {
		t.Fatal("failed enable must warn without claiming logging is enabled")
	}
}
