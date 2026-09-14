package main

import (
	"testing"
	"time"
)

func newTestEngine() (*Engine, *[]EngineEvent) {
	var events []EngineEvent
	e := &Engine{
		status: StatusStopped, desiredRunning: true, generation: 1,
		onEvent: func(ev EngineEvent) { events = append(events, ev) },
	}
	return e, &events
}

func TestSnapshotDoesNotExposeMutableTimestamp(t *testing.T) {
	e, _ := newTestEngine()
	now := time.Now()
	e.connectedAt = &now
	snap := e.Snapshot()
	*snap.ConnectedAt = time.Time{}
	if e.connectedAt.IsZero() {
		t.Fatal("snapshot aliases engine timestamp")
	}
}
