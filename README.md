# MirrorMe

An open-source Windows preview for receiving your iPhone's screen over
AirPlay. No cable, Apple account, or companion iPhone app is required.

MirrorMe is a native Windows 11 app (Go + [Wails v2](https://wails.io), the
same stack as [burkeholland/resize-me](https://github.com/burkeholland/resize-me))
with a fluent, WinUI-3-style interface, a system tray icon, dark/light theming,
and a settings experience that feels at home next to the rest of Windows.

**Preview status:** unsigned Windows x64 software, not an app-store release.
Local discovery and real video decoding/display have been checked, but the
[physical-iPhone checklist](#real-iphone-release-checklist) is still open.
The website demonstration is a simulation, not a device test.

[Try the interactive demo](https://burkeholland.github.io/mirror-me/) |
[Download the Windows preview](https://github.com/burkeholland/mirror-me/releases/download/v0.1.0-preview.1/MirrorMe-windows-x64.zip)

Extract the **entire ZIP**, open `MirrorMe.exe`, and choose **Download receiver
files** when prompted. This one-time, 113 MB download comes directly from the
upstream UxPlay Windows project. MirrorMe checks its pinned SHA-256 and decodes
a generated test frame before installing it in your local application cache.
The standalone UxPlay desktop app is excluded. Internet is needed for this
setup; mirroring itself stays on your local network. Windows may warn about
the unsigned application; verify the release checksum and source before
choosing whether to run it.

## Features

- **Wireless AirPlay mirroring** — your iPhone finds MirrorMe over your local
  Wi-Fi network exactly like it finds an Apple TV; no pairing app or cable
  required.
- **A focused Mirror workspace** — one connection view, the PC name your
  iPhone sees, and the right action for the current state. Connection
  details and recent activity stay out of the way until you expand them.
- **A short, two-step welcome** — name this PC, then connect your iPhone.
  Receiving starts when you continue, not before first-run setup.
- **Useful connection recovery** — phone detection, encoded-video arrival,
  and displayed frames are distinct. Only a real video sink's rendered-frame
  count starts the mirroring timer. A slow connection explains whether video
  has not arrived or Windows has not displayed it, with relevant recovery
  actions. Decoder/display errors are surfaced rather than hidden.
- **Full settings control**, grouped into Connection, Picture & sound, and
  App. Advanced options expand when needed. Changes remain a draft until
  you **Save changes** or **Revert**:
  - **Device** — the name your iPhone sees in its Screen Mirroring list.
  - **Streaming quality** — resolution (Auto / 720p / 1080p / 4K), max frame
    rate, audio passthrough, hardware-accelerated decoding, and optional
    H.265/HEVC for newer iPhones.
  - **Connection & security** — prefer the newest connection over rejecting
    a second device, an inactivity auto-disconnect timer, and an optional
    **4-digit PIN** (generated with `crypto/rand`) required before an iPhone
    can connect.
  - **App behavior** — launch at Windows startup, start minimized to the
    tray, auto-start mirroring on launch, always-on-top, and light / dark /
    match-Windows theming.
- **System tray integration** — start/stop mirroring, jump to Settings or
  About, or quit, all from the tray icon; closing the window keeps MirrorMe
  running quietly in the tray instead of exiting. The receiver has no
  separate tray icon or control window. Opening MirrorMe again brings up
  the existing window instead of creating a second app and tray icon.
- **Bounded startup** — the app reports ready only after receiver
  initialization succeeds. Startup can be cancelled, and a receiver that
  does not become ready within 20 seconds is stopped with an explanation.
- **Guided one-time setup** — AirPlay depends on Apple's Bonjour network
  service. If it isn't installed yet, MirrorMe walks you through the one-time,
  self-contained install (a single UAC prompt) instead of failing silently.
  See [How mirroring works](#how-mirroring-works) below.
- **Safe-by-design settings storage** — settings are written atomically
  (temp file + rename) to `%APPDATA%\MirrorMe\settings.json`, so a crash or
  power loss mid-save can't corrupt your configuration.
- **Windows-style interaction** — labeled navigation, system fonts,
  light/dark/system themes with reversible previews, accessible dialogs,
  keyboard shortcuts, reduced motion, and Windows high-contrast support.
  The frameless Wails window retains Windows 11 rounded decorations.
- **No online UI assets** — Postrboard's design tokens and Lucide SVG icons
  are bundled locally. There are no font or stylesheet CDN requests.

## Requirements

- **Windows 11** (or Windows 10 with the [WebView2 runtime](https://developer.microsoft.com/microsoft-edge/webview2/) installed — present by default on Windows 11).
- Your iPhone and this PC on the **same local network**. The PC can use
  Wi-Fi or Ethernet.
- An internet connection for the first receiver download. Published
  previews do not bundle or republish the upstream runtime DLLs.

To build from source you'll also need:

- [Go](https://go.dev/) 1.25 or later
- [Node.js](https://nodejs.org/) 20.19+ or 22.12+ (required by Vite 7)
- The [Wails v2 CLI](https://wails.io/docs/gettingstarted/installation) (`go install github.com/wailsapp/wails/v2/cmd/wails@v2.15.0`)

## Getting started

```powershell
# Install the Wails CLI (one time)
go install github.com/wailsapp/wails/v2/cmd/wails@v2.15.0

# From the MirrorMe source folder, build the background receiver
# when it is not already bundled
.\scripts\build-receiver.ps1

# Live development, with hot reload for the frontend
wails dev

# Build the Windows executable
wails build

# Package a preview ZIP plus matching native receiver source
.\scripts\package-release.ps1
```

`wails build` produces `build\bin\MirrorMe.exe`. A post-build step
(`scripts/copy-engine.ps1`) automatically copies the bundled mirroring
engine (`engine/`) alongside it for local development. The public ZIP includes
only MirrorMe's background receiver in that folder and installs the pinned
runtime on explicit first-run consent. **Keep the `engine` folder next to
`MirrorMe.exe`**; do not copy the app executable out on its own.

The receiver is built separately from pinned UxPlay source. Its native build
requirements and dependency locations are configured by
`scripts\build-receiver.ps1`. Go/Wails still builds the Windows app and its
interface; it does not compile the receiver's C/C++ dependencies.

## Using MirrorMe

1. Launch `MirrorMe.exe`. On first run, choose the name this PC should
   show on your iPhone and select **Continue**.
   If prompted, choose **Download receiver files** and let the one-time
   download and decoder check complete. It is cancellable and does not
   need administrator permission.
2. If discovery needs setup, select **Allow discovery** and approve the
   Windows administrator prompt to install or start Bonjour.
3. When the PC is ready, open **Control Center** on your iPhone and tap
   **Screen Mirroring**. Choose this PC's name. On an iPhone with a Home
   button, swipe up from the bottom to open Control Center.
4. Select **Done** to finish the welcome. The **How to connect** guide
   remains available from Mirror and Help & about.
5. When the receiver reports mirroring, use **Show screen** to bring the
   separate video window forward, or **Stop mirroring** to end the session.

After setup, MirrorMe starts receiving automatically unless you disable
that option. If receiving is stopped, select **Start receiving** on Mirror.

Closing the MirrorMe window doesn't quit it — it keeps running in the system
tray so mirroring isn't interrupted. Right-click the tray icon to show the
window, start/stop mirroring, jump to Settings or About, or quit for good.

### Settings reference

| Section | Setting | What it does |
|---|---|---|
| Connection | PC name | The name shown in your iPhone's Screen Mirroring list. |
| Connection | Require a pairing code | Requests a random four-digit code when a device pairs. |
| Connection, advanced | Let another iPhone take over | A new connection replaces the current session. |
| Connection, advanced | Disconnect an inactive session | Releases the connection after a chosen period of inactivity. |
| Picture & sound | Maximum resolution | The requested quality limit: Automatic, 720p, 1080p, or 4K. |
| Picture & sound | Maximum frame rate | The requested frame-rate limit, not a live measurement. |
| Picture & sound | Play iPhone audio | Uses the PC's speakers for mirrored sound. |
| Picture & sound, advanced | Use hardware acceleration | Uses the graphics processor to decode video. |
| Picture & sound, advanced | Allow HEVC video | Enables H.265 for compatible devices. |
| App | Theme | Light, dark, or follow Windows; preview before saving. |
| App | Keep MirrorMe on top | Keeps the control window above other apps. |
| App | Start receiving automatically | Makes the PC available when MirrorMe opens after setup. |
| App | Open in the system tray | Keeps the control window hidden on launch. |
| App, Windows startup | Launch when I sign in | Starts MirrorMe in the tray when you sign in to Windows. |

Settings are staged as a draft — edit as many fields as you like, then
**Save changes** to apply and persist them, or **Revert** to discard your changes.
Changes that affect an active mirroring session (like resolution) restart
the engine automatically; app-behavior changes never interrupt mirroring.
Leaving Settings with edits opens a save/discard confirmation. Generating
a new pairing code does not discard other unsaved changes.

Use **Ctrl+,** for Settings, **Ctrl+S** to save, **F1** for the connection
guide, and **Esc** to close a dialog. Arrow keys move between settings
categories. Receiver updates do not interrupt editing, and the session
timer updates without rebuilding the page.

## How mirroring works

MirrorMe doesn't reimplement Apple's AirPlay protocol. It's a native Windows
front end that manages [UxPlay](https://github.com/FDH2/UxPlay), an
open-source AirPlay mirroring receiver, as a background subprocess. MirrorMe owns the
UI, settings, tray icon, and lifecycle; UxPlay owns the network protocol and
video decoding.

There is **one tray icon**. `mirrorme-receiver.exe` is a background-only
adapter around the Windows-compatible UxPlay library, not the separate
`uxplay-windows` desktop application. Settings are passed directly as
arguments, and status is read from the receiver's output pipe, not from a
guessed log-file location. Quitting MirrorMe also stops the receiver.

Bonjour must be running for network discovery. **Allow discovery** uses the
standard Windows permission prompt to install or start it. Ordinary
mirroring does not need administrator permission.

## Project structure

```
mirror-me/
├── app.go, config.go, engine*.go, security.go, ...   Go backend (Wails-bound App, settings, engine supervisor)
├── main.go                                            Entry point / window configuration
├── engine/                                            Background receiver and multimedia runtime libraries
├── receiver/                                          Native receiver adapter and reproducible build inputs
├── frontend/src/                                      Vanilla JS/HTML/CSS UI (style.css, state.js, render.js, events.js, main.js)
├── build/                                             Wails build assets (icons, Windows manifest)
├── scripts/                                            Build helper scripts (engine packaging, icon generation)
└── wails.json                                          Wails project configuration
```

## Testing

The Go suite covers settings, arguments, status parsing, and real Windows
child-process startup, timeout, cancellation, failure, and cleanup:

```powershell
go vet ./...
go test -race ./...
```

Frontend regressions cover onboarding, cancellation, delayed video, staged
settings, pairing codes, theme handling, accessibility markup, and races
between initial page loading and incoming receiver events:

```powershell
Set-Location frontend
npm test

# Real browser layout and interaction checks (requires Microsoft Edge)
npm run test:ui
```

The UI review launches an isolated, temporary Edge profile against a local
Vite server and checks light/dark themes, minimum window dimensions, high
contrast, reduced motion, keyboard controls, focus, dialogs, and offline
assets. Screenshots and results go to `build\ui-review` by default.

For visual development, `frontend\tests\preview.html` is an explicitly
labeled simulation with selectable states. It does not start a receiver or
change Windows settings. These fixtures are not included in the production
frontend bundle.

These automated checks do not replace mirroring from a physical iPhone.
Device compatibility, video/audio synchronization, and protected-content
behavior need real-device testing before release.

The native build also checks actual decoding with an original H.264 fixture:

```powershell
.\engine\mirrorme-receiver.exe --media-self-test
.\engine\mirrorme-receiver.exe --media-self-test-software
# Opens a temporary real Windows video window, without a network receiver:
.\engine\mirrorme-receiver.exe --media-self-test-window
# An intentionally broken pipeline must exit nonzero and report its error:
.\engine\mirrorme-receiver.exe --media-self-test-invalid
```

The no-window checks must not emit the streaming marker, even after their
test sink processes decoded frames. The window check must report rendered
video, not merely a selected codec or PLAYING pipeline.

To verify the complete first-run download in a fresh temporary cache:
`$env:MIRRORME_RUNTIME_TEST='1'; go test -run '^TestRuntimeOfficialDownloadAndDecoder$' -count=1 -v`.
This downloads the pinned 113 MB archive from GitHub; normal unit tests
use local test servers and do not download it.

### Real-iPhone release checklist

These items require a physical device and are not implied by a passing UI
review or successful network discovery:

- [ ] Connect an iPhone and confirm that its Home Screen actually appears.
- [ ] Rotate the phone, open a photo, and confirm that the video window updates.
- [ ] Play unprotected video and confirm picture/audio synchronization.
- [ ] Enable a pairing code and verify the prompt on the iPhone.
- [ ] Stop mirroring from both devices, then reconnect.
- [ ] Exercise sleep/wake and a network interruption, and confirm recovery.
- [ ] Quit MirrorMe and confirm that its receiver and discovery records stop.

For an opt-in local integration check, stop other receiver instances and
run the following from the project root. This starts the actual bundled
receiver, confirms AirPlay and RAOP service discovery through Bonjour, and
stops it again without changing saved settings:

```powershell
$env:MIRRORME_LIVE_TEST = '1'
go test -run '^TestReceiverLiveStartupAndDiscovery$' -count=1 -v
Remove-Item Env:MIRRORME_LIVE_TEST
```

## Troubleshooting

- **My iPhone can't find this PC.** Confirm both devices are on the same
  Wi-Fi network (not one on Wi-Fi and one on cellular/a guest network), and
  that receiving is started (Mirror shows **Ready for your iPhone**,
  not **Not receiving**). Corporate/public Wi-Fi networks that isolate clients from
  each other will also block AirPlay discovery.
- **Setup keeps asking for Bonjour.** Make sure you approve the UAC prompt
  that appears after **Allow discovery** — if it's dismissed or times out,
  select **Allow discovery** again.
- **My iPhone stays on Connecting.** Stop Screen Mirroring on the phone,
  choose **Try again** in MirrorMe, then select this PC again on the phone.
  **Connection details** separates reported receiver state from video
  arrival and provides a copyable activity summary.
- **Video arrived but no screen opens.** In Settings, open **Picture & sound**,
  expand the advanced options, turn off hardware acceleration, save, and
  reconnect. A video pipeline failure is shown as an error rather than a
  successful mirroring session.
- **The receiver download fails.** Keep an internet connection for setup,
  cancel and retry. Failed hashes, incomplete ZIPs, and failed decoder checks
  are not installed. Runtime files are cached under
  `%LOCALAPPDATA%\MirrorMe\receiver`; settings remain in `%APPDATA%`.
- **The receiver times out.** Read the error on Home, confirm **Bonjour
  Service** is running in Windows Services, and try again. Allow the
  receiver through Windows Firewall on your trusted private network;
  do not disable the firewall.
- **An old uxplay-windows icon is still present.** Quit the standalone
  `uxplay-windows` application. Current MirrorMe builds never launch it.
- **Video is choppy or audio is out of sync.** Try lowering the resolution
  or frame rate in Settings, or move closer to your Wi-Fi router.
- **Where are my settings stored?** `%APPDATA%\MirrorMe\settings.json` —
  Help & about has **Copy path** and **Open folder** under Settings & support files.

## License

MirrorMe's own source code is licensed under the [MIT License](LICENSE).
The native receiver uses GPLv3 UxPlay with a small adapter and integration
changes. Its libraries retain their respective licenses; see
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for full attribution before
redistributing this app.

## Credits

- [UxPlay](https://github.com/FDH2/UxPlay) — the open-source AirPlay
  mirroring receiver MirrorMe manages.
- [leapbtw/libuxplay](https://github.com/leapbtw/libuxplay) — the
  Windows-compatible UxPlay library used by the background receiver.
- [leapbtw/uxplay-windows](https://github.com/leapbtw/uxplay-windows) — the
  source of the existing bundled multimedia runtime and Bonjour installer.
- [Wails](https://wails.io) — the Go + web application framework MirrorMe is
  built on.
