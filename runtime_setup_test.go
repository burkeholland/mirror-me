package main

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func runtimeZIP(t *testing.T, names []string) []byte {
	t.Helper()
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	for _, name := range names {
		file, err := writer.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := file.Write([]byte("test runtime file")); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

func testRuntime(t *testing.T) (*runtimeInstaller, *atomic.Int32) {
	t.Helper()
	archive := runtimeZIP(t, []string{"libgstreamer-1.0-0.dll", "libcrypto-3-x64.dll",
		"dnssd.dll", "mDNSResponder.exe", "lib/gstreamer-1.0/libgstlibav.dll",
		"uxplay-windows.exe", "uxplay-bluetooth-beacon.exe", "LICENSE.rtf"})
	requests := &atomic.Int32{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		requests.Add(1)
		w.Write(archive)
	}))
	t.Cleanup(server.Close)
	root := t.TempDir()
	exe := filepath.Join(root, receiverExecutable)
	if err := os.WriteFile(exe, []byte("MirrorMe receiver"), 0o700); err != nil {
		t.Fatal(err)
	}
	r, err := newRuntimeInstaller(exe, root)
	if err != nil {
		t.Fatal(err)
	}
	r.spec.URL = server.URL
	r.spec.Size = int64(len(archive))
	r.spec.SHA256 = fmt.Sprintf("%x", sha256.Sum256(archive))
	r.verify = func(_ context.Context, directory string) error {
		if !runtimeFilesPresent(directory) {
			return fmt.Errorf("missing runtime")
		}
		return nil
	}
	return r, requests
}

func TestRuntimeInstallVerifiesAndCachesWithoutDesktopWrapper(t *testing.T) {
	r, requests := testRuntime(t)
	var progress []int
	directory, err := r.install(context.Background(), func(percent int) { progress = append(progress, percent) })
	if err != nil {
		t.Fatal(err)
	}
	if !r.ready() || len(progress) == 0 || progress[len(progress)-1] != 100 {
		t.Fatalf("installation or progress is incomplete: %v", progress)
	}
	for _, name := range []string{"uxplay-windows.exe", "uxplay-bluetooth-beacon.exe"} {
		if _, err := os.Stat(filepath.Join(directory, name)); !os.IsNotExist(err) {
			t.Fatalf("separate desktop app was installed: %s (%v)", name, err)
		}
	}
	if data, _ := os.ReadFile(filepath.Join(directory, receiverExecutable)); string(data) != "MirrorMe receiver" {
		t.Fatal("the downloaded archive replaced MirrorMe's own receiver")
	}
	if _, err := r.install(context.Background(), nil); err != nil || requests.Load() != 1 {
		t.Fatalf("cached install downloaded again: %v (%d requests)", err, requests.Load())
	}
}

func TestRuntimeRepairsAnIncompleteCache(t *testing.T) {
	r, requests := testRuntime(t)
	directory, err := r.install(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(directory, "dnssd.dll")); err != nil {
		t.Fatal(err)
	}
	if _, err := r.install(context.Background(), nil); err != nil || !r.ready() || requests.Load() != 2 {
		t.Fatalf("incomplete cache was not repaired: %v", err)
	}
}

func TestRuntimeRejectsChangedOrTruncatedDownloads(t *testing.T) {
	for _, kind := range []string{"hash", "size"} {
		t.Run(kind, func(t *testing.T) {
			r, _ := testRuntime(t)
			if kind == "hash" {
				r.spec.SHA256 = strings.Repeat("0", 64)
			} else {
				r.spec.Size++
			}
			if _, err := r.install(context.Background(), nil); err == nil || r.ready() {
				t.Fatal("an invalid archive was installed")
			}
			if _, err := os.Stat(r.target); !os.IsNotExist(err) {
				t.Fatalf("partial install left a usable-looking directory: %v", err)
			}
		})
	}
}

func TestRuntimeDoesNotPublishFailedDecoderChecks(t *testing.T) {
	r, _ := testRuntime(t)
	r.verify = func(context.Context, string) error { return fmt.Errorf("decoder failed") }
	if _, err := r.install(context.Background(), nil); err == nil || !strings.Contains(err.Error(), "decoder failed") || r.ready() {
		t.Fatalf("bad decoder install was accepted: %v", err)
	}
}

func TestRuntimeArchiveRejectsWindowsTraversalAndDuplicates(t *testing.T) {
	for _, names := range [][]string{
		{"../outside.dll"}, {`..\outside.dll`}, {"C:/outside.dll"},
		{"/absolute.dll"}, {"file.dll:stream"}, {"trimmed. /evil.dll"},
		{"file.dll", "FILE.DLL"},
	} {
		t.Run(names[0], func(t *testing.T) {
			root := t.TempDir()
			archive := filepath.Join(root, "archive.zip")
			if err := os.WriteFile(archive, runtimeZIP(t, names), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := extractRuntime(context.Background(), archive, filepath.Join(root, "output")); err == nil {
				t.Fatal("unsafe archive path was accepted")
			}
		})
	}
}

func TestRuntimeDownloadCanBeCancelled(t *testing.T) {
	r, _ := testRuntime(t)
	started := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		w.Header().Set("Content-Length", fmt.Sprint(r.spec.Size))
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		close(started)
		<-request.Context().Done()
	}))
	defer server.Close()
	r.spec.URL = server.URL
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := r.install(ctx, nil); done <- err }()
	<-started
	cancel()
	select {
	case err := <-done:
		if err == nil || r.ready() {
			t.Fatal("cancelled download was installed")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("download did not stop promptly")
	}
}

func TestMissingRuntimeRequiresExplicitDownloadBeforeBonjour(t *testing.T) {
	r, _ := testRuntime(t)
	e := &Engine{runtime: r, engineDir: filepath.Dir(r.sourceExe), status: StatusStopped}
	e.checkBonjour = func() (bool, error) { t.Error("Bonjour checked before runtime consent"); return true, nil }
	if err := e.Start(DefaultConfig()); err != nil {
		t.Fatal(err)
	}
	if snapshot := e.Snapshot(); snapshot.Status != StatusNeedsSetup || snapshot.SetupKind != "runtime" {
		t.Fatalf("runtime setup was not explained: %+v", snapshot)
	}
}

func TestRuntimeOfficialDownloadAndDecoder(t *testing.T) {
	if os.Getenv("MIRRORME_RUNTIME_TEST") != "1" {
		t.Skip("set MIRRORME_RUNTIME_TEST=1 to download and validate the pinned upstream runtime")
	}
	_, executable, err := locateEngine()
	if err != nil {
		t.Fatal(err)
	}
	r, err := newRuntimeInstaller(executable, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Minute)
	defer cancel()
	directory, err := r.install(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !r.ready() {
		t.Fatal("verified runtime is not ready")
	}
	t.Logf("Pinned upstream runtime downloaded, hashed, safely extracted, and decoded generated video: %s", directory)
}
