# MirrorMe privacy notice

Effective September 15, 2026. This notice describes the native-receiver
Windows preview, versions 0.2.3 and later.

## Screen and audio

MirrorMe receives the screen and audio you choose to mirror from your
iPhone over your local network. It decodes that content in memory and
displays or plays it on your PC. MirrorMe does not provide a recording
feature or upload screen or audio content to the publisher.

Mirrored content can include notifications and other personal information
visible on your phone. Anyone who can see or hear your PC can see or hear
that content. Stop Screen Mirroring on the iPhone or stop receiving in
MirrorMe to end the session.

## Discovery and connections

MirrorMe advertises its receiver name and connection information on your
local network so an iPhone can discover it. The default receiver name is
based on your PC's hostname; you can change it in Settings. Other devices
on that network may see the advertised receiver.

Use a trusted private network and enable the optional pairing PIN when
appropriate. MirrorMe does not require an Apple account or a publisher
account.

## Files on your PC

MirrorMe stores preferences in `%APPDATA%\MirrorMe\settings.json`. These
include the receiver name, display and audio preferences, and the optional
pairing PIN when configured. Treat this file as private.

The receiver's persistent discovery identity and cryptographic key
material are stored under `%APPDATA%\MirrorMe\identity`. Do not share these
files.

Verbose logging is off by default. If you enable it, MirrorMe writes
structured diagnostic records under `%APPDATA%\MirrorMe\logs`. Records
include timestamps, app version, receiver state, failure indicators, and
selected picture/audio settings. They do not include screen or audio
content, device names, PINs, raw network packets, or raw error messages.
Logs rotate between two files of up to 1 MiB each. Turning logging off does
not delete existing logs.

MirrorMe does not automatically send these files to the publisher.
Uninstalling the portable application may leave its settings, identity,
logs, and WebView2 data on the PC. After quitting MirrorMe, you can remove
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
