package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"

	wailsruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

// App is the Wails-bound application root. It owns the persisted Config,
// the Engine process supervisor, and MirrorMe's own system tray icon, and
// is responsible for wiring events between all three and the frontend.
type App struct {
	ctx    context.Context
	store  *ConfigStore
	engine *Engine
	tray   *SystemTray
	logger *VerboseLogger

	// startHidden is true when launched via the Run-key autostart entry
	// (MirrorMe.exe --startup), so the window never flashes on login.
	startHidden bool

	mu         sync.RWMutex
	config     Config
	loadError  string
	logWarning string
	saveMu     sync.Mutex
}

// NewApp constructs the App and loads persisted settings. Engine/tray
// creation is deferred to startup(), once a Wails context exists.
func NewApp(startHidden bool) *App {
	store := NewConfigStore()
	config, err := store.Load()
	loadError := ""
	if err != nil {
		config = DefaultConfig()
		loadError = err.Error()
	}

	return &App{
		store:       store,
		config:      config,
		loadError:   loadError,
		startHidden: startHidden,
	}
}

// startup is a Wails OnStartup hook.
func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
	a.logger = newVerboseLogger(a.GetLogsFolder(), a.setLogWarning)
	if err := a.logger.SetEnabled(a.currentConfig().VerboseLogging); err != nil {
		a.setLogWarning(fmt.Sprintf("Verbose logging could not start: %v", err))
	}
	a.logEvent("app_start", EngineSnapshot{Status: StatusStopped})

	engine, err := NewEngine(a.handleEngineEvent)
	if err != nil {
		a.mu.Lock()
		a.loadError = err.Error()
		a.mu.Unlock()
	}
	a.engine = engine

	a.tray = NewSystemTray()
	a.tray.Show = a.ShowWindow
	a.tray.ToggleMirroring = a.toggleMirroringFromTray
	a.tray.ShowMirroredScreen = func() { a.ShowMirroredScreen() }
	a.tray.ShowSettings = a.ShowSettingsPage
	a.tray.ShowAbout = a.ShowAboutPage
	a.tray.Quit = a.Quit
	a.tray.MenuState = a.trayMenuState
	if err := a.tray.Start(); err != nil {
		// Non-fatal: MirrorMe still works from its main window without a
		// tray icon, just less conveniently.
		a.mu.Lock()
		if a.loadError == "" {
			a.loadError = fmt.Sprintf("system tray icon could not be created: %v", err)
		}
		a.mu.Unlock()
	}

	config := a.currentConfig()

	// Reconcile the persisted "launch at startup" flag with the actual
	// registry state, in case it was changed outside the app (or the exe
	// was moved/reinstalled since it was last written).
	if config.LaunchAtStartup != isLaunchAtStartupSet() {
		_ = setLaunchAtStartup(config.LaunchAtStartup)
	}

	wailsruntime.WindowSetAlwaysOnTop(ctx, config.AlwaysOnTop)
	applyTheme(ctx, config.Theme)

	if config.FirstRun && !a.startHidden {
		wailsruntime.WindowShow(ctx)
	} else if !a.startHidden && !config.StartMinimized {
		wailsruntime.WindowShow(ctx)
	}

	if shouldStartReceiverOnLaunch(config) && a.engine != nil {
		go func() {
			if err := a.engine.Start(config); err != nil {
				a.mu.Lock()
				a.loadError = err.Error()
				a.mu.Unlock()
			}
		}()
	}
}

func shouldStartReceiverOnLaunch(config Config) bool {
	return config.AutoStartMirroring && !config.FirstRun
}

// shutdown is a Wails OnShutdown hook.
func (a *App) shutdown(ctx context.Context) {
	if a.engine != nil {
		_ = a.engine.Stop()
	}
	if a.tray != nil {
		a.tray.Stop()
	}
	if a.logger != nil {
		a.logEvent("app_shutdown", a.GetStatus())
		if err := a.logger.Close(); err != nil {
			a.setLogWarning(fmt.Sprintf("Verbose logging could not finish: %v", err))
		}
	}
}

