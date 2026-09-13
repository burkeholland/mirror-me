//go:build windows

package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

const (
	gwHwndNext         = 2
	swRestore          = 9
	bonjourServiceName = "Bonjour Service"
)

var (
	user32                    = windows.NewLazySystemDLL("user32.dll")
	procGetTopWindow          = user32.NewProc("GetTopWindow")
	procGetWindow             = user32.NewProc("GetWindow")
	procGetWindowThreadProcID = user32.NewProc("GetWindowThreadProcessId")
	procGetWindowTextW        = user32.NewProc("GetWindowTextW")
	procIsWindowVisible       = user32.NewProc("IsWindowVisible")
	procSetForegroundWindow   = user32.NewProc("SetForegroundWindow")
	procShowWindow            = user32.NewProc("ShowWindow")
	procShellExecuteExW       = shell32.NewProc("ShellExecuteExW")
)

// Suppress only the CLI console, not the GStreamer video window.
func configureCommand(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow: true, CreationFlags: windows.CREATE_NO_WINDOW,
	}
}

// Closing the parent's job handle also stops any receiver children if
// MirrorMe crashes or is ended in Task Manager.
func superviseChild(pid uint32) (func(), error) {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return nil, err
	}
	info := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	info.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err := windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation, uintptr(unsafe.Pointer(&info)), uint32(unsafe.Sizeof(info))); err != nil {
		windows.CloseHandle(job)
		return nil, err
	}
	process, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE, false, pid)
	if err != nil {
		windows.CloseHandle(job)
		return nil, err
	}
	defer windows.CloseHandle(process)
	if err := windows.AssignProcessToJobObject(job, process); err != nil {
		windows.CloseHandle(job)
		return nil, err
	}
	return func() { windows.CloseHandle(job) }, nil
}

func windowsForPID(pid uint32) []windows.HWND {
	var found []windows.HWND
	hwnd, _, _ := procGetTopWindow.Call(0)
	for hwnd != 0 {
		var owningPID uint32
		procGetWindowThreadProcID.Call(hwnd, uintptr(unsafe.Pointer(&owningPID)))
		if owningPID == pid {
			found = append(found, windows.HWND(hwnd))
		}
		hwnd, _, _ = procGetWindow.Call(hwnd, gwHwndNext)
	}
	return found
}

func windowTitle(hwnd windows.HWND) string {
	buf := make([]uint16, 512)
	n, _, _ := procGetWindowTextW.Call(uintptr(hwnd), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if n == 0 {
		return ""
	}
	return windows.UTF16ToString(buf[:n])
}

func isWindowVisible(hwnd windows.HWND) bool {
	ret, _, _ := procIsWindowVisible.Call(uintptr(hwnd))
	return ret != 0
}

// The receiver has no control window or tray. Its only visible window is
// the video sink created when an iPhone starts streaming.
func bringVideoWindowToFront(pid uint32) bool {
	for _, hwnd := range windowsForPID(pid) {
		if windowTitle(hwnd) != "" && isWindowVisible(hwnd) {
			procShowWindow.Call(uintptr(hwnd), swRestore)
			procSetForegroundWindow.Call(uintptr(hwnd))
			return true
		}
	}
	return false
}

func bonjourState() (svc.State, error) {
	scm, err := windows.OpenSCManager(nil, nil, windows.SC_MANAGER_CONNECT)
	if err != nil {
		return 0, fmt.Errorf("check Bonjour service: %w", err)
	}
	defer windows.CloseServiceHandle(scm)
	name, _ := windows.UTF16PtrFromString(bonjourServiceName)
	// Querying must not request SERVICE_ALL_ACCESS: ordinary Windows users
	// can read service status without being allowed to reconfigure services.
	handle, err := windows.OpenService(scm, name, windows.SERVICE_QUERY_STATUS)
	if errors.Is(err, windows.ERROR_SERVICE_DOES_NOT_EXIST) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("open Bonjour service: %w", err)
	}
	service := mgr.Service{Name: bonjourServiceName, Handle: handle}
	defer service.Close()
	status, err := service.Query()
	if err != nil {
		return 0, fmt.Errorf("read Bonjour service status: %w", err)
	}
	return status.State, nil
}

func bonjourReady() (bool, error) {
	state, err := bonjourState()
	return state == svc.Running, err
}

func setupBonjour(ctx context.Context, engineDir string) error {
	state, err := bonjourState()
	if err != nil || state == svc.Running {
		return err
	}
	if state == 0 {
		exe := filepath.Join(engineDir, "mDNSResponder.exe")
		if _, err := os.Stat(exe); err != nil {
			return fmt.Errorf("Bonjour installer is missing: %w", err)
		}
		err = runElevated(ctx, exe, "-install", engineDir)
	} else if state == svc.Stopped {
		systemDir, dirErr := windows.GetSystemDirectory()
		if dirErr != nil {
			return dirErr
		}
		err = runElevated(ctx, filepath.Join(systemDir, "sc.exe"), `start "Bonjour Service"`, systemDir)
	}
	if err != nil {
		return err
	}
	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()
	for {
		ready, err := bonjourReady()
		if err != nil || ready {
			return err
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("Bonjour did not become ready: %w", ctx.Err())
		case <-ticker.C:
		}
	}
}

type shellExecuteInfo struct {
	Size       uint32
	Mask       uint32
	Window     windows.Handle
	Verb       *uint16
	File       *uint16
	Parameters *uint16
	Directory  *uint16
	Show       int32
	Instance   windows.Handle
	IDList     uintptr
	Class      *uint16
	ClassKey   windows.Handle
	HotKey     uint32
	Icon       windows.Handle
	Process    windows.Handle
}

// Only called by Continue Setup. The standard Windows UAC dialog remains
// visible; no service is installed or elevated without that approval.
func runElevated(ctx context.Context, exe, args, dir string) error {
	verb, _ := windows.UTF16PtrFromString("runas")
	file, err := windows.UTF16PtrFromString(exe)
	if err != nil {
		return err
	}
	parameters, err := windows.UTF16PtrFromString(args)
	if err != nil {
		return err
	}
	directory, err := windows.UTF16PtrFromString(dir)
	if err != nil {
		return err
	}
	info := shellExecuteInfo{
		Mask: 0x00000040, Verb: verb, File: file, Parameters: parameters,
		Directory: directory, Show: 1,
	}
	info.Size = uint32(unsafe.Sizeof(info))
	ok, _, callErr := procShellExecuteExW.Call(uintptr(unsafe.Pointer(&info)))
	if ok == 0 {
		if errors.Is(callErr, windows.ERROR_CANCELLED) {
			return errors.New("the Windows permission prompt was cancelled")
		}
		return fmt.Errorf("launch Bonjour setup: %w", callErr)
	}
	if info.Process == 0 {
		return errors.New("Windows did not return a handle for Bonjour setup")
	}
	defer windows.CloseHandle(info.Process)
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		result, err := windows.WaitForSingleObject(info.Process, 100)
		if err != nil {
			return fmt.Errorf("wait for Bonjour setup: %w", err)
		}
		if result == uint32(windows.WAIT_TIMEOUT) {
			continue
		}
		var code uint32
		if err := windows.GetExitCodeProcess(info.Process, &code); err != nil {
			return err
		}
		if code != 0 {
			return fmt.Errorf("Bonjour setup exited with code %d", code)
		}
		return nil
	}
}
