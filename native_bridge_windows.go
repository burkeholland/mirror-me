//go:build windows && amd64 && !native_contracts

package main

/*
#cgo CFLAGS: -I${SRCDIR}/native/include
#cgo LDFLAGS: -L${SRCDIR}/build/native -lmirrorme-native -static -static-libgcc -ldnsapi -lmfplat -lmfuuid -lole32 -loleaut32 -luuid -luser32 -lgdi32 -lksuser -lws2_32 -liphlpapi -lcrypt32 -lbcrypt -ladvapi32
#include <stdlib.h>
#include <string.h>
#include "mirrorme.h"
mm_receiver *mm_go_receiver_create(const mm_receiver_config *config, uintptr_t handle, char *error, size_t capacity);
*/
import "C"

import (
	"errors"
	"runtime/cgo"
	"unsafe"
)

const nativeReceiverAvailable = true

type linkedNativeReceiver struct {
	receiver *C.mm_receiver
	handle   cgo.Handle
}

func nativeBoolean(value bool) C.int {
	if value {
		return 1
	}
	return 0
}

func createNativeReceiver(options workerOptions, emit func(int, string)) (nativeReceiverSession, error) {
	if err := options.validate(); err != nil {
		return nil, err
	}
	config := C.mm_receiver_config{
		name: C.CString(options.Name), device_id: C.CString(options.DeviceID), key_path: C.CString(options.KeyPath),
		width: C.uint(options.Width), height: C.uint(options.Height), max_fps: C.uint(options.MaxFPS),
		idle_timeout_seconds: C.uint(options.IdleTimeoutSeconds), pin: C.uint(options.Pin),
		require_pin: nativeBoolean(options.RequirePin), prefer_newest: nativeBoolean(options.PreferNewest),
		hardware_decode: nativeBoolean(options.HardwareDecode), allow_h265: nativeBoolean(options.AllowH265),
		audio_enabled: nativeBoolean(options.AudioEnabled),
	}
	defer C.free(unsafe.Pointer(config.name))
	defer C.free(unsafe.Pointer(config.device_id))
	defer C.free(unsafe.Pointer(config.key_path))
	handle := cgo.NewHandle(emit)
	var errorBuffer [1024]C.char
	receiver := C.mm_go_receiver_create(&config, C.uintptr_t(handle), &errorBuffer[0], C.size_t(len(errorBuffer)))
	if receiver == nil {
		handle.Delete()
		message, valid := nativeMessage(&errorBuffer[0], len(errorBuffer))
		if !valid {
			message = "The built-in receiver returned an invalid initialization error."
		}
		if message == "" {
			message = "The built-in receiver could not initialize."
		}
		return nil, errors.New(message)
	}
	return &linkedNativeReceiver{receiver: receiver, handle: handle}, nil
}

//export mmGoReceiverEvent
func mmGoReceiverEvent(handle C.uintptr_t, kind C.int, message *C.char) {
	callback := cgo.Handle(handle).Value().(func(int, string))
	text, valid := nativeMessage(message, workerMessageLimit+1)
	if !valid {
		callback(workerError, "The built-in receiver returned an oversized status message.")
		return
	}
	callback(int(kind), text)
}

func nativeMessage(message *C.char, capacity int) (string, bool) {
	if message == nil {
		return "", true
	}
	length := C.strnlen(message, C.size_t(capacity))
	if length == C.size_t(capacity) {
		return "", false
	}
	return C.GoStringN(message, C.int(length)), true
}

func (r *linkedNativeReceiver) Run() error {
	if C.mm_receiver_run(r.receiver) != 0 {
		return errors.New("The built-in receiver stopped after a native error.")
	}
	return nil
}
func (r *linkedNativeReceiver) Stop() { C.mm_receiver_request_stop(r.receiver) }
func (r *linkedNativeReceiver) Show() { C.mm_receiver_show_video(r.receiver) }
func (r *linkedNativeReceiver) Close() {
	C.mm_receiver_destroy(r.receiver)
	r.handle.Delete()
}
