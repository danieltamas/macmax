# Build, release, install and update

MacMax ships the way Bton does (github.com/danieltamas/bton): GitHub releases, a reproducible zip,
a one-line installer that is also bundled in the app for in-app Update. Start from Bton's current
`scripts/` and `install.sh` on `main`, renamed (`Bton` -> `MacMax`, `bton` -> `macmax`, `BTON_` ->
`MACMAX_`), and remove what is Bton-specific (the `gh` prerequisite, agent CLI linking).

## Why not the Mac App Store

App Store apps must run in the App Sandbox, which forbids reading other processes' memory and CPU,
running `nettop`, `scutil` and `docker`, and acting on other apps. That is the whole product. Also no
Windows or Linux: SwiftUI, `MenuBarExtra` and the macOS data sources do not port.

## Versions

- Semantic versions, `0.x.y` until the owner calls 1.0. Tag `vX.Y.Z` (annotated) on `main`.
- The version is the owner's call, offered as a decision with a recommendation.
- `CFBundleShortVersionString` = `X.Y.Z`; `CFBundleVersion` = `git rev-list --count HEAD` (a shallow
  clone is refused, since it would change the number). A build from a checkout also gets
  `MacMaxSource` = `git describe --tags --always --dirty`, shown in About.

## Toolchain

`Support/toolchain` pins the Xcode build a release is made with (Bton pins `xcode-build 17C52`:
Xcode 26.2, Swift 6.2.3). `release.sh` refuses any other. Changing the pin is its own commit.

## Day-to-day build (the dev loop)

```
swift build --build-tests --scratch-path "$SCRATCH"          # sandbox off
swift test --skip-build --scratch-path "$SCRATCH"            # count the tests: it must grow when you add tests
scripts/check.sh                                              # build, tests, 500-line and ASCII lint
scripts/install-from-source.sh                               # bundle + install to /Applications, CLI to ~/.local/bin
```

After installing, check the installed build is this checkout:
`/usr/libexec/PlistBuddy -c 'Print MacMaxSource' /Applications/MacMax.app/Contents/Info.plist`
equals `git describe --tags --always --dirty`. For local builds, `scripts/make-signing-identity.sh`
creates a self-signed "MacMax Local" code-signing identity once, so TCC grants (Full Disk Access,
notifications) survive local rebuilds; releases never use it.

## bundle.sh

`scripts/bundle.sh [--universal] [--version x.y.z --build n] [--source <describe>] [--scratch d]
[--out d] [--identity <name>|-]` prints the `.app` path on stdout, noise on stderr. Per arch:
`swift build -c release --triple <arch>-apple-macosx13.0` with `-file-prefix-map` for the source
and scratch paths and `ZERO_AR_DATE=1`; `lipo -create` for universal; delete the toolchain rpath
SwiftPM adds; `strip -S`. Assemble Info.plist (versions replaced with `plutil`), `AppIcon.icns`,
`MenuBarIcon.pdf`, and `install.sh` into `Contents/Resources/`. The CLI goes into
`Contents/Resources/macmax` (the installer copies it out). Sign the CLI, then the app.

## Signing (decision D1)

**Path A, ad hoc (Bton's choice).** `codesign --force --sign -`. Reproducible bit for bit. Gatekeeper
does not block it because `curl` sets no quarantine flag; a zip downloaded in a browser needs
right-click > Open the first time. The cost for MacMax: every update is a new app to TCC, so Full
Disk Access and notification permission must be granted again after each update, and the updater
cannot verify who signed the new version.

**Path B, Developer ID (recommended for MacMax).** Requires the Apple Developer Program ($99/year)
and a "Developer ID Application" certificate in the owner's keychain.
```
codesign --force --options runtime --timestamp --sign "Developer ID Application: <name> (<TEAMID>)" \
  MacMax.app/Contents/Resources/macmax
codesign --force --options runtime --timestamp --sign "Developer ID Application: <name> (<TEAMID>)" MacMax.app
ditto -c -k --keepParent MacMax.app MacMax-X.Y.Z.zip
xcrun notarytool submit MacMax-X.Y.Z.zip --keychain-profile macmax-notary --wait
xcrun stapler staple MacMax.app && rm MacMax-X.Y.Z.zip      # re-zip the stapled app (below)
```
TCC grants survive updates (same Team ID), the updater checks the Team ID, and no right-click is
needed. A Developer ID signature carries a timestamp, so the signed zip is not reproducible: publish
the reproducible ad hoc zip beside it (`MacMax-X.Y.Z-adhoc.zip`) so anyone can verify the source
builds to the same bytes, and the installer uses the signed one. Hardened runtime needs no special
entitlements for MacMax's data sources (verify in U12: run the full live suite against the signed,
notarized build). The notary credentials (`notarytool store-credentials macmax-notary`) live in the
owner's keychain only, never in the repo or CI logs.

