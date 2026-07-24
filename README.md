# WindowPinner

A tiny macOS menu-bar app that stops macOS from scrambling your windows and
monitor arrangement after sleep, lid-close, or unplugging external monitors.

## What it does

- **Remembers a layout per monitor setup.** Each unique *set* of connected
  displays (identified by their hardware UUIDs) gets its own saved layout:
  "laptop only", "laptop + 2 office monitors", etc. Take the laptop to a
  meeting, come back, plug in — your office layout comes back.
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

## Build & install

```bash
./build.sh install     # builds, copies to /Applications, launches
```

Or just `./build.sh` to produce `dist/WindowPinner.app` without installing.

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
- **Forget All Layouts** — wipes saved state
  (`~/Library/Application Support/WindowPinner/layouts.json`).

## Debugging

Logs go to the unified log:

```bash
log stream --predicate 'subsystem == "com.darnt.WindowPinner"' --level info
```

## Known limitations

- Windows are matched by app + title, falling back to window order, so an
  app whose window titles all changed since the snapshot may get windows
  back in a different order (still on the right display, though).
- Spaces/Mission Control desktops aren't managed — a window is moved within
  the space it currently lives on.
- Minimized windows are left minimized; full-screen windows are ignored.
- Apps started *after* the last snapshot aren't repositioned until the next
  snapshot cycle picks them up.