func (a *App) currentConfig() Config {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.config.Clone()
}

// GetSettings returns the current persisted configuration, annotated with
// any load error from the last time it was read (transient, UI-only).
func (a *App) GetSettings() Config {
	a.mu.RLock()
	defer a.mu.RUnlock()
	config := a.config.Clone()
	config.LoadError = a.loadError
	config.LogWarning = a.logWarning
	return config
}

// SaveSettings validates, normalizes, and persists a settings draft from
// the UI. If the mirroring engine is currently running and a
// mirroring-relevant field changed, it is restarted so the change takes
// effect immediately; purely cosmetic/app-behaviour changes (theme,
// launch-at-startup, etc.) never interrupt an active mirroring session.
func (a *App) SaveSettings(next Config) (Config, error) {
	a.saveMu.Lock()
	defer a.saveMu.Unlock()

	current := a.currentConfig()

	normalized, err := NormalizeConfig(next, current)
	if err != nil {
		return current, err
	}

	if normalized.LaunchAtStartup != current.LaunchAtStartup {
		if err := setLaunchAtStartup(normalized.LaunchAtStartup); err != nil {
			return current, fmt.Errorf("update startup registration: %w", err)
		}
	}

	if a.logger != nil && normalized.VerboseLogging != current.VerboseLogging {
		if !normalized.VerboseLogging {
			a.logEvent("logging_disabled", a.GetStatus())
		}
		if err := a.logger.SetEnabled(normalized.VerboseLogging); err != nil {
			if normalized.LaunchAtStartup != current.LaunchAtStartup {
				err = errors.Join(err, setLaunchAtStartup(current.LaunchAtStartup))
			}
			a.setLogWarning(fmt.Sprintf("Verbose logging could not change: %v", err))
			return current, err
		}
	}

	if a.ctx != nil {
		if normalized.AlwaysOnTop != current.AlwaysOnTop {
			wailsruntime.WindowSetAlwaysOnTop(a.ctx, normalized.AlwaysOnTop)
		}
		if normalized.Theme != current.Theme {
			applyTheme(a.ctx, normalized.Theme)
		}
	}

	if err := a.store.Save(normalized); err != nil {
		if a.logger != nil && normalized.VerboseLogging != current.VerboseLogging {
			if rollbackErr := a.logger.SetEnabled(current.VerboseLogging); rollbackErr != nil {
				a.setLogWarning(fmt.Sprintf("Verbose logging could not restore its previous setting: %v", rollbackErr))
			}
		}
		if normalized.LaunchAtStartup != current.LaunchAtStartup {
			_ = setLaunchAtStartup(current.LaunchAtStartup)
		}
		return current, err
	}

	a.mu.Lock()
	a.config = normalized.Clone()
	a.loadError = ""
	if normalized.VerboseLogging != current.VerboseLogging {
		a.logWarning = ""
	}
	a.mu.Unlock()
	a.logEvent("settings_saved", a.GetStatus())

	if a.engine != nil && a.engine.IsRunning() && configAffectsEngineArgs(current, normalized) {
		if err := a.engine.Start(normalized); err != nil {
			// Settings are already safely persisted; only the live restart
			// failed. Surface it as an engine event rather than a save
			// error, since from the user's perspective their settings did
			// save correctly.
			snapshot := a.engine.Snapshot()
			snapshot.Status, snapshot.LastError = StatusError, err.Error()
			a.handleEngineEvent(EngineEvent{
				Snapshot: snapshot,
				Activity: fmt.Sprintf("Could not apply new settings to the running engine: %v", err),
			})
		}
	}

	saved := a.GetSettings()
	a.emitSettingsUpdated(saved)
	return saved, nil
}

// RegeneratePinCode replaces the current PIN with a new random 4-digit
// code and persists it (only meaningful while RequirePin is enabled).
func (a *App) RegeneratePinCode() (Config, error) {
	next := a.currentConfig()
	next.PinCode = generatePinCode()
	return a.SaveSettings(next)
}

