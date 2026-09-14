//go:build windows

package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func executableRuntimeImports(binary string) ([]string, error) {
	// debug/pe.ImportedLibraries is unimplemented in Go 1.25. Inspect the
	// actual DLL table with the same binutils toolchain used by the build.
	command := exec.Command("objdump", "-p", binary)
	configureCommand(command)
	output, err := command.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("inspect executable imports (binutils objdump is required): %w: %s", err, output)
	}
	var libraries []string
	for _, line := range strings.Split(string(output), "\n") {
		if library, ok := strings.CutPrefix(strings.TrimSpace(line), "DLL Name:"); ok {
			library = strings.TrimSpace(library)
			if library == "" {
				return nil, fmt.Errorf("executable contains an empty DLL import")
			}
			libraries = append(libraries, library)
		}
	}
	if len(libraries) == 0 {
		return nil, fmt.Errorf("no DLL imports were found; refusing an empty audit")
	}
	return libraries, nil
}

func TestRuntimeImportAuditReadsRealExecutable(t *testing.T) {
	if !nativeReceiverAvailable {
		t.Skip("the real import audit runs with the native Windows build and binutils")
	}
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	libraries, err := executableRuntimeImports(binary)
	if err != nil {
		t.Fatal(err)
	}
	for _, library := range libraries {
		if strings.EqualFold(library, "kernel32.dll") {
			return
		}
	}
	t.Fatal("the import audit did not observe the executable's Windows imports")
}

func systemRuntimeImport(name string) bool {
	name = strings.ToLower(name)
	if strings.HasPrefix(name, "api-ms-win-") || strings.HasPrefix(name, "ext-ms-win-") {
		return strings.HasSuffix(name, ".dll")
	}
	switch name {
	case "kernel32.dll", "kernelbase.dll", "ntdll.dll", "advapi32.dll", "user32.dll",
		"gdi32.dll", "shell32.dll", "shlwapi.dll", "shcore.dll", "dwmapi.dll", "comctl32.dll",
		"comdlg32.dll", "ole32.dll", "oleaut32.dll", "uuid.dll", "rpcrt4.dll", "propsys.dll",
		"msvcrt.dll", "ucrtbase.dll", "msvcp_win.dll", "ws2_32.dll", "mswsock.dll",
		"dnsapi.dll", "iphlpapi.dll", "secur32.dll", "sspicli.dll", "crypt32.dll",
		"cryptbase.dll", "cryptsp.dll", "bcrypt.dll", "bcryptprimitives.dll", "ncrypt.dll",
		"wintrust.dll", "winmm.dll", "avrt.dll", "mf.dll", "mfplat.dll", "mfreadwrite.dll",
		"mfuuid.dll", "d3d11.dll", "dxgi.dll", "d3dcompiler_47.dll", "dwrite.dll",
		"windowscodecs.dll", "version.dll", "imm32.dll", "winhttp.dll", "uxtheme.dll",
		"powrprof.dll", "wtsapi32.dll", "setupapi.dll", "cfgmgr32.dll", "normaliz.dll":
		return true
	}
	return false
}

func TestRuntimeImportAuditRejectsReceiverAndCompilerDLLs(t *testing.T) {
	for _, library := range []string{
		"libgstreamer-1.0-0.dll", "libcrypto-3-x64.dll", "dnssd.dll", "avcodec-62.dll",
		"libstdc++-6.dll", "libwinpthread-1.dll", "libgcc_s_seh-1.dll", "vcruntime140.dll",
	} {
		if systemRuntimeImport(library) {
			t.Fatalf("external runtime was mistaken for a Windows component: %s", library)
		}
	}
	for _, library := range []string{"KERNEL32.dll", "MFPlat.dll", "api-ms-win-core-synch-l1-2-0.dll", "dnsapi.dll"} {
		if !systemRuntimeImport(library) {
			t.Fatalf("Windows component was rejected: %s", library)
		}
	}
}

// Opt-in: copies only the app executable into an empty directory, removes
// compiler/runtime directories from PATH, and exercises its real worker.
func TestNativeApplicationRunsFromOneFile(t *testing.T) {
	binary := os.Getenv("MIRRORME_NATIVE_BINARY")
	if binary == "" {
		t.Skip("set MIRRORME_NATIVE_BINARY to the built self-contained application")
	}
	imports, err := executableRuntimeImports(binary)
	if err != nil {
		t.Fatal(err)
	}
	for _, library := range imports {
		if !systemRuntimeImport(library) {
			t.Fatalf("application still imports an external runtime: %s", library)
		}
	}
	directory := t.TempDir()
	executable := filepath.Join(directory, "MirrorMe.exe")
	source, err := os.Open(binary)
	if err != nil {
		t.Fatal(err)
	}
	destination, err := os.Create(executable)
	if err != nil {
		source.Close()
		t.Fatal(err)
	}
	_, copyErr := io.Copy(destination, source)
	source.Close()
	closeErr := destination.Close()
	if copyErr != nil || closeErr != nil {
		t.Fatalf("copy application: %v / %v", copyErr, closeErr)
	}
	options := testWorkerOptions(t)
	options.Name = fmt.Sprintf("MirrorMe standalone check %d", os.Getpid())
	options.AudioEnabled = false
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, executable, receiverWorkerArgument)
	command.Dir = directory
	command.Env = append(os.Environ(), "PATH="+filepath.Join(os.Getenv("WINDIR"), "System32"))
	command.WaitDelay = 2 * time.Second
	configureCommand(command)
	input, err := command.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	var diagnostic bytes.Buffer
	command.Stderr = &diagnostic
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	waited := false
	defer func() {
		input.Close()
		cancel()
		if !waited {
			command.Wait()
		}
		if t.Failed() && diagnostic.Len() != 0 {
			t.Logf("Worker diagnostic: %s", diagnostic.String())
		}
	}()
	if err := json.NewEncoder(input).Encode(workerCommand{Protocol: workerProtocolVersion, Command: "start", Options: &options}); err != nil {
		t.Fatal(err)
	}
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 4096), maxReceiverLine)
	ready := false
	for scanner.Scan() {
		event, err := decodeWorkerEvent(scanner.Text())
		if err != nil {
			t.Fatal(err)
		}
		if event.Kind == workerError {
			t.Fatalf("standalone receiver failed: %s", event.Message)
		}
		if event.Kind == workerReady {
			ready = true
			break
		}
	}
	if !ready {
		t.Fatalf("standalone receiver never advertised: %v", scanner.Err())
	}
	if err := json.NewEncoder(input).Encode(workerCommand{Protocol: workerProtocolVersion, Command: "stop"}); err != nil {
		t.Fatal(err)
	}
	input.Close()
	for scanner.Scan() {
		event, err := decodeWorkerEvent(scanner.Text())
		if err != nil || event.Kind == workerError {
			t.Fatalf("standalone receiver failed to stop: %v / %s", err, event.Message)
		}
	}
	if err := scanner.Err(); err != nil {
		t.Fatalf("standalone receiver output was truncated: %v", err)
	}
	if err := command.Wait(); err != nil {
		waited = true
		t.Fatal(err)
	}
	waited = true
	if ctx.Err() != nil {
		t.Fatal("standalone receiver exceeded the shutdown deadline")
	}
}
