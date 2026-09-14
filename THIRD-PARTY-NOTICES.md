# Third-Party Notices

The Go application and `frontend\` code are covered by the root MIT
[`LICENSE`](LICENSE). The native receiver and its dependencies are licensed
separately. The MIT license does not relicense any third-party component.

This notice covers the current self-contained source build, the static
website, and development tools. The external-receiver build and its download
have been retired; only the self-contained implementation is maintained.

## Self-contained native source build

The default Windows x64 build links the new `native\` host, Windows media and
discovery integration, and licensed protocol/codec libraries into the same
application executable. It does not launch UxPlay, load GStreamer, or install
Bonjour. Windows platform libraries and WebView2 remain platform requirements.

The low-level AirPlay protocol implementation remains derived from the pinned
`leapbtw/libuxplay` source below; it is not a clean-room implementation.
The original protocol copyrights and licenses are retained. OpenSSL and
libplist are statically linked; audio decoding uses the separately pinned
codec build. Native build manifests and notices record those inputs.

| Component in the native build | License information | Source / exact-input record |
|---|---|---|
| libuxplay 1.73.6 protocol and PlayFair code | GPL-3.0-or-later; individual protocol files LGPL-2.1-or-later | [Pinned protocol and SDK inputs](native/dependencies.json), commit `437f37514257d9cb513ac7fbdee743b4da85852e`; [upstream](https://github.com/leapbtw/libuxplay) |
| llhttp, retained with the protocol source | MIT; Copyright Fedor Indutny, 2018 | Included in the pinned protocol tree; [native source notices](native/NATIVE-SOURCE-NOTICES.txt) |
| OpenSSL 3.6.1 (`libcrypto`, MSYS2 package 3.6.1-1) | Apache-2.0; MSYS2 path-tool additions carry CC0 notices | [Source and recipe pins](native/source-dependencies.json); [upstream](https://github.com/openssl/openssl) |
| libplist 2.7.0 and libcnary (MSYS2 package 2.7.0-3) | LGPL-2.1-or-later; GPL utilities in the source archive are not linked into MirrorMe | [Source and recipe pins](native/source-dependencies.json); [upstream](https://github.com/libimobiledevice/libplist) |
| FFmpeg 8.0.1, `libavcodec` 62.11.100 and `libavutil` 60.8.100 | LGPL-2.1-or-later for the selected static audio build | [Audio pins and configuration](native/audio-dependencies.json); [full audio notices](native/AUDIO-NOTICES.txt) |
| GCC 13.2.0 `libstdc++`, `libgcc`, `libgcc_eh` | GPL-3.0-or-later with GCC Runtime Library Exception 3.1 | [Matched toolchain archives and source notices](native/NATIVE-SOURCE-NOTICES.txt) |
| MinGW-w64 11.0.1 UCRT and winpthreads | Component-specific permissive terms; preserve the complete MinGW runtime notice set and winpthreads MIT/BSD-style notices | [Runtime provenance and notice inventory](native/NATIVE-SOURCE-NOTICES.txt) |

The selected FFmpeg build enables audio decoders, not FFmpeg executables,
encoders, external codec libraries, or its GPL/nonfree options. This does not
change the GPL terms of the combined MirrorMe executable. Its audio-format
configuration also retains attribution to RPiPlay (Florian Draschbacher,
2019) and UxPlay (F. Duncanh, 2021-23), detailed in the audio notices.

Windows DNS-SD, Media Foundation, GDI and WASAPI are operating-system APIs,
not copies of Bonjour or GStreamer. The shared Microsoft WebView2 runtime
and Windows system fonts are supplied separately by Windows/Microsoft; this
repository does not bundle their runtime installers or font files.

**The combined native executable is subject to the applicable GPL terms.**
The root MIT grant still covers MirrorMe's own Go/frontend sources, not the
linked program as a whole. Distribution requires matching native and application
source, library source/build inputs, and the relevant license notices.
Do not treat a development SDK archive or a successful local build as proof
that a redistributable corresponding-source package is complete.

The detailed [native source notices](native/NATIVE-SOURCE-NOTICES.txt) and
[audio notices](native/AUDIO-NOTICES.txt) describe patches, source archives,
compiler-runtime notices and remaining release work. The native source
collector preserves the full upstream license texts and file-level notices;
the summary table above does not replace them.

## Go and frontend dependencies

| Component | License | Source |
|---|---|---|
| Wails v2.15.0 | MIT | <https://github.com/wailsapp/wails> |
| Go 1.25 and golang.org/x/sys v0.46.0 | BSD-3-Clause | <https://go.dev/>, <https://pkg.go.dev/golang.org/x/sys> |
| Postrboard CSS 2.0.0 | MIT | <https://github.com/burkeholland/postrboard-design> |
| Lucide 1.39.0, including Feather-derived icons | ISC / MIT | <https://lucide.dev>, <https://github.com/feathericons/feather> |

The Postrboard stylesheet is vendored in
`frontend\src\vendor\postrboard.css` from
<https://burkeholland.github.io/postrboard-design/postrboard.css>.
Its SHA-256 is
`d5e7a983b3b35413223b6eebc564c79fd7d50e8e693c13b9d7e22eabeccacade`.
The application uses Windows system fonts instead of requesting web fonts.

The exact Go dependency graph, including indirect Wails/WebView2 loader
dependencies, is in [go.mod](go.mod) and [go.sum](go.sum). Frontend package
versions and package license metadata are pinned in
[frontend/package-lock.json](frontend/package-lock.json). Preserve each
dependency's original notices when packaging a build; the short table is not
a substitute for the full transitive notice set.

## Static website and artwork

The website distributes Postrboard CSS and static PNG screenshots of the
desktop frontend. Those screenshots contain the app's Lucide/Feather-derived
icons and Postrboard styling; their copyright and license notices remain
applicable credits even though the website no longer loads the interactive
frontend or a browser-to-app simulation bridge.

The website's stylesheet is `site\assets\postrboard.css`, with the same
SHA-256 shown above. Website-specific credits and the full Postrboard,
Lucide and Feather license texts are kept in
[site/assets/NOTICE.txt](site/assets/NOTICE.txt).

`site\assets\mark.svg` (the monitor-and-phone app mark) and the mountain
illustration in `site\index.html` are original MirrorMe artwork covered by
the root license. The PNG/ICO app icons are generated from that SVG; they
are not a replacement license for Lucide icons used elsewhere in the UI.
Screenshot generation uses example data, not a recording of someone's phone.

## Build and test tools

These are development dependencies, not additional programs shipped inside
the MirrorMe executable or the static website.

| Component | License information | Use / source |
|---|---|---|
| Vite 7.3.6 | MIT core; its packaged dependencies retain their own notices | Frontend build and browser-test server; [upstream](https://github.com/vitejs/vite) |
| Pillow 12.2.0 | MIT-CMU; packaged third-party libraries retain their notices | PNG/ICO generation; [upstream license](https://github.com/python-pillow/Pillow/blob/12.2.0/LICENSE) |
| resvg-py 0.5.0 | MIT for the Python wrapper; Rust dependencies retain their own licenses | SVG rasterization; [upstream](https://github.com/baseplate-admin/resvg-py) |
| Microsoft Edge | Microsoft software license terms | Locally installed browser used to capture screenshots and run UI checks; not redistributed |
| Ittiam libxaac | Apache-2.0 | Test-only AAC-ELD fixture generation; [fixture notices and exact provenance](native/tests/audio_fixtures/NOTICE.txt) |

Pillow and resvg-py versions are pinned in
[scripts/icon-requirements.txt](scripts/icon-requirements.txt). Their installed
license files identify Pillow's MIT-CMU terms and resvg-py's MIT notice
(Copyright 2024, baseplate-admin). Redistributed copies of these development
tools require their own full license and dependency notices.

The original generated audio-test signals are dedicated under CC0, as recorded
in the fixture notices. Neither libxaac nor its encoder is linked into the
production application. The fixture notice also preserves the full Apache
license and the upstream source/configuration provenance.

## Frontend and website license texts

### Postrboard

```text
MIT License

