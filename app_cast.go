package main

import (
	"errors"

	wailsruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

func (a *App) GetCastStatus() CastSnapshot {
	if a.sender == nil {
		return CastSnapshot{Status: "stopped", Targets: []CastTarget{}, LastError: "Desktop casting is not initialized."}
	}
	return a.sender.Snapshot()
}

func (a *App) DiscoverCastTargets() error {
	if a.sender == nil {
		return errors.New("desktop casting is not initialized")
	}
	return a.sender.Discover()
}

func (a *App) StartDesktopCast(targetID string, revision uint64) error {
	if a.sender == nil {
		return errors.New("desktop casting is not initialized")
	}
	return a.sender.Start(targetID, revision)
}

func (a *App) SubmitCastPIN(pin string, revision uint64) error {
	if a.sender == nil {
		return errors.New("desktop casting is not initialized")
	}
	return a.sender.SubmitPIN(pin, revision)
}

func (a *App) StopDesktopCast() error {
	if a.sender == nil {
		return errors.New("desktop casting is not initialized")
	}
	return a.sender.Stop()
}

func (a *App) ForgetCastTarget(targetID string) error {
	if a.sender == nil {
		return errors.New("desktop casting is not initialized")
	}
	return a.sender.Forget(targetID)
}

func (a *App) handleCastEvent(snapshot CastSnapshot) {
	if a.tray != nil {
		a.tray.UpdateTooltip(a.trayMenuState().Tooltip)
		if snapshot.Status == "error" {
			a.tray.Notify("Desktop casting stopped", snapshot.LastError)
		}
	}
	if a.ctx != nil {
		wailsruntime.EventsEmit(a.ctx, "cast-status", snapshot)
	}
}
