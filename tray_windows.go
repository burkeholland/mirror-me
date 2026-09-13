//go:build windows

package main

import (
	"fmt"
	"os"
	"runtime"
	"sync"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

// SystemTray owns MirrorMe's own tray icon, context menu, and the hidden
// message-only window required to receive Shell_NotifyIcon callbacks. It is
// intentionally decoupled from Engine/Config: callers wire behaviour through
// the exported callback fields and MenuState, so this file has no knowledge
// of the engine's status model.
type SystemTray struct {
	mu      sync.RWMutex
	hwnd    windows.Handle
	hIcon   windows.Handle
	stopped bool

	// Callbacks wired up by the owner (app.go) before Start().
	Show               func()
	ToggleMirroring    func()
	ShowMirroredScreen func()
	ShowSettings       func()
	ShowAbout          func()
	Quit               func()

	// MenuState supplies the current dynamic menu contents on demand
	// (called each time the context menu is about to be shown).
	MenuState func() TrayMenuState
}

// TrayMenuState is the small, engine-agnostic snapshot the tray needs to
// render its context menu and tooltip.
type TrayMenuState struct {
	Tooltip                   string
	MirroringLabel            string
	ShowMirroredScreenEnabled bool
}

const (
	trayWmDestroy     = 0x0002
	trayWmCommand     = 0x0111
	trayWmUser        = 0x0400
	trayWmIcon        = trayWmUser + 1
	trayWmLButtonUp   = 0x0202
	trayWmRButtonUp   = 0x0205
	trayWmContextMenu = 0x007B

	nimAdd    = 0x00000000
	nimModify = 0x00000001
	nimDelete = 0x00000002

	nifMessage = 0x00000001
	nifIcon    = 0x00000002
	nifTip     = 0x00000004
	nifInfo    = 0x00000010

	mfString    = 0x00000000
	mfSeparator = 0x00000800
	mfDisabled  = 0x00000002
	mfGrayed    = 0x00000001

	tpmRightButton = 0x0002
	tpmReturnCmd   = 0x0100
	tpmNonotify    = 0x0080

	niifInfo = 0x00000001

	cmdShowWindow   = 1
	cmdToggleMirror = 2
	cmdShowScreen   = 3
	cmdSettings     = 4
	cmdAbout        = 5
	cmdQuit         = 6
)

var (
	shell32  = windows.NewLazySystemDLL("shell32.dll")
	kernel32 = windows.NewLazySystemDLL("kernel32.dll")

	procRegisterClassEx  = user32.NewProc("RegisterClassExW")
	procCreateWindowEx   = user32.NewProc("CreateWindowExW")
	procDefWindowProc    = user32.NewProc("DefWindowProcW")
	procDestroyWindow    = user32.NewProc("DestroyWindow")
	procGetMessage       = user32.NewProc("GetMessageW")
	procTranslateMessage = user32.NewProc("TranslateMessage")
	procDispatchMessage  = user32.NewProc("DispatchMessageW")
	procPostQuitMessage  = user32.NewProc("PostQuitMessage")
	procLoadIcon         = user32.NewProc("LoadIconW")
	procGetCursorPos     = user32.NewProc("GetCursorPos")
	procCreatePopupMenu  = user32.NewProc("CreatePopupMenu")
	procAppendMenu       = user32.NewProc("AppendMenuW")
	procTrackPopupMenu   = user32.NewProc("TrackPopupMenu")
	procDestroyMenu      = user32.NewProc("DestroyMenu")

	procExtractIconEx   = shell32.NewProc("ExtractIconExW")
	procShellNotifyIcon = shell32.NewProc("Shell_NotifyIconW")
	procGetModuleHandle = kernel32.NewProc("GetModuleHandleW")

	trayMu        sync.RWMutex
	activeTray    *SystemTray
	trayWndProcCB = syscall.NewCallback(trayWindowProc)
)

type trayPoint struct {
	X int32
	Y int32
}

type trayWndClassEx struct {
	CbSize        uint32
	Style         uint32
	LpfnWndProc   uintptr
	CbClsExtra    int32
	CbWndExtra    int32
	HInstance     windows.Handle
	HIcon         windows.Handle
	HCursor       windows.Handle
	HbrBackground windows.Handle
	LpszMenuName  *uint16
	LpszClassName *uint16
	HIconSm       windows.Handle
}

type trayNotifyIconData struct {
	CbSize            uint32
	HWnd              windows.Handle
	UID               uint32
	UFlags            uint32
	UCallbackMessage  uint32
	HIcon             windows.Handle
	SzTip             [128]uint16
	DwState           uint32
	DwStateMask       uint32
	SzInfo            [256]uint16
	UTimeoutOrVersion uint32
	SzInfoTitle       [64]uint16
	DwInfoFlags       uint32
	GuidItem          windows.GUID
	HBalloonIcon      windows.Handle
}

type trayMessage struct {
	Hwnd    windows.Handle
	Message uint32
	WParam  uintptr
	LParam  uintptr
	Time    uint32
	Pt      trayPoint
}

// NewSystemTray creates a tray controller. Wire the callback fields and
// MenuState, then call Start.
func NewSystemTray() *SystemTray {
	return &SystemTray{}
}

// Start creates the hidden window, adds the tray icon, and begins pumping
// the Win32 message loop on a dedicated locked OS thread. It blocks until
// the tray icon is ready (or creation fails).
func (t *SystemTray) Start() error {
	started := make(chan error, 1)
	go t.run(started)
	return <-started
}

// Stop removes the tray icon and tears down the hidden window. Safe to call
// multiple times.
func (t *SystemTray) Stop() {
	t.mu.Lock()
	if t.stopped {
		t.mu.Unlock()
		return
	}
	t.stopped = true
	hwnd := t.hwnd
	t.mu.Unlock()

	if hwnd != 0 {
		t.deleteIcon()
		procDestroyWindow.Call(uintptr(hwnd))
	}
}

// Notify shows a balloon notification from MirrorMe's tray icon.
func (t *SystemTray) Notify(title, body string) {
	t.mu.RLock()
	hwnd := t.hwnd
	hIcon := t.hIcon
	t.mu.RUnlock()
	if hwnd == 0 {
		return
	}

	nid := trayNotifyIconData{
		CbSize:      uint32(unsafe.Sizeof(trayNotifyIconData{})),
		HWnd:        hwnd,
		UID:         1,
		UFlags:      nifInfo,
		HIcon:       hIcon,
		DwInfoFlags: niifInfo,
	}
	copyTrayUTF16(nid.SzInfoTitle[:], title)
	copyTrayUTF16(nid.SzInfo[:], body)
	procShellNotifyIcon.Call(nimModify, uintptr(unsafe.Pointer(&nid)))
}

// UpdateTooltip refreshes just the tooltip text (e.g. after a status change).
func (t *SystemTray) UpdateTooltip(tooltip string) {
	t.mu.RLock()
	hwnd := t.hwnd
	hIcon := t.hIcon
	t.mu.RUnlock()
	if hwnd == 0 {
		return
	}

	nid := trayNotifyIconData{
		CbSize:           uint32(unsafe.Sizeof(trayNotifyIconData{})),
		HWnd:             hwnd,
		UID:              1,
		UFlags:           nifIcon | nifTip,
		UCallbackMessage: trayWmIcon,
		HIcon:            hIcon,
	}
	copyTrayUTF16(nid.SzTip[:], tooltip)
	procShellNotifyIcon.Call(nimModify, uintptr(unsafe.Pointer(&nid)))
}

func (t *SystemTray) run(started chan<- error) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	trayMu.Lock()
	activeTray = t
	trayMu.Unlock()
	defer func() {
		trayMu.Lock()
		if activeTray == t {
			activeTray = nil
		}
		trayMu.Unlock()
	}()

	hwnd, err := createTrayWindow()
	if err != nil {
		started <- err
		return
	}

	hIcon := loadAppIcon()

	t.mu.Lock()
	t.hwnd = hwnd
	t.hIcon = hIcon
	t.mu.Unlock()

	if err := t.addIcon(); err != nil {
		started <- err
		return
	}
	started <- nil

	var msg trayMessage
	for {
		ret, _, _ := procGetMessage.Call(uintptr(unsafe.Pointer(&msg)), 0, 0, 0)
		if int32(ret) == -1 || ret == 0 {
			return
		}
		procTranslateMessage.Call(uintptr(unsafe.Pointer(&msg)))
		procDispatchMessage.Call(uintptr(unsafe.Pointer(&msg)))
	}
}