Copyright (c) 2026 Burke Holland

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Lucide

```text
ISC License

Copyright (c) 2026 Lucide Icons and Contributors

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
```

Some Lucide icons used here derive from Feather and also carry this notice:

```text
The MIT License (MIT)

Copyright (c) 2013-present Cole Bemis

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Before distributing a release

For the **legacy `v0.1.0-preview.1` release**, the matching
`MirrorMe-receiver-source.zip` release asset contains the custom
adapter, both maintained patches, the build scripts and SDK pins, the original
video fixture, and a Git bundle of the exact upstream source. The build script
can clone that bundle without fetching the library from a moving branch.
The public Windows ZIP includes the receiver's GPL text and aggregated Go
dependency license notices. No closed-source restrictions are imposed on
modifying or replacing the separately licensed receiver.

That legacy source ZIP is **not** the corresponding-source package for the
new self-contained executable. Before publishing a native binary, freeze the
complete app/native source revision, bind the binary hash to its matching
source and rebuild inputs, include all applicable Go/frontend/native
dependency notices, and satisfy the applicable GPL/LGPL source and relinking
requirements. Updating this document does not approve a binary release or
change the distribution gate in `native\dependencies.json`.

Provide the corresponding source for GPL/LGPL components as required by
their licenses, including the exact revisions, local modifications, and
necessary build scripts. General upstream repository links alone do not
establish compliance for a particular binary.

Keep all required copyright and license notices, verify the enabled codec
licenses, and review any application-store or signing requirements before
publication. This local build has not been certified for an app store.
