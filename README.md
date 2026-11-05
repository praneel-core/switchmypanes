# Switchmypanes

Windows-style **Alt-Tab** (individual windows, most-recently-used order) and **window snapping** for macOS.
Free, local only: no accounts, no network calls, no analytics. Phase 1 of 3: see [ARCHITECTURE.md](ARCHITECTURE.md).

## What it does now

- **Option+Tab**: overlay with a thumbnail, app icon and title for each window on the current Space.
  Hold Option, tap Tab / Shift+Tab (or use the arrow keys) to move, release Option to switch, Esc to cancel,
  or click a window. The second window is preselected, so a quick tap toggles between your last two windows.
  Cmd+Tab is untouched.
- **Drag to snap**: drag a window by its title bar to the left or right edge (half), top edge (maximize) or a corner
  (quarter). A translucent preview shows where it will land; release to snap. Edges shared with another display are ignored.
- **Snap Layouts** (**Option+Z**): pick one of nine layouts (halves, thirds, three columns, 2×2 grid, ...) with the
  arrow keys + Return, the digits 1–9, or the mouse. Then, for each area in turn (outlined on screen), pick a window;
  it moves there immediately. Space skips an area, Esc stops (windows already placed stay). Note that Option+Z
  normally types “Ω”; turn this off in Preferences if you need it.
- **Snapping** with **Control+Option+Arrow**: Left / Right = half, Up = maximize, Down = restore (or minimize if
  not snapped). Left then Up = top-left quarter, etc. Add **Shift** to move the window to another display.
  The modifiers and a gap between windows are configurable in Preferences.

## Build and run

Needs only the Xcode Command Line Tools (`xcode-select --install`); full Xcode is not required.

```bash
# one time (recommended): stable signing identity so permissions survive rebuilds
./tools/create-signing-identity.sh      # asks for your login password; creates "Switchmypanes Local Dev"

./build.sh            # builds build/Switchmypanes.app
./build.sh run        # build and launch
./build.sh install    # build, copy to ~/Applications and relaunch
swift run CoreChecks  # run the logic checks
```

Without the identity, `build.sh` still works but signs ad-hoc, and macOS forgets the permissions on each rebuild.
(If you would rather reuse an identity you already have: `SIGN_IDENTITY="Your Identity Name" ./build.sh`.)

## First launch: permissions

A checklist window opens. For each of **Accessibility**, **Input Monitoring** and (optionally) **Screen Recording**,
click the button, switch Switchmypanes on in System Settings, and come back; the status updates live.
If the status line still says shortcuts are inactive after granting, click *Relaunch Switchmypanes*.
Screen Recording only adds the window previews.

## What the keyboard listener does and doesn't read

Option+Tab and the snap shortcuts need a system-wide keyboard listener (a CGEventTap). For each key press it
looks at two things: the key code and which modifier keys are held, and checks whether that is one of its own
shortcuts. Everything else is passed on untouched. It does not read characters, does not store or log anything
typed, and cannot see into password fields (macOS hides those from all apps). It only swallows Option+Tab, the
snap shortcuts, and, while the overlay is open, Tab / arrows / Esc.

## Menu bar and URL scheme

Menu: Preferences, Permissions, Pause / Resume, Quit. `open switchmypanes://pause`, `://resume`,
`://preferences`, `://permissions`.

## Known limits in Phase 1

Current Space only; minimized windows not listed; thumbnails are captured when the overlay opens (placeholders
show app icons for the first moment); with a very large number of windows the overlay shows only as many as fit
the screen; no drag-to-edge, Snap Assist or Snap Layouts yet (Phase 2).
No automated tests can click macOS permission dialogs; see the manual test checklist below.

## Manual test checklist

1. Run `./build.sh run`, grant the permissions; status should say "Keyboard shortcuts: active".
2. Open 4+ windows across 2+ apps (two Safari windows, Finder, Terminal, Notes).
3. Hold Option, tap Tab: overlay appears, second window selected. Tab / Shift+Tab / arrows move. Release: that window comes to the front.
4. Quick tap Option+Tab twice: you go back and forth between the last two windows, and the overlay barely flashes.
5. Option+Tab then Esc: nothing changes. Option+Tab then click a tile: switches.
6. Hold Option+Tab, move the mouse over a tile: it highlights; do NOT move the mouse: selection stays on keys.
7. Snap: focus a window, Control+Option+Left / Right / Up / Down; then Left then Up (top-left), Left then Down, Right then Up/Down.
8. Down on a snapped window returns its old size; Down on a normal window minimizes it.
9. Shift added: with a second display, the window moves there and keeps its snapped position. Try displays with different scales.
10. Try a full-screen app (overlay should still appear on top; snapping does nothing to full-screen windows by design).
11. Try an app with a minimum size (e.g. System Settings) in a quarter: it should sit in the right corner, not off-screen.
12. Drag a window by its title bar to each edge and corner: preview appears and follows the cursor; release snaps; Control+Option+Down then restores the old size. With two displays, dragging across the middle must NOT snap.
13. Option+Z: pick "Three columns" (press 3): the first area is outlined, windows are listed with the front one selected. Place three windows with Return; each should move and come to the front. Try Space to skip, Esc halfway, and clicking outside the picker (it should close). Set a gap in Preferences and re-run: gaps should be even.
14. Menu bar: Pause stops all shortcuts; Resume restores; Quit removes the icon.
