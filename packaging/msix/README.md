# MirrorMe MSIX package

`scripts/build-msix.ps1` creates the x64 MSIX package from the production
`MirrorMe.exe` build. The package includes the application, Windows assets,
privacy information, license terms, third-party notices, and corresponding
source links.

The default identity is only for local development:

```powershell
.\scripts\build-msix.ps1
```

For Microsoft Store submission, reserve the product in Partner Center and use
the exact package identity values shown under **Product management > Product
identity**:

```powershell
.\scripts\build-msix.ps1 `
  -StoreSubmission `
  -IdentityName '<Partner Center package identity name>' `
  -Publisher '<Partner Center publisher ID>' `
  -PublisherDisplayName '<Partner Center publisher display name>' `
  -ProductDisplayName '<reserved Store product name>'
```

Store submission MSIX packages are intentionally unsigned. Microsoft signs the
package after certification. A package distributed outside the Store must be
signed with a certificate whose subject exactly matches the manifest publisher.

Microsoft does not allow an MSIX version whose first component is zero. Unless
`-PackageVersion` is supplied, the build maps application version `0.2.5` to
package version `1.2.5.0` by adding one to the application major version. This
keeps package versions monotonic while MirrorMe uses pre-1.0 application
versions. The executable and product UI continue to report `0.2.5`.

The package targets Windows 11 x64 and includes the self-contained desktop
casting helper and its license notices. Its startup task is declared in the
manifest and uses the Windows packaged startup API, so it remains valid across
Store-managed upgrades.

The manifest also declares inbound TCP and UDP firewall rules for `MirrorMe.exe`
and `sender\MirrorMe.Sender.exe`. Windows applies them when the package is
installed, so Store users are not asked to allow network access, and the rules
follow the app across updates. `build-msix.ps1` fails if they are missing.