func createTrayWindow() (windows.Handle, error) {
	className, err := windows.UTF16PtrFromString("MirrorMeTrayWindow")
	if err != nil {
		return 0, err
	}
	instance, _, _ := procGetModuleHandle.Call(0)
	wc := trayWndClassEx{
		CbSize:        uint32(unsafe.Sizeof(trayWndClassEx{})),
		LpfnWndProc:   trayWndProcCB,
		HInstance:     windows.Handle(instance),
		LpszClassName: className,
	}
	atom, _, registerErr := procRegisterClassEx.Call(uintptr(unsafe.Pointer(&wc)))
	if atom == 0 && registerErr != windows.ERROR_CLASS_ALREADY_EXISTS {
		return 0, fmt.Errorf("register tray window: %w", registerErr)
	}

	hwnd, _, createErr := procCreateWindowEx.Call(
		0,
		uintptr(unsafe.Pointer(className)),
		uintptr(unsafe.Pointer(className)),
		0,
		0, 0, 0, 0,
		0,
		0,
		instance,
		0,
	)
	if hwnd == 0 {
		return 0, fmt.Errorf("create tray window: %w", createErr)
	}
	return windows.Handle(hwnd), nil
}

// loadAppIcon extracts the icon embedded in this running exe (index 0 of
// the icon group Wails compiles in from build/windows/icon.ico), falling
// back to the generic application icon if extraction fails for any reason.
func loadAppIcon() windows.Handle {
	exePath, err := os.Executable()
	if err == nil {
		lpszFile, convErr := windows.UTF16PtrFromString(exePath)
		if convErr == nil {
			var hSmallIcon windows.Handle
			count, _, _ := procExtractIconEx.Call(
				uintptr(unsafe.Pointer(lpszFile)),
				0,
				0,
				uintptr(unsafe.Pointer(&hSmallIcon)),
				1,
			)
			if count > 0 && hSmallIcon != 0 {
				return hSmallIcon
			}
		}
	}
	icon, _, _ := procLoadIcon.Call(0, 32512) // IDI_APPLICATION fallback
	return windows.Handle(icon)
}