// GetStatus returns the mirroring engine's current status snapshot.
func (a *App) GetStatus() EngineSnapshot {
	if a.engine == nil {
		snapshot := EngineSnapshot{Status: StatusError, LastError: a.engineUnavailableMessage(), Backend: "legacy"}
		if selfContainedReceiver {
			snapshot.Backend = "native"
		}
		return snapshot
	}
	return a.engine.Snapshot()
}

// StartMirroring starts (or restarts) the engine using the current
// settings.
func (a *App) StartMirroring() error {
	if a.engine == nil {
		return errors.New(a.engineUnavailableMessage())
	}
	return a.engine.Start(a.currentConfig())
}

// StopMirroring stops the engine.
func (a *App) StopMirroring() error {
	if a.engine == nil {
		return nil
	}
	return a.engine.Stop()
}

// ConfirmSetupAndStart is retained for older frontends. The self-contained
// receiver starts directly, without an installer or elevated service.
func (a *App) ConfirmSetupAndStart() error {
	if a.engine == nil {
		return errors.New(a.engineUnavailableMessage())
	}
	return a.engine.ConfirmSetupAndStart(a.currentConfig())
}

// ShowMirroredScreen brings the mirrored video window to the foreground.
func (a *App) ShowMirroredScreen() bool {
	if a.engine == nil {
		return false
	}
	return a.engine.ShowMirroredScreen()
}

func (a *App) engineUnavailableMessage() string {
	a.mu.RLock()
	defer a.mu.RUnlock()
	if a.loadError != "" {
		return a.loadError
	}
	return "the mirroring engine is not available"
}

// GetVersion returns the running application version for the About page.
func (a *App) GetVersion() string {
	return applicationVersion()
}

// GetSettingsFolder returns the directory settings.json lives in, shown on
// the About page for troubleshooting.
func (a *App) GetSettingsFolder() string {
	return a.store.Path()
}

// OpenSettingsFolder opens the settings directory in Explorer.
func (a *App) OpenSettingsFolder() error {
	dir := a.store.Path()
	if idx := strings.LastIndexAny(dir, `\/`); idx >= 0 {
		dir = dir[:idx]
	}
	return exec.Command("explorer", dir).Start()
}

func (a *App) GetLogsFolder() string {
	return filepath.Join(filepath.Dir(a.store.Path()), "logs")
}

func (a *App) OpenLogsFolder() error {
	dir := a.GetLogsFolder()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create logs folder: %w", err)
	}
	return exec.Command("explorer", dir).Start()
}

func (a *App) setLogWarning(message string) {
	a.mu.Lock()
	a.logWarning = message
	a.mu.Unlock()
	if a.ctx != nil {
		wailsruntime.EventsEmit(a.ctx, "log-warning", message)
	}
}

func (a *App) logEvent(kind string, snapshot EngineSnapshot) {
	if a.logger != nil {
		a.logger.Log(makeLogRecord(kind, a.currentConfig(), snapshot))
	}
}

// OpenExternalURL opens a link in the user's default browser. Restricted to
// https URLs so this can't be used to launch arbitrary local programs.
func (a *App) OpenExternalURL(url string) error {
	if !strings.HasPrefix(url, "https://") {
		return fmt.Errorf("refusing to open non-https URL")
	}
	if a.ctx != nil {
		wailsruntime.BrowserOpenURL(a.ctx, url)
	}
	return nil
}

// ShowWindow shows, restores, and forces the main window to the foreground.
// Used by the tray icon's "Show MirrorMe" action and left-click.
func (a *App) ShowWindow() {
	if a.ctx == nil {
		return
	}
	wailsruntime.WindowShow(a.ctx)
	wailsruntime.WindowUnminimise(a.ctx)
	// Toggling always-on-top briefly is a reliable way to force focus even
	// when Windows' foreground-lock rules would otherwise ignore a plain
	// WindowShow from a background process (e.g. tray-triggered).
	wailsruntime.WindowSetAlwaysOnTop(a.ctx, true)
	wailsruntime.WindowSetAlwaysOnTop(a.ctx, false)
}

