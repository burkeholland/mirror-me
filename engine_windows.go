//go:build windows

package main

import (
	"os/exec"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

const (
	gwHwndNext = 2
	swRestore  = 9
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
)

func configureCommand(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow: true, CreationFlags: windows.CREATE_NO_WINDOW,
	}
}

// Closing the parent's job also stops the receiver if MirrorMe crashes.
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
