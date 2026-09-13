package main

import (
	"archive/zip"
	"context"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

//go:embed receiver/runtime.json
var runtimeManifest []byte

type runtimeSpec struct {
	Version string `json:"version"`
	URL     string `json:"url"`
	SHA256  string `json:"sha256"`
	Size    int64  `json:"size"`
}

type runtimeInstaller struct {
	spec      runtimeSpec
	sourceExe string
	target    string
	client    *http.Client
	verify    func(context.Context, string) error
}

func newRuntimeInstaller(sourceExe, cacheDir string) (*runtimeInstaller, error) {
	var spec runtimeSpec
	if err := json.Unmarshal(runtimeManifest, &spec); err != nil {
		return nil, fmt.Errorf("read receiver download manifest: %w", err)
	}
	hash, err := fileSHA256(sourceExe)
	if err != nil {
		return nil, fmt.Errorf("identify bundled receiver: %w", err)
	}
	return &runtimeInstaller{
		spec: spec, sourceExe: sourceExe,
		target: filepath.Join(cacheDir, "runtime-"+spec.SHA256[:12]+"-"+hash[:12]),
		client: &http.Client{Timeout: 5 * time.Minute},
		verify: verifyRuntime,
	}, nil
}

func runtimeFilesPresent(dir string) bool {
	for _, name := range []string{receiverExecutable, "libgstreamer-1.0-0.dll",
		"libcrypto-3-x64.dll", "dnssd.dll", "mDNSResponder.exe",
		filepath.Join("lib", "gstreamer-1.0", "libgstlibav.dll")} {
		info, err := os.Stat(filepath.Join(dir, name))
		if err != nil || !info.Mode().IsRegular() || info.Size() == 0 {
			return false
		}
	}
	return true
}

func (r *runtimeInstaller) ready() bool {
	receipt, err := os.ReadFile(filepath.Join(r.target, ".verified-runtime"))
	return err == nil && string(receipt) == r.spec.SHA256 && runtimeFilesPresent(r.target)
}

func fileSHA256(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

type downloadProgress struct {
	written, size int64
	last          int
	report        func(int)
}

func (p *downloadProgress) Write(data []byte) (int, error) {
	p.written += int64(len(data))
	percent := int(min(p.written*100/p.size, 100))
	if p.report != nil && percent != p.last {
		p.last = percent
		p.report(percent)
	}
	return len(data), nil
}

func (r *runtimeInstaller) install(ctx context.Context, report func(int)) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if r.ready() {
		return r.target, nil
	}
	root := filepath.Dir(r.target)
	if err := os.MkdirAll(root, 0o700); err != nil {
		return "", fmt.Errorf("create receiver cache: %w", err)
	}
	staging, err := os.MkdirTemp(root, "runtime-download-")
	if err != nil {
		return "", err
	}
	cleanup := true
	defer func() {
		if cleanup {
			os.RemoveAll(staging)
		}
	}()
	archive := filepath.Join(staging, "runtime.zip")
	if err := r.download(ctx, archive, report); err != nil {
		return "", err
	}
	extracted := filepath.Join(staging, "engine")
	if err := extractRuntime(ctx, archive, extracted); err != nil {
		return "", fmt.Errorf("unpack receiver files: %w", err)
	}
	if err := copyRuntimeFile(r.sourceExe, filepath.Join(extracted, receiverExecutable)); err != nil {
		return "", fmt.Errorf("stage MirrorMe receiver: %w", err)
	}
	if err := r.verify(ctx, extracted); err != nil {
		return "", err
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(extracted, ".verified-runtime"), []byte(r.spec.SHA256), 0o600); err != nil {
		return "", err
	}
	// Keep a damaged previous install until its verified replacement is ready.
	backup := filepath.Join(staging, "previous")
	if err := os.Rename(r.target, backup); err != nil && !os.IsNotExist(err) {
		return "", fmt.Errorf("replace cached receiver (quit other MirrorMe windows first): %w", err)
	}
	if err := os.Rename(extracted, r.target); err != nil {
		restoreErr := os.Rename(backup, r.target)
		if os.IsNotExist(restoreErr) {
			restoreErr = nil
		}
		if restoreErr != nil {
			cleanup = false
			restoreErr = fmt.Errorf("previous receiver files were retained at %s: %w", backup, restoreErr)
		}
		return "", errors.Join(fmt.Errorf("finish receiver installation: %w", err), restoreErr)
	}
	return r.target, nil
}

func (r *runtimeInstaller) download(ctx context.Context, destination string, report func(int)) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, r.spec.URL, nil)
	if err != nil {
		return err
	}
	request.Header.Set("User-Agent", "MirrorMe receiver setup")
	response, err := r.client.Do(request)
	if err != nil {
		return fmt.Errorf("download receiver files from GitHub: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("GitHub returned %s while downloading receiver files; try again later", response.Status)
	}
	if response.ContentLength > 0 && response.ContentLength != r.spec.Size {
		return errors.New("the receiver download has an unexpected size; no files were installed")
	}
	output, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	hash := sha256.New()
	progress := &downloadProgress{size: r.spec.Size, last: -1, report: report}
	n, copyErr := io.Copy(io.MultiWriter(output, hash, progress), io.LimitReader(response.Body, r.spec.Size+1))
	closeErr := output.Close()
	if err := errors.Join(copyErr, closeErr); err != nil {
		return fmt.Errorf("save receiver download: %w", err)
	}
	if n != r.spec.Size || hex.EncodeToString(hash.Sum(nil)) != r.spec.SHA256 {
		return errors.New("receiver download verification failed; no files were installed. Try downloading again")
	}
	return nil
}

