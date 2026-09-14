//go:build !windows || !amd64 || native_contracts

package main

import "errors"

const nativeReceiverAvailable = false

func createNativeReceiver(workerOptions, func(int, string)) (nativeReceiverSession, error) {
	return nil, errors.New("this build does not contain the native receiver; use a Windows x64 production build")
}
