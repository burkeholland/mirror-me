package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDefaultConfigIsValid(t *testing.T) {
	def := DefaultConfig()
	normalized, err := NormalizeConfig(def, def)
	if err != nil {
		t.Fatalf("NormalizeConfig returned error for default config: %v", err)
	}
	if normalized != def {
		t.Fatalf("default config was not stable under normalization:\n got: %+v\nwant: %+v", normalized, def)
	}
}

func TestConfigStoreSaveLoadRoundTrip(t *testing.T) {
	dir := t.TempDir()
	store := &ConfigStore{path: filepath.Join(dir, "settings.json")}

	original := DefaultConfig()
	original.DeviceName = "Living Room PC"
	original.Resolution = Resolution1080
	original.MaxFPS = 60
	original.RequirePin = true
	original.PinCode = "1234"

	if err := store.Save(original); err != nil {
		t.Fatalf("Save failed: %v", err)
	}

	loaded, err := store.Load()
	if err != nil {
		t.Fatalf("Load failed: %v", err)
	}
	if loaded.DeviceName != original.DeviceName {
		t.Errorf("DeviceName = %q, want %q", loaded.DeviceName, original.DeviceName)
	}
	if loaded.Resolution != original.Resolution {
		t.Errorf("Resolution = %q, want %q", loaded.Resolution, original.Resolution)
	}
	if loaded.MaxFPS != original.MaxFPS {
		t.Errorf("MaxFPS = %d, want %d", loaded.MaxFPS, original.MaxFPS)
	}
	if loaded.PinCode != original.PinCode {
		t.Errorf("PinCode = %q, want %q", loaded.PinCode, original.PinCode)
	}
}

func TestConfigStoreLoadMissingFileReturnsDefaults(t *testing.T) {
	dir := t.TempDir()
	store := &ConfigStore{path: filepath.Join(dir, "does-not-exist.json")}

	loaded, err := store.Load()
	if err != nil {
		t.Fatalf("Load on missing file should not error, got: %v", err)
	}
	if loaded.DeviceName == "" {
		t.Errorf("expected default device name, got empty string")
	}
}

func TestConfigStoreLoadCorruptFileFallsBackToDefaults(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "settings.json")
	store := &ConfigStore{path: path}

	if err := os.WriteFile(path, []byte("{not valid json"), 0o644); err != nil {
		t.Fatalf("failed to seed corrupt file: %v", err)
	}

	loaded, err := store.Load()
	if err == nil {
		t.Fatalf("expected an error describing the corrupt file, got nil")
	}
	if loaded != DefaultConfig() {
		t.Errorf("expected defaults on corrupt file, got: %+v", loaded)
	}
}

func TestConfigStoreSaveIsAtomic(t *testing.T) {
	dir := t.TempDir()
	store := &ConfigStore{path: filepath.Join(dir, "settings.json")}

	if err := store.Save(DefaultConfig()); err != nil {
		t.Fatalf("Save failed: %v", err)
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("failed to list dir: %v", err)
	}
	for _, e := range entries {
		if filepath.Ext(e.Name()) == ".tmp" {
			t.Errorf("temp file left behind after successful save: %s", e.Name())
		}
	}
}
