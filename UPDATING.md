# Updating this fork (EthanSK/VoiceInk) against upstream

This is Ethan's personal GPL-3.0 fork of [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk),
carrying a small set of local patches on top of upstream. Upstream **does not accept PRs**, so our
patches live only here and must be **rebased** onto each upstream release.

## Our patches (preserve these through every rebase)

All in `VoiceInk/Modes/ActiveWindowService.swift` + a one-line wiring call in `VoiceInk/VoiceInk.swift`:

- **#785 — Mode follows the current app (the load-bearing fix).** Adds an
  `NSWorkspace.didActivateApplicationNotification` observer in `ActiveWindowService.start()` so the
  active Mode re-resolves whenever the frontmost app changes — *including during recording*. Upstream
  only resolves the Mode at record-start, which breaks the common "start dictating, then click the
  target field" workflow (it pastes into the right app but with the wrong app's auto-send). With the
  observer, at paste/delivery time the Mode matches the app you're actually in.
- **#784 — neutral nil-fallback.** When an app has no enabled matching Mode and there's no
  enabled+default Mode, `setActiveConfiguration(nil)` (neutral paste / no auto-send) instead of
  silently retaining the previous app's Mode.

`start()` is wired once at app launch in `VoiceInk.swift` (right after `ActiveWindowService.shared`).

## Build (MUST be on the Mac Mini — never the MBP)

`xcodebuild` fires codesign dialogs on the MBP; the Mini is the dedicated build box. VoiceInk is a
native Swift/SwiftUI app, **not** Electron, so changes require a recompile (you can't hot-patch the
installed `.app`).

```sh
# on the Mac Mini:
cd ~/Projects/VoiceInk-build        # the Mini's clone of this fork
make local                          # builds whisper.cpp (cached after first time) + ad-hoc-signed xcodebuild
# output: ~/Downloads/VoiceInk.app  (quarantine already stripped by the Makefile)
```

`make local` injects the `LOCAL_BUILD` compile flag → `LicenseViewModel` is hard-coded to `.licensed`,
so a local build is permanently Pro with **no** trial/keychain/Polar gate. No Apple Developer cert
needed (ad-hoc `CODE_SIGN_IDENTITY = -`). Mic / Accessibility / Screen-Recording are normal TCC grants
on first launch.

## Pull in upstream changes (rebase workflow)

```sh
git fetch upstream
git rebase upstream/main          # replay our 2 commits onto the latest upstream
# If conflicts: they'll be in ActiveWindowService.swift / VoiceInk.swift — keep BOTH upstream's
# changes and our observer/start() additions, then `git rebase --continue`.
git push --force-with-lease origin main
```
Then rebuild on the Mini (`make local`) and install the fresh `~/Downloads/VoiceInk.app` on the MBP.

Upstream auto-update (Sparkle) is disabled in local builds, so updating is this manual rebase + Mini
rebuild — or the automated job below.

## Automated rebuild (keeps the build current with our fixes)

A scheduled job on the Mini (`~/.claude/scripts/voiceink-fork-autorebuild.sh` + a LaunchAgent) does the
above on a cadence: fetch upstream → rebase our patches → `make local` → notify, and the new `.app` is
copied to the MBP. If a rebase hits a conflict it stops and notifies (manual resolve) rather than
producing a broken build. See that script for details.

## Settings / data

Same bundle id as the official app (`com.prakashjoshipax.voiceink`), so this build reads the same
Modes/prefs (`~/Library/Preferences/com.prakashjoshipax.VoiceInk.plist`) and app-support — your setup
carries over automatically. A pre-migration backup lives at `~/voiceink-settings-backup-*`.
