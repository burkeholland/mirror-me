//go:build !windows || !amd64 || legacy_receiver

package main

import "errors"

const selfContainedReceiver = false

func createNativeReceiver(workerOptions, func(int, string)) (nativeReceiverSession, error) {
	return nil, errors.New("this build does not contain the native receiver; build for Windows x64 without the legacy_receiver tag")
}
