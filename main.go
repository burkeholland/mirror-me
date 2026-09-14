package main

import (
	"embed"
	"os"
	"slices"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
)

//go:embed all:frontend/dist
var assets embed.FS

func main() {
	if len(os.Args) == 2 && os.Args[1] == receiverWorkerArgument {
		os.Exit(runReceiverWorker(os.Stdin, os.Stdout, createNativeReceiver))
	}
	// The Run-key autostart entry launches "MirrorMe.exe --startup" so the
	// window never flashes visible during a normal Windows login.
	app := NewApp(isStartupLaunch(os.Args[1:]))

	// StartHidden is always true: app.startup (OnStartup) is the single
	// place that decides whether/when to reveal the window, based on
	// first-run, "start minimized", and the --startup flag. Deciding this
	// in exactly one place avoids the two settings ever disagreeing.
	err := wails.Run(&options.App{
		Title:             "MirrorMe",
		Width:             1040,
		Height:            760,
		MinWidth:          760,
		MinHeight:         560,
		Frameless:         true,
		StartHidden:       true,
		HideWindowOnClose: true,
		BackgroundColour:  &options.RGBA{R: 245, G: 247, B: 248, A: 255},
		SingleInstanceLock: &options.SingleInstanceLock{
			UniqueId: "ca0a7802-6cdf-4b36-9b16-b07c2d2343a1",
			OnSecondInstanceLaunch: func(data options.SecondInstanceData) {
				if !isStartupLaunch(data.Args) {
					app.ShowWindow()
				}
			},
		},
		AssetServer: &assetserver.Options{
			Assets: assets,
		},
		OnStartup:  app.startup,
		OnShutdown: app.shutdown,
		Bind: []interface{}{
			app,
		},
	})

	if err != nil {
		println("Error:", err.Error())
	}
}

func isStartupLaunch(args []string) bool {
	return slices.Contains(args, "--startup") || slices.Contains(args, "-startup")
}