func extractRuntime(ctx context.Context, archive, destination string) error {
	reader, err := zip.OpenReader(archive)
	if err != nil {
		return err
	}
	defer reader.Close()
	var total uint64
	seen := make(map[string]bool)
	for _, entry := range reader.File {
		if err := ctx.Err(); err != nil {
			return err
		}
		name := strings.ReplaceAll(entry.Name, "\\", "/")
		parts := strings.Split(name, "/")
		for _, part := range parts {
			if part == ".." || strings.Contains(part, ":") || strings.HasSuffix(part, ".") || strings.HasSuffix(part, " ") {
				return fmt.Errorf("unsafe archive path %q", entry.Name)
			}
		}
		if strings.HasPrefix(name, "/") || entry.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("unsafe archive entry %q", entry.Name)
		}
		key := strings.ToLower(name)
		if seen[key] {
			return fmt.Errorf("duplicate archive path %q", entry.Name)
		}
		seen[key] = true
		if entry.FileInfo().IsDir() {
			continue
		}
		base := strings.ToLower(filepath.Base(filepath.FromSlash(name)))
		// Never install or run the separate desktop app, its tray, or its beacon.
		if strings.HasPrefix(base, "uxplay-") || base == "compile_commands.json" {
			continue
		}
		total += entry.UncompressedSize64
		if total > 768<<20 || entry.UncompressedSize64 > 256<<20 {
			return errors.New("receiver archive exceeds its extraction limit")
		}
		path := filepath.Join(destination, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			return err
		}
		if err := extractRuntimeFile(entry, path); err != nil {
			return err
		}
	}
	return nil
}

func extractRuntimeFile(entry *zip.File, path string) error {
	input, err := entry.Open()
	if err != nil {
		return err
	}
	defer input.Close()
	output, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(output, io.LimitReader(input, int64(entry.UncompressedSize64)+1))
	return errors.Join(copyErr, output.Close())
}

func copyRuntimeFile(source, destination string) error {
	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer input.Close()
	output, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o700)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(output, input)
	return errors.Join(copyErr, output.Close())
}

func verifyRuntime(ctx context.Context, directory string) error {
	if !runtimeFilesPresent(directory) {
		return errors.New("the downloaded archive is missing required receiver files")
	}
	for _, mode := range []string{"--self-test", "--media-self-test"} {
		probeCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
		command := exec.CommandContext(probeCtx, filepath.Join(directory, receiverExecutable), mode)
		command.Dir = directory
		command.Env = receiverEnvironment(directory, directory)
		command.Env = append(command.Env, "PATH="+directory+";"+filepath.Join(os.Getenv("WINDIR"), "System32"))
		configureCommand(command)
		last := ""
		expected := "MIRRORME_RECEIVER_SELF_TEST_OK"
		if mode == "--media-self-test" {
			expected = "MIRRORME_MEDIA_TEST_OK"
		}
		confirmed := false
		output := &receiverOutput{onLine: func(line string) {
			last = line
			confirmed = confirmed || strings.HasPrefix(line, expected)
		}}
		command.Stdout, command.Stderr = output, output
		err := command.Run()
		output.flush()
		cancel()
		if err != nil {
			return fmt.Errorf("the installed receiver did not pass its %s check: %w. %s", mode, err, last)
		}
		if !confirmed {
			return fmt.Errorf("the receiver exited without confirming its %s check", mode)
		}
	}
	return nil
}
