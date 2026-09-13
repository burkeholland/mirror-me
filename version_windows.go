//go:build windows

package main

import (
	"fmt"
	"os"
	"unsafe"

	"golang.org/x/sys/windows"
)

const fileInfoSignature = 0xFEEF04BD

var (
	versionDLL                 = windows.NewLazySystemDLL("version.dll")
	procGetFileVersionInfoSize = versionDLL.NewProc("GetFileVersionInfoSizeW")
	procGetFileVersionInfo     = versionDLL.NewProc("GetFileVersionInfoW")
	procVerQueryValue          = versionDLL.NewProc("VerQueryValueW")
)

type fixedFileInfo struct {
	Signature        uint32
	StructVersion    uint32
	FileVersionMS    uint32
	FileVersionLS    uint32
	ProductVersionMS uint32
	ProductVersionLS uint32
	FileFlagsMask    uint32
	FileFlags        uint32
	FileOS           uint32
	FileType         uint32
	FileSubtype      uint32
	FileDateMS       uint32
	FileDateLS       uint32
}

// applicationVersion reads the ProductVersion embedded in this exe's own
// Win32 VERSIONINFO resource (populated by Wails from wails.json's "info"
// block at build time), falling back to Go module build info for
// `wails dev`/`go run`, where no such resource exists yet.
func applicationVersion() string {
	version, err := executableVersion()
	if err != nil {
		return buildInfoVersion()
	}
	return version
}

func executableVersion() (string, error) {
	executable, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("resolve executable path: %w", err)
	}

	path, err := windows.UTF16PtrFromString(executable)
	if err != nil {
		return "", fmt.Errorf("encode executable path: %w", err)
	}

	var handle uint32
	size, _, callErr := procGetFileVersionInfoSize.Call(
		uintptr(unsafe.Pointer(path)),
		uintptr(unsafe.Pointer(&handle)),
	)
	if size == 0 {
		return "", fmt.Errorf("read version info size: %w", callErr)
	}

	data := make([]byte, size)
	ok, _, callErr := procGetFileVersionInfo.Call(
		uintptr(unsafe.Pointer(path)),
		0,
		size,
		uintptr(unsafe.Pointer(&data[0])),
	)
	if ok == 0 {
		return "", fmt.Errorf("read version info: %w", callErr)
	}

	root, err := windows.UTF16PtrFromString(`\`)
	if err != nil {
		return "", fmt.Errorf("encode version query: %w", err)
	}

	var value unsafe.Pointer
	var valueLength uint32
	ok, _, callErr = procVerQueryValue.Call(
		uintptr(unsafe.Pointer(&data[0])),
		uintptr(unsafe.Pointer(root)),
		uintptr(unsafe.Pointer(&value)),
		uintptr(unsafe.Pointer(&valueLength)),
	)
	if ok == 0 {
		return "", fmt.Errorf("query version info: %w", callErr)
	}
	if value == nil || valueLength < uint32(unsafe.Sizeof(fixedFileInfo{})) {
		return "", fmt.Errorf("version info is incomplete")
	}

	info := (*fixedFileInfo)(value)
	if info.Signature != fileInfoSignature {
		return "", fmt.Errorf("version info has an invalid signature")
	}

	return formatVersion(info.ProductVersionMS, info.ProductVersionLS), nil
}

func formatVersion(ms uint32, ls uint32) string {
	major := ms >> 16
	minor := ms & 0xffff
	patch := ls >> 16
	revision := ls & 0xffff
	if revision == 0 {
		return fmt.Sprintf("%d.%d.%d", major, minor, patch)
	}
	return fmt.Sprintf("%d.%d.%d.%d", major, minor, patch, revision)
}
