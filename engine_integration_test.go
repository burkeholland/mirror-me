//go:build windows

package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Opt-in: this starts a real receiver on the local network. It proves local
// service discovery, not that video/audio works with a physical iPhone.
func TestReceiverLiveStartupAndDiscovery(t *testing.T) {
	if os.Getenv("MIRRORME_LIVE_TEST") != "1" {
		t.Skip("set MIRRORME_LIVE_TEST=1 to exercise the bundled receiver and Bonjour")
	}
	e, err := NewEngine(nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := e.Stop(); err != nil {
			t.Error(err)
		}
	})
	config := DefaultConfig()
	config.DeviceName = fmt.Sprintf("MirrorMe startup check %d", os.Getpid())
	if err := e.Start(config); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(startupDeadline + 5*time.Second)
	for e.Snapshot().Status != StatusAdvertising {
		snap := e.Snapshot()
		if snap.Status == StatusError || snap.Status == StatusNeedsSetup || time.Now().After(deadline) {
			t.Fatalf("receiver failed to become ready: %+v", snap)
		}
		time.Sleep(50 * time.Millisecond)
	}
	e.mu.Lock()
	pid := uint32(e.run.cmd.Process.Pid)
	e.mu.Unlock()
	for _, hwnd := range windowsForPID(pid) {
		if isWindowVisible(hwnd) {
			t.Errorf("idle background receiver opened a window: %q", windowTitle(hwnd))
		}
	}
	for _, serviceType := range []string{"_airplay._tcp", "_raop._tcp"} {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		err := discoverReceiver(ctx, filepath.Join(e.engineDir, "dnssd.dll"), serviceType, config.DeviceName)
		cancel()
		if err != nil {
			t.Fatalf("%s discovery failed: %v", serviceType, err)
		}
	}
}

func discoverReceiver(ctx context.Context, dllPath, serviceType, name string) error {
	dll, err := windows.LoadDLL(dllPath)
	if err != nil {
		return err
	}
	defer dll.Release()
	browse, err := dll.FindProc("DNSServiceBrowse")
	if err != nil {
		return err
	}
	deallocate, err := dll.FindProc("DNSServiceRefDeallocate")
	if err != nil {
		return err
	}
	sockFD, err := dll.FindProc("DNSServiceRefSockFD")
	if err != nil {
		return err
	}
	processResult, err := dll.FindProc("DNSServiceProcessResult")
	if err != nil {
		return err
	}
	found := make(chan error, 1)
	callback := syscall.NewCallback(func(_ uintptr, flags, _ uint32, code int32, serviceName, _, _ *byte, _ uintptr) uintptr {
		var result error
		if code != 0 {
			result = fmt.Errorf("DNSServiceBrowse callback: %d", code)
		} else {
			if flags&2 == 0 || serviceName == nil {
				return 0
			}
			got := windows.BytePtrToString(serviceName)
			if got != name && !(serviceType == "_raop._tcp" && strings.HasSuffix(got, "@"+name)) {
				return 0
			}
		}
		select {
		case found <- result:
		default:
		}
		return 0
	})
	kind, err := windows.BytePtrFromString(serviceType)
	if err != nil {
		return err
	}
	var ref uintptr
	code, _, _ := browse.Call(uintptr(unsafe.Pointer(&ref)), 0, 0, uintptr(unsafe.Pointer(kind)), 0, callback, 0)
	if int32(code) != 0 {
		return fmt.Errorf("DNSServiceBrowse: %d", int32(code))
	}
	defer deallocate.Call(ref)
	socket, _, _ := sockFD.Call(ref)
	if int32(socket) < 0 {
		return fmt.Errorf("DNSServiceRefSockFD returned an invalid socket")
	}

	// Windows select uses an FD_SET count plus pointer-sized SOCKET handles.
	// Polling avoids leaving a blocking DNS reader behind when the test ends.
	type fdSet struct {
		Count   uint32
		Sockets [64]uintptr
	}
	type timeVal struct {
		Seconds, Microseconds int32
	}
	selectProc := windows.NewLazySystemDLL("ws2_32.dll").NewProc("select")
	for {
		select {
		case err := <-found:
			return err
		case <-ctx.Done():
			return fmt.Errorf("receiver was not discoverable: %w", ctx.Err())
		default:
		}
		fds := fdSet{Count: 1}
		fds.Sockets[0] = socket
		wait := timeVal{Microseconds: 100000}
		n, _, _ := selectProc.Call(0, uintptr(unsafe.Pointer(&fds)), 0, 0, uintptr(unsafe.Pointer(&wait)))
		if int32(n) < 0 {
			return fmt.Errorf("select failed while waiting for Bonjour")
		}
		if n == 0 {
			continue
		}
		code, _, _ := processResult.Call(ref)
		if int32(code) != 0 {
			return fmt.Errorf("DNSServiceProcessResult: %d", int32(code))
		}
	}
}