## release.sh

`scripts/release.sh <X.Y.Z> [--verify] [--developer-id "<identity>"]`. Preconditions, each failing
with a message: semver; clean tree; HEAD is tag `vX.Y.Z`; not shallow; Xcode build equals the pin.
Build from `git archive HEAD | tar -x` in a temp dir with `SOURCE_DATE_EPOCH` = the tag commit's
time, normalize modes (`chmod -R u=rwX,go=rX`), `xattr -cr`, `touch -h -t <stamp>` every file, zip
with sorted entries (`find MacMax.app | LC_ALL=C sort | TZ=UTC zip -q -X -D -y -@`). `--verify`
builds a second copy at another path and `cmp`s the zips. With `--developer-id`, it then signs,
notarizes, staples and zips the signed copy. Output in `dist/`: `MacMax-X.Y.Z.zip` (the one users
install), `MacMax-X.Y.Z-adhoc.zip` (path B only), and `SHA256SUMS` with one line per zip.

It takes minutes: run it in a terminal, never behind a button with a short timeout.

## Release ceremony (only when the owner chooses a release)

1. Everything merged on `main`; `scripts/acceptance.sh` passes on the commit to tag.
2. README, screenshots (`docs/SCREENSHOTS.md`), docs and `SECURITY.md` match this version, and
   `scripts/registry-snapshot.sh` has refreshed `Support/Registry` (the app list a first launch shows;
   commit it when it changed).
3. Release notes in `$SCRATCH/notes-X.Y.Z.md`: what users get, in plain words; known limits;
   "First install on a second Mac: <date, macOS version, result>" for v0.1.0 and any release that
   changes the installer or signing.
4. ```
   git tag -a vX.Y.Z -m vX.Y.Z && git push origin vX.Y.Z
   scripts/release.sh X.Y.Z --verify [--developer-id "..."]
   gh release create vX.Y.Z dist/MacMax-X.Y.Z*.zip dist/SHA256SUMS --repo danieltamas/macmax \
     --title "MacMax X.Y.Z" --notes-file "$SCRATCH/notes-X.Y.Z.md"
   ```
5. Verify on the public path: `MACMAX_VERSION=X.Y.Z ./install.sh` (the session's hook blocks
   `curl | bash`; the file is the same), then the installed `CFBundleShortVersionString` is `X.Y.Z`,
   the app opens, About says "latest". Once per release, the owner runs the real one-liner from the
   README in Terminal. The `release` tool's last two verify lines ping the app registry
   (github.com/danieltamas/registry, its docs/PRODUCER.md) and wait until it lists X.Y.Z, so every
   other app's More apps page shows the new version within a minute.
6. The first public release also needs: the repo public (it already is: created public and empty
   on 2026-10-25), GitHub's private vulnerability reporting on (`SECURITY.md`), branch protection
   on `main`, a `gitleaks` scan of the full history with no findings, `CONTRIBUTING.md`, and issue
   and PR templates.

## install.sh

Repo root; `curl -fsSL https://raw.githubusercontent.com/danieltamas/macmax/main/install.sh | bash`.
- Every step in a function; `main "$@"` is the last line, so a truncated download runs nothing.
- Darwin and macOS 13 or newer, else a sentence and exit.
- `fetch()` = `curl -fsSL --connect-timeout 20 --speed-limit 1024 --speed-time 60`.
- Version: `MACMAX_VERSION=X.Y.Z` (validated as semver) pins a release; otherwise
  `releases/latest/download/`. Downloads the zip and `SHA256SUMS`; exactly one line must match
  `^[0-9a-f]{64}  MacMax-X.Y.Z.zip$`; verify with `shasum -a 256`; `ditto -x -k` into a temp dir.
- With Developer ID (path B): `codesign --verify --deep --strict` and the Team ID equals the
  expected one baked into the script; `spctl --assess --type execute` passes.
- Lock: a symlink in `$TMPDIR` pointing at the pid (`ln -s` is atomic); a stale lock is taken over
  by one installer through `mkdir "$lock.takeover"`; cleanup removes the lock only if it is still ours.
- Destination: `/Applications` when the user can write it, else `~/Applications` (created 0755) so
  a non-admin user installs without a password; an existing install keeps its location. The README
  promises "no admin password", and this is why.
- Swap: `ditto` to `<destination>/MacMax.app.new`; stop the running app, including the one that
  launched this installer (Bton's `pkill` skipped its own ancestor, so Update never restarted:
  stop by bundle path, wait until the pid is gone, at most 10 s, then kill); `mv` old to `.old`,
  `.new` into place, restore `.old` if the second move fails, remove `.old`; copy the CLI to
  `~/.local/bin/macmax` (0755; refuse to overwrite a file that is not a previous MacMax CLI); `open`
  the new app; warn if `~/.local/bin` is not on PATH.