func (t *SystemTray) addIcon() error {
	t.mu.RLock()
	hwnd := t.hwnd
	hIcon := t.hIcon
	t.mu.RUnlock()

	nid := trayNotifyIconData{
		CbSize:           uint32(unsafe.Sizeof(trayNotifyIconData{})),
		HWnd:             hwnd,
		UID:              1,
		UFlags:           nifMessage | nifIcon | nifTip,
		UCallbackMessage: trayWmIcon,
		HIcon:            hIcon,
	}
	copyTrayUTF16(nid.SzTip[:], "MirrorMe")
	ret, _, err := procShellNotifyIcon.Call(nimAdd, uintptr(unsafe.Pointer(&nid)))
	if ret == 0 {
		return fmt.Errorf("add tray icon: %w", err)
	}
	return nil
}

func (t *SystemTray) deleteIcon() {
	t.mu.RLock()
	hwnd := t.hwnd
	t.mu.RUnlock()
	if hwnd == 0 {
		return
	}
	nid := trayNotifyIconData{
		CbSize: uint32(unsafe.Sizeof(trayNotifyIconData{})),
		HWnd:   hwnd,
		UID:    1,
	}
	procShellNotifyIcon.Call(nimDelete, uintptr(unsafe.Pointer(&nid)))
}