// ShowSettingsPage shows the window and asks the frontend to navigate to
// Settings.
func (a *App) ShowSettingsPage() {
	a.ShowWindow()
	if a.ctx != nil {
		wailsruntime.EventsEmit(a.ctx, "navigate", "settings")
	}
}

// ShowAboutPage shows the window and asks the frontend to navigate to About.
func (a *App) ShowAboutPage() {
	a.ShowWindow()
	if a.ctx != nil {
		wailsruntime.EventsEmit(a.ctx, "navigate", "about")
	}
}

// Quit stops the engine and tray, then exits the application.
func (a *App) Quit() {
	if a.engine != nil {
		_ = a.engine.Stop()
	}
	if a.tray != nil {
		a.tray.Stop()
	}
	if a.ctx != nil {
		wailsruntime.Quit(a.ctx)
	}
}

func (a *App) toggleMirroringFromTray() {
	status := a.GetStatus().Status
	if status == StatusStopped || status == StatusError {
		_ = a.StartMirroring()
		return
	}
	_ = a.StopMirroring()
}

func (a *App) trayMenuState() TrayMenuState {
	snap := a.GetStatus()
	label := "Start receiving"
	if snap.Status != StatusStopped && snap.Status != StatusError {
		label = "Stop receiving"
	}
	if snap.Status == StatusMirroring || snap.Status == StatusPaused {
		label = "Stop mirroring"
	}
	return TrayMenuState{
		Tooltip:                   trayTooltipFor(snap),
		MirroringLabel:            label,
		ShowMirroredScreenEnabled: snap.Status == StatusMirroring,
	}
}

// applyTheme hints WebView2/Windows about the app's light/dark preference so
// native-drawn bits inside the webview (default form controls, scrollbars)
// match the CSS theme the frontend applies via data-mode. The frontend is
// still the source of truth for actual colours; this only affects the
// browser engine's own "prefers-color-scheme" resolution.
func applyTheme(ctx context.Context, theme string) {
	switch theme {
	case "dark":
		wailsruntime.WindowSetDarkTheme(ctx)
	case "light":
		wailsruntime.WindowSetLightTheme(ctx)
	default:
		wailsruntime.WindowSetSystemDefaultTheme(ctx)
	}
}

func trayTooltipFor(snap EngineSnapshot) string {
	switch snap.Status {
	case StatusMirroring:
		if snap.DeviceName != "" {
			return "MirrorMe - mirroring " + snap.DeviceName
		}
		return "MirrorMe - mirroring"
	case StatusConnecting:
		return "MirrorMe - connecting…"
	case StatusPaused:
		return "MirrorMe - paused"
	case StatusAdvertising:
		return "MirrorMe - ready for a device"
	case StatusStarting:
		return "MirrorMe - starting…"
	case StatusNeedsSetup:
		return "MirrorMe - setup required"
	case StatusError:
		return "MirrorMe - error"
	default:
		return "MirrorMe - stopped"
	}
}

// handleEngineEvent is the Engine's onEvent callback: it forwards the
// snapshot to the frontend, keeps the tray tooltip current, and proactively
// surfaces states that need the user's attention (setup required, error)
// even if the window is currently hidden in the tray.
func (a *App) handleEngineEvent(ev EngineEvent) {
	a.logEvent("receiver_event", ev.Snapshot)
	if a.ctx != nil {
		wailsruntime.EventsEmit(a.ctx, "engine-status", ev)
	}
	if a.tray != nil {
		a.tray.UpdateTooltip(trayTooltipFor(ev.Snapshot))
	}
	if ev.Snapshot.Status == StatusNeedsSetup || ev.Snapshot.Status == StatusError {
		a.ShowWindow()
		if a.tray != nil && ev.Activity != "" {
			a.tray.Notify("MirrorMe", ev.Activity)
		}
	}
}

func (a *App) emitSettingsUpdated(config Config) {
	if a.ctx != nil {
		wailsruntime.EventsEmit(a.ctx, "settings-updated", config)
	}
}
