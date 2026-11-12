# MirrorMe privacy notice

Effective September 15, 2026. This notice describes the native-receiver
Windows preview, versions 0.2.3 and later.
Updated October 17, 2026 to cover the source-build desktop casting preview.

## Screen and audio

MirrorMe receives the screen and audio you choose to mirror from your
iPhone over your local network. It decodes that content in memory and
displays or plays it on your PC. MirrorMe does not provide a recording
feature or upload screen or audio content to the publisher.

Mirrored content can include notifications and other personal information
visible on your phone. Anyone who can see or hear your PC can see or hear
that content. Stop Screen Mirroring on the iPhone or stop receiving in
MirrorMe to end the session.

When you choose **Cast desktop > Share primary display**, MirrorMe captures
your Windows primary display in memory and sends encrypted screen video to
the selected AirPlay target on your local network. This includes notifications
and any personal information visible on that display. This sender preview does
not capture desktop audio or record to disk. Discovery and target selection
alone do not start capture.

Anyone watching the target display can see the shared desktop. **Stop sharing**,
the tray's **Stop sharing desktop**, or Quit ends capture. Closing the control
window keeps sharing in the tray. Desktop sharing does not start automatically
or reconnect automatically after a failure.

## Discovery and connections

MirrorMe advertises its receiver name and connection information on your
local network so an iPhone can discover it. The default receiver name is
based on your PC's hostname; you can change it in Settings. Other devices
on that network may see the advertised receiver.

Use a trusted private network and enable the optional pairing PIN when
appropriate. MirrorMe does not require an Apple account or a publisher
account.
Opening Cast desktop also browses local AirPlay service advertisements to list
targets. Their names and network addresses are shown locally, not uploaded.

## Files on your PC

MirrorMe stores preferences in `%APPDATA%\MirrorMe\settings.json`. These
include the receiver name, display and audio preferences, and the optional
pairing PIN when configured. Treat this file as private.

The receiver's persistent discovery identity and cryptographic key
material are stored under `%APPDATA%\MirrorMe\identity`. Do not share these
files.

Desktop sender pairing identities are stored in `%APPDATA%\MirrorMe\sender`
in files encrypted with Windows DPAPI for the current user. PINs are sent to the
bundled helper through its private input pipe, not process arguments or logs.
**Forget pairing** removes the selected target's saved credentials. These files
are separate from receiving settings and identity; do not share them.

Verbose logging is off by default. If you enable it, MirrorMe writes
structured diagnostic records under `%APPDATA%\MirrorMe\logs`. Records
include timestamps, app version, receiver state, failure indicators, and
selected picture/audio settings. They do not include screen or audio
content, device names, PINs, raw network packets, or raw error messages.
Logs rotate between two files of up to 1 MiB each. Turning logging off does
not delete existing logs.

MirrorMe does not automatically send these files to the publisher.
Uninstalling the portable application may leave its settings, identity,
sender pairing credentials, logs, and WebView2 data on the PC. After quitting MirrorMe, you can remove
its local data if you no longer need it. Removing the identity generates a
new receiver identity on a later launch.

## Windows and external websites

The interface uses Microsoft's WebView2 runtime, which may maintain its
own browser/runtime data and receive Microsoft updates. Windows, WinGet,
and WebView2 operate under their respective privacy terms.

Opening help, source, or credit links launches external websites in your
browser. GitHub hosts our website, downloads, source code, and issue
tracker. Requests to those services are governed by their privacy
policies:

- [GitHub privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement)
- [Microsoft privacy statement](https://privacy.microsoft.com/privacystatement)

## Support

Questions can be raised in the
[MirrorMe issue tracker](https://github.com/burkeholland/mirror-me/issues).
Issues are public: do not attach personal screen content, settings files,
pairing keys, or PINs. Review any diagnostic logs before sharing them.

## Screenshots and recordings

Only when you press **Screenshot** or **Record** in the mirror window's
toolbar, MirrorMe saves the phone picture to the folders chosen in
**Settings > App > Capture folders**. By default these are `Pictures\MirrorMe`
(PNG) and `Videos\MirrorMe` (MP4, no audio) on this PC. Screenshots are also copied to
the clipboard. Files stay local; MirrorMe never uploads them.