func (t *SystemTray) showMenu() {
	t.mu.RLock()
	hwnd := t.hwnd
	menuStateFn := t.MenuState
	t.mu.RUnlock()
	if hwnd == 0 {
		return
	}

	state := TrayMenuState{MirroringLabel: "Start Mirroring"}
	if menuStateFn != nil {
		state = menuStateFn()
	}

	menu, _, _ := procCreatePopupMenu.Call()
	if menu == 0 {
		return
	}
	defer procDestroyMenu.Call(menu)

	appendTrayMenu(menu, mfString, cmdShowWindow, "Show MirrorMe")
	appendTrayMenu(menu, mfSeparator, 0, "")
	appendTrayMenu(menu, mfString, cmdToggleMirror, state.MirroringLabel)
	screenFlags := uint32(mfString)
	if !state.ShowMirroredScreenEnabled {
		screenFlags |= mfDisabled | mfGrayed
	}
	appendTrayMenu(menu, screenFlags, cmdShowScreen, "Show screen")
	appendTrayMenu(menu, mfSeparator, 0, "")
	appendTrayMenu(menu, mfString, cmdSettings, "Settings...")
	appendTrayMenu(menu, mfString, cmdAbout, "Help && about")
	appendTrayMenu(menu, mfSeparator, 0, "")
	appendTrayMenu(menu, mfString, cmdQuit, "Quit MirrorMe")

	var pt trayPoint
	procGetCursorPos.Call(uintptr(unsafe.Pointer(&pt)))

	procSetForegroundWindow.Call(uintptr(hwnd))
	cmd, _, _ := procTrackPopupMenu.Call(
		menu,
		tpmRightButton|tpmReturnCmd|tpmNonotify,
		uintptr(uint32(pt.X)),
		uintptr(uint32(pt.Y)),
		0,
		uintptr(hwnd),
		0,
	)
	if cmd != 0 {
		go t.handleCommand(uint32(cmd))
	}
}

func appendTrayMenu(menu uintptr, flags uint32, command uint32, label string) {
	var labelPtr uintptr
	if label != "" {
		labelPtr = uintptr(unsafe.Pointer(windows.StringToUTF16Ptr(label)))
	}
	procAppendMenu.Call(menu, uintptr(flags), uintptr(command), labelPtr)
}

func (t *SystemTray) handleCommand(command uint32) {
	switch command {
	case cmdShowWindow:
		t.invoke(t.Show)
	case cmdToggleMirror:
		t.invoke(t.ToggleMirroring)
	case cmdShowScreen:
		t.invoke(t.ShowMirroredScreen)
	case cmdSettings:
		t.invoke(t.ShowSettings)
	case cmdAbout:
		t.invoke(t.ShowAbout)
	case cmdQuit:
		t.invoke(t.Quit)
	}
}

func (t *SystemTray) invoke(fn func()) {
	if fn != nil {
		fn()
	}
}

func trayWindowProc(hwnd uintptr, msg uint32, wParam uintptr, lParam uintptr) uintptr {
	trayMu.RLock()
	tray := activeTray
	trayMu.RUnlock()

	if tray != nil {
		switch msg {
		case trayWmIcon:
			switch lParam {
			case trayWmLButtonUp:
				go tray.invoke(tray.Show)
				return 0
			case trayWmRButtonUp, trayWmContextMenu:
				tray.showMenu()
				return 0
			}
		case trayWmCommand:
			go tray.handleCommand(uint32(wParam & 0xffff))
			return 0
		case trayWmDestroy:
			tray.deleteIcon()
			procPostQuitMessage.Call(0)
			return 0
		}
	}

	ret, _, _ := procDefWindowProc.Call(hwnd, uintptr(msg), wParam, lParam)
	return ret
}

func copyTrayUTF16(target []uint16, value string) {
	encoded := windows.StringToUTF16(value)
	if len(encoded) > len(target) {
		encoded = encoded[:len(target)]
		encoded[len(encoded)-1] = 0
	}
	copy(target, encoded)
}
