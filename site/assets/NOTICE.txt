# Third-Party Notices

The Go application and `frontend\` code are covered by the root MIT
[`LICENSE`](LICENSE). The native receiver and its dependencies are licensed
separately. The MIT license does not relicense any third-party component.

## Background AirPlay receiver

`engine\mirrorme-receiver.exe` uses UxPlay through the Windows-compatible
[leapbtw/libuxplay](https://github.com/leapbtw/libuxplay) library, pinned to
commit `437f37514257d9cb513ac7fbdee743b4da85852e`. This is the library
revision used by the published `uxplay-windows` release `2.0.0.1736`.
The original upstream project is [FDH2/UxPlay](https://github.com/FDH2/UxPlay).

The receiver is GPLv3 software. MirrorMe's native adapter and build inputs
are in `receiver\`, with the build entry point in
`scripts\build-receiver.ps1`. The integration differs from the upstream
desktop application: there is no Qt control window or tray icon; it accepts
arguments directly and provides process-pipe status and shutdown control.
Consult the receiver's source and retained license notices for its changes.

MirrorMe does not launch or package the `uxplay-windows.exe` desktop wrapper
or its Bluetooth-beacon executable. Those files may still exist in the
original development-time `engine\` bundle but are excluded during packaging.

## Multimedia and discovery libraries

The public preview ZIP contains MirrorMe and its custom GPL receiver, but
**does not redistribute the upstream DLL bundle or Bonjour installer**.
On explicit first-run consent, the application downloads that archive directly
from its publisher, verifies its exact hash, excludes the separate desktop
applications, and validates its decoder. The pin is in `receiver\runtime.json`.

The optional development/runtime download originates from the unmodified x64
`uxplay-windows` release `2.0.0.1736`:
<https://github.com/leapbtw/uxplay-windows/releases/tag/2.0.0.1736>.
The original distribution's notices are retained in `engine\LICENSE.rtf`.
Any additional native build dependencies are recorded by the receiver build.

| Component | License information | Source |
|---|---|---|
| UxPlay | GPLv3 | <https://github.com/FDH2/UxPlay> |
| mDNSResponder / dnssd | BSD-3-Clause / Apache-2.0, as specified per source file | <https://github.com/apple-oss-distributions/mDNSResponder> |
| GStreamer and plugins | LGPL and component-specific third-party terms | <https://gstreamer.freedesktop.org/> |
| FFmpeg and codec libraries | LGPL or GPL depending on the library and build configuration | <https://ffmpeg.org/> |
| x264 / x265 libraries | GPL; see the respective project terms | <https://www.videolan.org/developers/x264.html>, <https://www.videolan.org/developers/x265.html> |
| OpenSSL | Apache-2.0 for OpenSSL 3 | <https://www.openssl.org/> |
| Qt 6 libraries retained from the original bundle | LGPL/GPL or commercial terms; not used by MirrorMe's receiver | <https://www.qt.io/licensing/> |

Other bundled libraries retain their original licenses. This table is a
summary, not a complete bill of materials or a legal determination about
distribution.

## Go and frontend dependencies

| Component | License | Source |
|---|---|---|
| Wails v2 | MIT | <https://github.com/wailsapp/wails> |
| Vite | MIT | <https://github.com/vitejs/vite> |
| Go and golang.org/x/sys | BSD-3-Clause | <https://go.dev/> |
| Postrboard CSS 2.0.0 | MIT | <https://github.com/burkeholland/postrboard-design> |
| Lucide 1.39.0, including Feather-derived icons | ISC / MIT | <https://lucide.dev>, <https://github.com/feathericons/feather> |

The Postrboard stylesheet is vendored in
`frontend\src\vendor\postrboard.css` from
<https://burkeholland.github.io/postrboard-design/postrboard.css>.
Its SHA-256 is
`d5e7a983b3b35413223b6eebc564c79fd7d50e8e693c13b9d7e22eabeccacade`.
The application uses Windows system fonts instead of requesting web fonts.

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

The matching `MirrorMe-receiver-source.zip` release asset contains the custom
adapter, both maintained patches, the build scripts and SDK pins, the original
video fixture, and a Git bundle of the exact upstream source. The build script
can clone that bundle without fetching the library from a moving branch.
The public Windows ZIP includes the receiver's GPL text and aggregated Go
dependency license notices. No closed-source restrictions are imposed on
modifying or replacing the separately licensed receiver.

Provide the corresponding source for GPL/LGPL components as required by
their licenses, including the exact revisions, local modifications, and
necessary build scripts. General upstream repository links alone do not
establish compliance for a particular binary.

Keep all required copyright and license notices, verify the enabled codec
licenses, and review any application-store or signing requirements before
publication. This local build has not been certified for an app store.
