package main

import (
	"reflect"
	"strings"
	"testing"
)

func TestReceiverOutputReassemblesLinesAndUTF8(t *testing.T) {
	var lines []string
	output := &receiverOutput{onLine: func(line string) { lines = append(lines, line) }}
	data := []byte("MIRRORME_READY\r\nDevice: caf\xc3\xa9\npartial")
	for _, b := range data {
		if _, err := output.Write([]byte{b}); err != nil {
			t.Fatal(err)
		}
	}
	want := []string{"MIRRORME_READY", "Device: caf\xc3\xa9"}
	if !reflect.DeepEqual(lines, want) {
		t.Fatalf("lines before flush = %q, want %q", lines, want)
	}
	output.flush()
	want = append(want, "partial")
	if !reflect.DeepEqual(lines, want) {
		t.Fatalf("lines after flush = %q, want %q", lines, want)
	}
}

func TestReceiverOutputBoundsOversizedLinesAndRecovers(t *testing.T) {
	var lines []string
	output := &receiverOutput{onLine: func(line string) { lines = append(lines, line) }}
	output.Write([]byte(strings.Repeat("x", maxReceiverLine+1)))
	output.Write([]byte("MIRRORME_READY\nMIRRORME_READY\n"))
	if !reflect.DeepEqual(lines, []string{"MIRRORME_READY"}) {
		t.Fatalf("oversized line was parsed or next line lost: %q", lines)
	}
}