- `--app <path>` installs a local build (used by `install-from-source.sh`).
- `--uninstall`: quit the app, remove `MacMax.app` from `/Applications` and `~/Applications` and
  `~/.local/bin/macmax`, keep
  `~/.macmax` unless `--purge`, print `claude mcp remove macmax` for the user to run. The login
  item goes with the app.

## In-app update (U11)

- **Check by itself**: at launch and every 24 hours, `GET
  https://api.github.com/repos/danieltamas/macmax/releases/latest` with URLSession (no `gh`
  needed), connect timeout 10 s, total 30 s, at most once per 15 minutes even on "Check again";
  honor `403`/`429` and `Retry-After` with backoff. One shared release check feeds About and the
  panel header.
- **Standing** (`MacMaxRelease.standing`): compare X.Y.Z numerically: lower is `behind` (even when
  dirty or past its tag), higher is `ahead`, equal is `latest` only when clean with no commits after
  the tag, else `ahead`; unparseable is `unknown`.
- **Notify** once per new version (a notification and the header arrow).
- **Install on press**: "Update to X.Y.Z" in About, offered only when running from exactly
  `/Applications/MacMax.app` or `~/Applications/MacMax.app` and `behind` a valid tag (a copy run
  from Downloads or a build folder is never replaced). The login item follows the same rule. It runs the bundled installer: executable
  `/bin/bash`, argv `[<bundle>/Contents/Resources/install.sh]`, environment
  `{MACMAX_VERSION: X.Y.Z, MACMAX_INSTALL_ROOT: <folder of the running copy>, HOME, PATH: /usr/bin:/bin:/usr/sbin:/sbin}`
  (the installer replaces the copy that is running, and `set -u` needs HOME). If it ends while the app is
  still running, About shows the log's last line and a later press may try again. The installer outlives the app,
  stops it, swaps, reopens. Shows "Updating..." at once; the state lives in the store-level
  `Updater` singleton.
- **"Install updates automatically"** (Settings > General, off by default, offered only on path B):
  installs a new version when the app has been idle for 10 minutes and no action is running, then
  notifies "Updated to X.Y.Z". On path A it is hidden: without a Team ID check, an automatic swap
  would trust whatever the release holds.
- **Log**: `~/.macmax/update.log`, opened `O_WRONLY|O_CREAT|O_TRUNC|O_NOFOLLOW|O_NONBLOCK`, mode 0600,
  `fstat`-checked as a regular file. On failure, About shows the log's last non-empty line, sanitized.

## Rollback

A bad release: `MACMAX_VERSION=<previous> bash -c "$(curl -fsSL .../install.sh)"` installs the
previous version (the installer replaces a newer app too). Then mark the bad release as a
pre-release on GitHub (so `releases/latest` points at the previous one) and publish a fixed patch.
Never delete a published tag. Database migrations are forward-only, but an older app opens a newer
schema read-only (U5), so a rollback never corrupts history; it shows "History written by a newer
MacMax" until the update returns.

## CI (GitHub Actions)

- `ci.yml` on every PR and push to `main`: `macos-15` runner, select the newest installed Xcode that
  matches the pin's major version, `swift build --build-tests`, `swift test`, `scripts/check.sh`.
  Live suites do not run in CI (they need a real Mac's VPN, Docker and processes).
- `release-verify.yml` on tag push: builds the release zip twice and compares (no signing, no
  secrets). If the pinned Xcode build is not on the runner image, the job says so and exits
  neutral; the local `--verify` remains the gate.
- Actions pinned by commit SHA, `permissions: contents: read`, no secrets in any workflow in v1.

## Homebrew (decision D7)

`Casks/macmax.rb` in `danieltamas/homebrew-tap`, pinned by `sha256` to the release zip, with the
`macmax` CLI as its `binary` and a `postflight_steps` that clears the quarantine flag, so the ad hoc
signed app opens like the curl install does. `scripts/tap.sh X.Y.Z` runs in the release's verify
step: it rewrites the two pinned lines from `dist/SHA256SUMS`, pushes the tap, and `brew fetch`
proves the published zip matches. A cask bump never changes anything else in the file. Decided
2026-10-27: own tap; homebrew-core would need notarization (D1).

## Second Mac check (v0.1.0 and installer or signing changes)

On a Mac (or a fresh macOS user account) with no Xcode, no `/opt/homebrew`, no Docker, no VPN, and a
non-admin user: run the README line; no password is asked; the app lands in `~/Applications` and opens; Overview shows a verdict within two minutes;
Docker and VPN cards say "not installed" or "no VPN" instead of errors; `macmax snapshot --json`
works from a new Terminal; Update from the previous release works. Record the result in the release
notes.
