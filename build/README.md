# Build Directory

The build directory is used to house all the build files and assets for your application. 

The structure is:

* bin - Output directory
* darwin - macOS specific files
* windows - Windows specific files

## Mac

The `darwin` directory holds files specific to Mac builds.
These may be customised and used as part of the build. To return these files to the default state, simply delete them
and
build with `wails build`.

The directory contains the following files:

- `Info.plist` - the main plist file used for Mac builds. It is used when building using `wails build`.
- `Info.dev.plist` - same as the main plist file but used when building using `wails dev`.

## Windows

The `windows` directory contains the manifest and rc files used when building with `wails build`.
These may be customised for your application. To return these files to the default state, simply delete them and
build with `wails build`.

- `icon.ico` - The application and tray icon, generated from `site/assets/mark.svg`.
  Do not edit it separately from the website icon.
- `installer/*` - The files used to create the Windows installer. These are used when building using `wails build`.
- `info.json` - Application details used for Windows builds. The data here will be used by the Windows installer,
  as well as the application itself (right click the exe -> properties -> details)
- `wails.exe.manifest` - The main application manifest file.

## Shared application icon

`site/assets/mark.svg` is the source for the website, app title bar, About page,
Windows executable/tray and receiver video-window icons. To regenerate the
checked-in SVG copy, PNG and multi-size ICO files from the repository root:

```powershell
python -m pip install -r scripts\icon-requirements.txt
python scripts\generate-icon.py
python scripts\generate-icon.py --check
```

The renderer dependencies are build tools only; they are not installed with
MirrorMe. The ICO includes 16 through 256 pixel sizes for Windows display scaling.