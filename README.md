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
The website shows static screenshots with example data, not a device test.

[Explore the app interface](https://burkeholland.github.io/mirror-me/) |
[Download the Windows preview](https://github.com/burkeholland/mirror-me/releases/download/v0.2.3-preview.1/MirrorMe-0.2.3-windows-x64.zip) |
[Matching source and checksums](https://github.com/burkeholland/mirror-me/releases/tag/v0.2.3-preview.1)

The current **0.2.3 source build** has a built-in receiver. It uses Windows
media and discovery APIs and statically linked protocol/audio libraries:
no UxPlay executable, GStreamer bundle, Bonjour installation, or receiver
download is needed. It is not a clean-room AirPlay implementation.

**The public 0.2.3 preview is self-contained.** Extract the Windows ZIP and
open `MirrorMe.exe`. It is unsigned, so Windows may show an unknown-publisher
warning. Compare `SHA256SUMS.txt` on the release page before running it.
The same release includes the full license notices and
`MirrorMe-0.2.3-source.zip`, with the frozen application source, matching
dependency sources, build recipes and a verified `REBUILD.ps1`.
The old external-receiver preview remains retired.

## Features in the current source build

- **Wireless AirPlay mirroring** — your iPhone finds MirrorMe over your local
  Wi-Fi network exactly like it finds an Apple TV; no pairing app or cable
  required.
- **A focused Mirror workspace** — one connection view, the PC name your
  iPhone sees, and the right action for the current state. Optional logging
  is in **Settings > App > Troubleshooting**.
- **A separate, branded video window** — the control window manages receiving
  and settings; your iPhone appears in **MirrorMe - iPhone screen**, with the
  MirrorMe icon. Video is not embedded in the controls page.
  Frames and letterboxing are assembled off-screen and copied together,
  rather than briefly clearing the visible picture to black between frames.
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
    rate, audio playback, and optional H.265/HEVC when Windows has a compatible
    decoder. This native preview uses software video decoding, not GPU decoding.
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
- **Built-in receiving** — Windows handles discovery; there is no receiver
  download or Bonjour setup step. Both discovery services must register
  before the app reports ready. Windows Firewall still needs to allow the app
  on your trusted private network.
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
- The application needs no internet connection at runtime.
- Windows N/KN editions may need Microsoft's Media Feature Pack. Optional
  HEVC support depends on an installed Windows decoder.

To build from source you'll also need:

- [Go](https://go.dev/) 1.25 or later
- [Node.js](https://nodejs.org/) 20.19+ or 22.12+ (required by Vite 7)
- The [Wails v2 CLI](https://wails.io/docs/gettingstarted/installation) (`go install github.com/wailsapp/wails/v2/cmd/wails@v2.15.0`)
- An x64 **UCRT** MinGW toolchain (tested: Strawberry GCC 13.2.0 at
  `C:\Strawberry\c\bin`), CMake, Ninja, Python, Git for Windows with Bash,
  GNU Make, and tar. An MSVCRT-only compiler cannot consume the pinned SDK.
- Internet for the pinned source/build dependencies on the first build.

## Getting started

```powershell
# Install the Wails CLI (one time)
go install github.com/wailsapp/wails/v2/cmd/wails@v2.15.0

# Restore the frontend dependencies
npm ci --prefix frontend

# Build native libraries, the Windows app, and check single-file startup
.\scripts\build-app.ps1

# Later app-only rebuilds, after native libraries are unchanged
.\scripts\build-app.ps1 -SkipNativeBuild

# Live frontend development after native libraries are built
wails dev
```

The build produces `build\bin\MirrorMe.exe`; that executable does not require
an `engine` folder. Windows and WebView2 remain platform requirements.
Close an existing app from its tray before replacing its executable, or use
`-OutputName MirrorMe-native.exe` to build separately.

The script verifies the production archive, forces fresh Go linking, audits
DLL imports, and runs the worker from an otherwise empty folder with a
Windows-only PATH. A protocol-only test stub cannot pass as a production build.
Use the script after native changes: ordinary Go caching does not track
external static archive contents. See `native\INTEGRATION.txt` and
`native\AUDIO-NOTICES.txt` for component builds and retained source licenses.

There is no external receiver fallback, runtime downloader, or service
installer. Do not publish a native binary without its matching
corresponding-source and license package.

`collect-native-sources.ps1` collects pinned native sources, exact MSYS2
recipes/patches, and compiler-runtime notices into `build\native-sources\bundle`.
Its `-Offline` mode rechecks the cached inputs. This native source inventory
is not yet a complete application distribution package: publication must also
bind the final executable to the matching application/frontend sources and
dependency notices. The app build writes a `.build.json` fingerprint beside
its executable and deliberately does not mark the build approved for release.

## Using MirrorMe

1. Launch `MirrorMe.exe`. On first run, choose the name this PC should
   show on your iPhone and select **Continue**.
   The current source build starts its built-in receiver directly.
2. Allow MirrorMe through Windows Firewall on your trusted private network
   if Windows prompts. Do not disable the firewall.
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
| Picture & sound, advanced | Windows video decoder | The current native preview uses software decoding. |
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

### Troubleshooting logs

In **Settings > App > Troubleshooting**, turn on **Verbose logging** and save
before reproducing a problem. This takes effect without restarting mirroring.
Use **Open logs folder** or **Copy logs path** to find
`%APPDATA%\MirrorMe\logs\verbose.jsonl` and its rotated backup
`verbose.jsonl.1`. Each file is limited to 1 MiB.

The JSON-lines records include UTC time, application version, receiver state,
video-arrival and error flags, and selected picture/audio settings. Agents can
read these files to trace connection, pause, resume and shutdown events.
They do not contain screen/audio content, pairing codes, device identities,
raw errors, or network packet dumps. Logging is off by default. Turning it off
stops writing but retains existing files; delete those files to remove them.
A file-writing failure appears in Settings without interrupting mirroring.

## How mirroring works

The default Windows x64 build runs the same executable with
`--receiver-worker` for receiving. The worker starts before Wails, so it
does not create another tray or control window. This separates decoder and
driver failures from the interface without installing another program.
Versioned JSON carries settings and status over private process pipes;
pairing codes are not command-line arguments or lifecycle log markers.

The new native host uses Windows DNS-SD, Media Foundation video decoding,
an owned Windows video window, and WASAPI audio output. FFmpeg's selected
audio decoders are compiled in. Low-level licensed AirPlay, pairing, and
crypto compatibility code remains derived from the pinned libuxplay source;
UxPlay's orchestration and GStreamer renderers are not compiled.

There is **one tray icon**. Quitting MirrorMe stops the worker. A stable
receiver identity and protected pairing key are stored beneath
`%APPDATA%\MirrorMe\identity`; a malformed key is reported, not silently
replaced. PC names fit the 50-byte discovery-label budget without splitting
Unicode characters. Automatic video settings currently select 1080p/60 FPS
as requested limits, not a promise of delivered frame rate.

## Project structure

```
mirror-me/
├── app.go, config.go, engine*.go, security.go, ...   Go backend (Wails-bound App, settings, engine supervisor)
├── main.go                                            Entry point / window configuration
├── native/                                            Built-in Windows receiver, media, audio, tests and dependency pins
├── receiver/                                          Shared icon/video fixture and pinned protocol source checkout
├── frontend/src/                                      Vanilla JS/HTML/CSS UI (style.css, state.js, render.js, events.js, main.js)
├── build/                                             Wails build assets (icons, Windows manifest)
├── scripts/                                            Native/app builds, source collection and icon generation
└── wails.json                                          Wails project configuration
```

## Testing

The Go suite covers settings, worker commands/events, and real Windows
child-process startup, timeout, cancellation, failure, and cleanup:

```powershell
go vet ./...
go test -race ./...
```

For Windows CI without the native SDK, `go test -tags native_contracts ./...`
and `go vet -tags native_contracts ./...` exercise the same supervisor and
worker contracts with test fixtures. That tag supplies an explicit
unavailable-native stub, not a different receiver, and cannot produce a
working application. Production verification still requires the native build.

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

### Website app preview

The landing page shows static light/dark screenshots of the real desktop
frontend beside an example image. It does not embed a running app, simulate
connections, or expose interactive Settings. Only the page's theme switch and
links are interactive. Both windows stay side by side at widths of 768 pixels
and above; below that, only the app screenshot is shown at full width.

Regenerate screenshots on Windows with Edge after changing the frontend, then
check the generated site:

```powershell
npm --prefix frontend run build:site-preview
node --test .\site\tests\demo.test.mjs
node .\site\tests\browser-review.mjs
```

The screenshot builder runs the existing frontend browser checks using example
data, then writes two PNGs and `app-screenshots.json` into `site\assets`.
It does not modify the native app's `frontend\dist` bundle. The manifest ties
the screenshots to their source and asset hashes. Website browser checks cover
desktop/mobile layouts, static content, image loading, keyboard navigation,
themes, reduced motion, and use without JavaScript. Review images go to
`build\site-review`. The executable size shown is the uncompressed executable,
not the Windows ZIP size. Download links point to a specific verified preview;
matching source, full notices and checksums are on that release page.

Commit the source and generated assets together. `scripts\publish-site.ps1`
checks freshness and publishes the committed `site` subtree to `gh-pages`
without force-pushing. To check the deployed page:

```powershell
node .\site\tests\browser-review.mjs https://burkeholland.github.io/mirror-me/
```

### Device validation

These automated checks do not replace mirroring from a physical iPhone.
Device compatibility, video/audio synchronization, and protected-content
behavior need real-device testing before release.

The native components have original video/audio fixtures and real Windows
playback, discovery, lifecycle, malformed-input, and session-ordering checks:

```powershell
.\scripts\build-audio-codecs.ps1 -Test
.\scripts\build-native.ps1
.\native\tests\media_check.ps1
.\native\tests\media_flicker_check.ps1
.\native\tests\media_audio_check.ps1
$env:MIRRORME_NATIVE_BINARY = (Resolve-Path .\build\bin\MirrorMe.exe).Path
go test -run '^TestNativeApplicationRunsFromOneFile$' -count=1 -v
Remove-Item Env:MIRRORME_NATIVE_BINARY
```

These include real H.264 window pixels, landscape/portrait 4K, real AAC-ELD
and ALAC audio, and barriers preventing old frames from reviving ended
sessions. They do not establish physical-device interoperability.

### Real-iPhone release checklist

These items require a physical device and are not implied by a passing UI
review or successful network discovery:

The user confirmed physical iPhone video in native 0.2.0, but reported severe
flickering. The user confirmed that version 0.2.1's buffered presentation removes
the flickering, then reported latency and failure to resume after locking the phone.
Version 0.2.2 preserves video decoder references across pauses and clock corrections,
hides paused/disconnected video, and resumes on fresh video even without a resume
header. Controls show a distinct paused state instead of claiming live playback.
It also reuses decoder output storage and skips color conversion for outdated
queued frames without skipping their reference decoding. Original 1080p/60 FPS
fixtures cover receiver-side timing, backlog recovery and inter-frame resume;
these measurements exclude phone encoding, Wi-Fi and monitor scan-out.
Real-phone lock/unlock and latency retesting remain required. Sustained playback
and broad device reliability are not established by generated-frame checks.

- [ ] Connect an iPhone and confirm that its Home Screen actually appears.
- [ ] Rotate the phone, open a photo, and confirm that the video window updates.
- [ ] Play unprotected video and confirm picture/audio synchronization.
- [ ] Enable a pairing code and verify the prompt on the iPhone.
- [ ] Stop mirroring from both devices, then reconnect.
- [ ] Exercise sleep/wake and a network interruption, and confirm recovery.
- [ ] Quit MirrorMe and confirm that its receiver and discovery records stop.

## Troubleshooting

- **My iPhone can't find this PC.** Confirm both devices are on the same
  Wi-Fi network (not one on Wi-Fi and one on cellular/a guest network), and
  that receiving is started (Mirror shows **Ready for your iPhone**,
  not **Not receiving**). Corporate/public Wi-Fi networks that isolate clients from
  each other will also block AirPlay discovery.
- **My iPhone stays on Connecting.** Stop Screen Mirroring on the phone,
  choose **Try again** in MirrorMe, then select this PC again on the phone.
  Enable **Verbose logging** in **Settings > App > Troubleshooting** before
  reproducing a persistent problem.
- **Video arrived but no screen opens.** In Settings, open **Picture & sound**,
  expand the advanced options, turn off HEVC, save, and
  reconnect. Check the error shown on the Mirror screen.
  A video failure is shown as an error rather than a
  successful mirroring session.
- **Audio plays but video never starts.** Reconnect from the iPhone's Screen
  Mirroring menu and check the status on the Mirror screen. The native build
  distinguishes accepted packets from actually displayed frames and reports
  decoder/display failures explicitly. Protected video may not support mirroring.
- **The receiver times out.** Read the error on Home and try again. Allow
  MirrorMe through Windows Firewall on your trusted private network;
  do not disable the firewall.
- **Video is choppy or audio is out of sync.** Try lowering the resolution
  or frame rate in Settings, or move closer to your Wi-Fi router.
- **Where are my settings stored?** `%APPDATA%\MirrorMe\settings.json` —
  Help & about has **Copy path** and **Open folder** under Settings & support files.

## License

MirrorMe's own source code is licensed under the [MIT License](LICENSE).
The combined self-contained executable links licensed AirPlay code and is
subject to the applicable GPL terms, including corresponding-source obligations.
The MIT grant for MirrorMe's own Go/frontend source remains intact.
Its libraries retain their respective licenses; see
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for full attribution before
redistributing this app.

## Credits

- [UxPlay](https://github.com/FDH2/UxPlay) — upstream AirPlay compatibility work.
- [leapbtw/libuxplay](https://github.com/leapbtw/libuxplay) — the
  pinned source of retained low-level protocol compatibility code.
- [FFmpeg](https://ffmpeg.org) — statically linked audio decoders in the native build.
- [Wails](https://wails.io) — the Go + web application framework MirrorMe is
  built on.
