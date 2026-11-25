# WindowPinner

A tiny macOS menu-bar app that stops macOS from scrambling your windows and
monitor arrangement after sleep, lid-close, or unplugging external monitors.

## What it does

- **Remembers a layout per monitor setup.** Each unique *set* of connected
  displays (identified by their hardware UUIDs) gets its own saved layout:
  "laptop only", "laptop + 2 office monitors", etc. Take the laptop to a
  meeting, come back, plug in — your office layout comes back.
- **Handles identical monitors.** Two displays of the same make and model can
  report the *same* EDID serial, so the UUID macOS derives from it isn't
  reliably tied to a physical panel — after sleep macOS can swap which panel
  is which, landing desktops on the wrong monitor. WindowPinner detects that
  case and identifies each panel by its own alphanumeric serial (falling back
  to the physical port), so arrangement and desktops are pinned to the actual
  monitor. Requires each monitor to stay on its own cable/port.
- **Snapshots automatically.** Every 30 seconds (only while the display
  configuration has been stable for 20+ seconds), plus right before sleep.
  It never snapshots in the messy window right after wake or a monitor
  plug/unplug, so a scrambled layout can't overwrite a good one.
- **Treats your monitor arrangement and desktop layout as reference data.**
  The display *arrangement* (monitor positions) and the *desktop→monitor*
  mapping are captured the first time a display set is seen and refreshed
  only when you choose **Snapshot Now** — automatic snapshots never touch
  them. That way a transient post-wake or replug scramble can't quietly be
  recorded as your new "correct" setup. Window positions still update on
  every automatic snapshot. **If you deliberately rearrange your monitors or
  desktops, pick Snapshot Now** to save the new arrangement as the reference.
- **Restores automatically.** After system wake, after *display* wake (screen
  saver / monitors blanking — which does not post a system wake event), after
  the display set changes, and whenever the live arrangement or desktop
  grouping is found to have drifted from the saved layout. It waits for the
  monitors to settle, optionally fixes the display *arrangement* (macOS loves
  swapping left/right monitors), then moves every window back, retrying across
  a widening window because displays and apps both settle late.
- **Puts desktops back on their displays.** macOS sometimes moves whole
  Mission Control desktops (Spaces) to a different monitor after
  sleep/reconnect. WindowPinner snapshots which desktops belong to which
  display and, when they've migrated, rewrites the mapping and restarts the
  Dock (a brief flicker; running apps are unaffected) before placing
  windows. Toggleable via "Also Restore Desktops to Displays"; the previous
  mapping is backed up under
  `~/Library/Application Support/WindowPinner/spaces-backups/`.

## Install

**Download:** the latest `.dmg` is on the
[Releases page](https://github.com/dthornley/WindowPinner/releases). The app
checks for a newer release once a day (and shortly after launch) and offers to
install it; **Check for Updates…** in the menu does the same on demand, and
**Check for Updates Automatically** turns the daily check off.

## Build

```bash
./build.sh install     # builds, copies to /Applications, launches
```

Or just `./build.sh` to produce `dist/WindowPinner.app` without installing.
The build fetches [Sparkle](https://sparkle-project.org) (the updater) via
SwiftPM and embeds it in the app bundle.

### Releasing

```bash
./build.sh release
```

Bump `VERSION` and `BUILD` in `build.sh` first (Sparkle compares `BUILD`, so
it must go up every release) and commit. The script builds, signs and
notarizes the app and DMG, signs the update zip with the Sparkle EdDSA key,
writes `appcast.xml`, tags `v<VERSION>`, pushes, and publishes the GitHub
release with the DMG, the zip and the appcast. The running app downloads
`releases/latest/download/appcast.xml` to learn about new versions. Release
notes come from `RELEASE_NOTES.md` when present, otherwise from the commits
since the previous tag.

The update signature uses a key pair separate from Apple's. The private key
lives in the login keychain (created with Sparkle's `generate_keys`, found
under `.build/artifacts/sparkle/Sparkle/bin/` after a build); the public key
is `SPARKLE_PUBLIC_KEY` in `build.sh`. Back the private key up
(`generate_keys -x sparkle.key`): the updater refuses archives signed with
any other key, so losing it means shipping the next version by hand. On a
new Mac, import it with `generate_keys -f sparkle.key`.

### First run

1. On first launch macOS asks for **Accessibility** permission
   (System Settings → Privacy & Security → Accessibility). This is required —
   it's the API used to read and move other apps' windows.
2. Click the pin icon that appeared in the menu bar and enable
   **Start at Login**.

> After rebuilding the app, macOS may silently revoke Accessibility (the
> ad-hoc code signature changes). Fix: toggle WindowPinner off and on again
> in the Accessibility list, or remove and re-add it.

## Menu

- **Snapshot Now / Restore Now** — manual save/restore for the current
  monitor setup. Snapshot Now is also how you re-save the monitor arrangement
  and desktop→display mapping after deliberately changing them (automatic
  snapshots preserve the existing reference rather than overwriting it).
- **Automatic Snapshot & Restore** — the whole automatic behavior; untick to
  pause.
- **Also Restore Display Arrangement** — re-applies saved monitor positions
  (fixes swapped displays), not just window positions.
- **Start at Login** — registers as a login item.
- **Check for Updates… / Check for Updates Automatically** — look for a
  newer release on GitHub now, or toggle the daily background check.
- **Forget All Layouts** — wipes saved state
  (`~/Library/Application Support/WindowPinner/layouts.json`).

## Debugging

Logs go to the unified log:

```bash
log stream --predicate 'subsystem == "com.darnt.WindowPinner"' --level info
```

To inspect how WindowPinner currently identifies your displays and maps
desktops to physical panels (useful with identical monitors):

```bash
/Applications/WindowPinner.app/Contents/MacOS/WindowPinner --dump-displays
```

## Known limitations

- Windows are matched by app + title, falling back to window order, so an
  app whose window titles all changed since the snapshot may get windows
  back in a different order (still on the right display, though).
- Spaces/Mission Control desktops aren't managed — a window is moved within
  the space it currently lives on.
- Windows you minimized yourself stay minimized (their position is still
  recorded, so they land correctly when you unminimize them). Windows that a
  wake scramble minimized behind your back are unminimized and placed.
  Full-screen windows are ignored.
- Apps started *after* the last snapshot aren't repositioned until the next
  snapshot cycle picks them up.
