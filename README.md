# Sentinel

A macOS menu bar app that watches the webcam to tell whether you're at your Mac:

- **While you're present** (a face is visible to the camera) it holds a power assertion so the display never idle-sleeps or locks under you.
- **When you leave**, it locks the screen — after one missed check plus a grace period (30 seconds by default).
- Checks are deliberately gentle: one single frame every 30 seconds by default (the camera light blinks briefly during each check, then turns off).

Everything is analyzed on-device with the Vision framework. No frames are stored or sent anywhere.

## Install

### From a GitHub release

Download the latest `Sentinel-X.Y.Z.dmg` from the repo's **Releases** page, open it, and drag **Sentinel** into **Applications**. Release builds are ad-hoc signed and not notarized, so macOS quarantines the download; clear it once:

```sh
xattr -d com.apple.quarantine /Applications/Sentinel.app
```

(or launch it, let macOS complain, then *System Settings → Privacy & Security → Open Anyway*).

### From source

```sh
make install          # builds, copies to /Applications, launches
```

On first check, macOS asks for camera permission — click **Allow**. Then open the menu bar icon and enable **Launch at Login**.

For development, `make run` builds and launches straight from `build/Sentinel.app`.

> **Tip — code signing:** the default build is ad-hoc signed, so macOS treats every rebuild as a new app and re-asks for camera permission. If you have an Apple Development certificate, build with `make CODESIGN_IDENTITY="Apple Development"` and the permission grant survives rebuilds.

## How it works

| You | Sentinel |
|---|---|
| Sitting at your Mac | Checks a webcam frame every 30 s, finds your face, keeps the display awake (`pmset -g assertions` shows *Sentinel: user present at webcam*) |
| Step away | Next check misses you → 30 s grace → one final check → screen locks |
| Come back and unlock | Unlocking is treated as proof of presence; monitoring resumes, no instant camera check |
| Screen locked / Mac asleep | Polling fully suspended — no camera blinks while you're away |

The lock itself uses the private `SACLockScreenImmediate` API from `login.framework` (the standard approach for non-App-Store utilities), with `pmset displaysleepnow` as a fallback. The fallback only *locks* (rather than just sleeping the display) if *System Settings → Lock Screen → Require password after screen saver begins or display is turned off* is set to **Immediately**.

### Fail-open by design

A presence guard must never lock you out because the camera broke. Any check that can't produce a confident verdict — permission denied, no camera, capture timeout, frame too dark (lens covered, lid closed, lights off) — counts as *inconclusive*, never as *absent*. Sentinel releases its assertions, shows the problem in the menu, and retries on the normal schedule. Only a well-lit, successfully analyzed frame containing zero faces moves toward locking.

## Menu

- **Check Now** — immediate presence check
- **Pause** — 15 minutes / 1 hour / until resumed (releases assertions, stops camera checks)
- **Check Every** — 10 s / 30 s / 1 min / 2 min / 5 min
- **Lock After Absence** — immediately / 15 s / 30 s / 1 min / 2 min of grace after a missed check
- **Camera** — Automatic (system preferred) or a specific device
- **Launch at Login** — registers via `SMAppService`

## Configuration from the terminal

All settings live in `UserDefaults` under `com.github.martintreurnicht.sentinel`:

```sh
defaults write com.github.martintreurnicht.sentinel pollInterval -float 30        # seconds between checks (min 5)
defaults write com.github.martintreurnicht.sentinel absenceGracePeriod -float 30  # seconds before lock after a miss (0 = immediate)
defaults write com.github.martintreurnicht.sentinel cameraUniqueID -string ""     # "" = automatic
defaults write com.github.martintreurnicht.sentinel warmupFrames -int 8           # frames discarded while auto-exposure settles
defaults write com.github.martintreurnicht.sentinel checkTimeout -float 10        # seconds allowed per capture
defaults write com.github.martintreurnicht.sentinel lockMethod -string auto       # auto | private | pmset
```

Restart Sentinel (or change any setting from the menu) after editing defaults externally.

## Development

```sh
make            # build release bundle into build/Sentinel.app
make test       # state-machine unit tests
make run        # build + relaunch
make icon       # regenerate build/AppIcon.icns from scripts/generate-icon.swift
make dmg        # build a drag-to-install disk image (build/Sentinel.dmg)
make verify     # lint Info.plist, verify code signature and bundled icon
make logs       # follow live logs (subsystem com.github.martintreurnicht.sentinel)
make uninstall  # remove from /Applications
```

With the app running and a face visible, `pmset -g assertions` should list a `PreventUserIdleDisplaySleep` assertion named *Sentinel: user present at webcam*.

## Releases & automatic versioning

CI is set up so that **every merge to `main` ships a release** (`.github/workflows/release.yml`):

1. `scripts/next-version.sh` computes the next version from the latest `vX.Y.Z` git tag and the commits since it:
   - **major** — any commit containing `#major` or `BREAKING CHANGE`, or a conventional `type!:` subject (e.g. `feat!: …`)
   - **minor** — any commit containing `#minor`, or a `feat:` / `feat(scope):` subject
   - **patch** — everything else (the default)
   - no tags yet → `1.0.0`
2. Tests run, then a **universal (arm64 + x86_64) DMG** is built with the version stamped into `CFBundleShortVersionString` and the CI run number into `CFBundleVersion`. The checked-in `Support/Info.plist` keeps its placeholder — versions live in git tags, so no bump commits and no workflow loops.
3. The commit is tagged `vX.Y.Z` and a GitHub release is created with auto-generated notes and `Sentinel-X.Y.Z.dmg` attached.

Squash-merge PRs and the PR title becomes the commit subject that drives the bump — e.g. title a PR `feat: add away-time stats` to get a minor release. Re-running the workflow on an already-released commit is a no-op (`skip=true`).

Pull requests themselves get a build + test check (`.github/workflows/ci.yml`).

> Release builds are ad-hoc signed because CI has no signing certificate. To ship properly notarized builds later, add a Developer ID certificate + `notarytool` step to the release workflow.

## Caveats

- **Dark rooms:** Mac webcams have no IR hardware. In real darkness the luminance guard kicks in and Sentinel fails open (no lock, but also no keep-awake). In a *dim* room detection may miss you — lengthen the grace period or pause if that bites.
- **Private API:** `SACLockScreenImmediate` is private and could disappear in a future macOS; Sentinel automatically falls back to `pmset displaysleepnow` (see lock note above). It's verified present on macOS 26.5.
- **Multiple cameras:** "Automatic" follows the system-preferred camera, which may be an external one pointing somewhere unhelpful. Pick a specific camera from the menu if checks misfire.
- **Video calls:** macOS allows concurrent camera access, so Sentinel keeps working during calls (and you're present anyway).
- Removing the app? `make uninstall`, then optionally `tccutil reset Camera com.github.martintreurnicht.sentinel`.
