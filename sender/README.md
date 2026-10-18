# Desktop AirPlay sender (preview)

The Cast desktop workspace uses a separate, self-contained Windows x64 helper.
It integrates WinPlay Core and Capture, pinned by `dependency.json`, not WinPlay's
tray app or CLI. The existing native receiver is unchanged. No .NET installation,
Bonjour service, FFmpeg executable, or runtime download is required by users.

**Requirements:** Windows 11 22H2 or later, an active, unrotated primary display
on a Direct3D 11 adapter, and a screen-capable AirPlay receiver on the same IPv4
LAN. Apple TV is the initial target; compatibility with other AirPlay generations
and vendors is not guaranteed. The preview shares primary-display SDR video at
30 fps, fitted to the target's advertised resolution, including the Windows
mouse pointer. It does not send desktop
audio, offer an extended desktop, select other monitors, capture protected video,
or automatically reconnect/start sharing. Discovery also lists audio-only targets,
but they cannot be selected for screen sharing.

Select a target, then **Share primary display**. If prompted, enter the four-digit
code shown on the TV. Selecting a target or discovering devices never captures
the screen. Pairing credentials are DPAPI-encrypted for the current Windows user,
written atomically under `%APPDATA%\MirrorMe\sender`, and verified on reconnect.
**Forget pairing** removes that target's credentials. Fixed AirPlay passwords and
legacy pairing modes are not implemented; enable code-based access on the TV.

**Stop sharing**, the tray's **Stop sharing desktop**, and Quit all stop capture.
Closing the control window continues sharing in the tray, like receiving.
Parent-pipe EOF and the Windows kill-on-close job also terminate the helper.
There is no automatic retry of a capture after an error.
Stopping or cancelling a sharing attempt from the app or tray refreshes the
target list after the capture process exits. The UI retains the selected target
if it is still discovered. This never reconnects or resumes capture; cancelling
discovery and quitting do not start another scan.

## Build

Run `.\scripts\build-sender.ps1` (also called by `build-app.ps1`). Build-time
requirements are Git and the .NET 8 SDK or later. NuGet dependencies are locked
in `packages.lock.json`. Keep the entire `build\bin\sender` directory alongside
`MirrorMe.exe`; receiving still works if that directory is absent.

The script checks the exact upstream commit and patch, publishes the helper,
retains the pristine upstream archive, local changes, wrapper sources, original
NuGet archives (including runtime/reference packs), and build instructions under
`build\native-sender\source`, and writes hashes to
`sender.build.json`. The checked-in patch:

- selects the actual primary monitor and refuses unsupported rotation;
- composites separate DXGI hardware pointers before scaling/encoding, including
  color transparency, monochrome AND/XOR masks, masked-color cursors, pointer-only
  moves, and clipping at monitor edges without leaving trails or drawing a
  second software cursor; an invalid, oversized, or missing pointer shape hides
  the cursor instead of ending the share;
- propagates capture and network failures, including a bounded feedback timeout;
- counts video only after completed TCP writes;
- never discards encrypted packets (their nonce sequence must remain intact);
- explicitly initializes the video cipher nonce.

For a Linux build check after fetching and patching the pinned sources:

```sh
dotnet build sender/MirrorMe.Sender.csproj -c Release -p:EnableWindowsTargeting=true -p:RestoreLockedMode=true
```

This checks compilation, **not** Windows capture or physical Apple TV playback.
After building, `node --test sender/tests/worker.test.mjs` checks the actual helper
process's command parsing, cancellation and six-second discovery. Those checks
send local mDNS queries but never start desktop capture. On Linux they run the
managed assembly against the installed .NET runtime. Portable Go lifecycle
checks can be run with
`go test -race sender.go engine_output.go sender_test.go sender_portable_test.go`.

Before release, verify discovery (including two targets with the same name),
wrong/correct/expired PIN, reconnect with saved credentials, Forget pairing,
primary display on a secondary adapter, real TV video, receiver rejection,
network loss, screen lock, cancellation at every stage, tray Stop, Quit, parent
crash, and simultaneous iPhone receiving on Windows. Also check arrow, I-beam,
hand, enlarged/accessibility and inverted cursors on the TV, movement over an
otherwise static desktop, transitions onto other monitors, and automatic target
refresh after disconnecting. Do not call the feature
device-verified until this checklist is completed.

## Protocol and failure handling

The Go host sends versioned JSON lines over stdin; stdout contains typed state
events only. PINs never appear in process arguments or logs. Discovery is a fresh
six-second scan, bounded to 64 resolved targets, excluding this PC. The host
accepts only a server-side discovered target ID and requires refreshing results
older than one minute. A separate helper invocation handles pairing, negotiation,
capture/encoding, encrypted AirPlay mirroring transport, and teardown.

DXGI pointer position is the shape's top-left in desktop pixels, not its hotspot.
Only the clipped cursor rectangle is mapped to the CPU for blending; the desktop
remains on the GPU. Each acquired frame starts from the original DXGI image, so
moving or hiding a pointer restores the old background. Composition happens
before BGRA-to-NV12 conversion and scaling, so the cursor and desktop stay aligned.
`DesktopPointerTests` in the patched upstream test project exercises the shared
pixel-composition code without requiring a Windows GPU.

The UI reports streaming only after a video packet is written, not after a
successful handshake. This does not claim that the TV has displayed the frame.
Discovery/connection/PIN waits are bounded; no video progress for 12 seconds
ends capture with an error. The host kills a helper that does not stop promptly.

## Licensing and distribution

WinPlay is GPL-3.0-or-later; its FairPlay work credits the LGPL-3.0-or-later
doubletake project. Preserve upstream copyrights, LICENSE and
THIRD_PARTY_NOTICES.md, the pinned source, this wrapper, the patch, and build inputs
with distributions. MirrorMe's MIT grant does not relicense those components.
NuGet libraries and the bundled .NET runtime have their own notices; retain their
full license/third-party notices too. The build receipt remains
`distributionApproved=false`: successful publishing and the retained WinPlay
archive alone are not a complete corresponding-source/license release package.
