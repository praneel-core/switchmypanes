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
- **Excluded apps** (Preferences → Excluded apps): pick apps Switchmypanes should leave alone, per app: *Hide from
  switcher* (not listed in Option+Tab) and/or *Never snap* (the snap shortcuts, dragging to edges, Snap Assist and Snap
  Layouts ignore it). Separate from the "never take previews of" list, which only controls pictures.
- **Close windows from the overlay**: hover a tile and click the red ✕, or highlight a window and press **Delete** or
  **W**. It closes exactly as if you had clicked its close button, so "Save changes?" prompts still appear (the tile
  stays until the window is really gone). For a window on another desktop (including a full-screen app) it first switches to that desktop, then closes it.
- **Minimized and hidden windows**: minimized windows and windows of hidden (Cmd+H) apps are listed too, tagged
  "Minimized" / "Hidden"; choosing one restores it. Helper windows that apps draw but that are not real windows (for example Chrome's full-screen toolbar strip) are
  hidden too. Apps like Claude or Slack that "close" a window to the
  background without destroying it are NOT listed (they are not really showing anywhere). Toggle in Preferences.
- **Other desktops and full-screen apps**: the overlay also lists windows on other desktops (Spaces) and full-screen
  apps, each with a small "Desktop 2" / "Full screen" tag. Choosing one makes macOS switch to that desktop.
  Both can be turned off in Preferences. macOS cannot capture a window that is not showing, so these tiles show the last picture
  taken while the window was visible. To have one ready, Switchmypanes takes a picture of a window when you *leave*
  it, and once after you have settled into it (plus a slow refresh if you stay a long time). There is no timer
  polling every window. It does nothing while the screen is locked, you are idle, Low Power Mode is on, or it is
  switched off in Preferences, and it never captures apps on the "never take previews" list (password managers by
  default). Pictures are kept in memory only, never saved or sent. A window that has not been visible since
  Switchmypanes started shows its app icon until you visit it.
- **Snap Layouts** (**Option+Z**): pick one of nine layouts (halves, thirds, three columns, 2×2 grid, ...) with the
  arrow keys + Return, the digits 1–9, or the mouse. Then, for each area in turn (outlined on screen), pick a window;
  it moves there immediately. Space skips an area, Esc stops (windows already placed stay). Note that Option+Z
  normally types “Ω”; turn this off in Preferences if you need it.
- **Linked resizing, with a divider line**: windows you place with **Snap Layouts**, and the pair you make with
  **Snap Assist** (snap one window to a half, pick another for the empty half), are linked. A thin accent-coloured line
  with a small grip appears between them (while you are working in one of those apps): that line means "these windows
  are linked". **Drag the line** and the windows on both sides resize together, so they stay flush (in a 2×2 grid the
  whole vertical or horizontal line moves; with three columns, the line between two columns). The line stops where a
  window cannot get any smaller, so nothing overlaps; dragging back always works. A window leaves the group (and the line
  disappears) when you drag it away, snap it elsewhere, or close it. Resizing a window by its own edge also still
  pulls its neighbours along. Only windows placed through Snap Layouts or Snap Assist are linked, not ones lined up by
  hand. Toggle in Preferences.
- **Snap Assist**: after a window is snapped to the left or right half (keyboard or drag), thumbnails of your other
  windows appear over the empty half. Click one, or use the arrows + Return, and it fills the space. Esc, a click
  elsewhere, or any other key closes it (and that key then does its normal job, so chaining snaps works).
- **Snapping** with **Control+Option+Arrow**: Left / Right = half, Up = maximize, Down = restore (or minimize if
  not snapped). Left then Up = top-left quarter, etc. Add **Shift** to move the window to another display.
  The modifiers and a gap between windows are configurable in Preferences.

## Preferences

Menu bar icon → Preferences. **Shortcuts**: click a shortcut, press the new combination (Esc cancels). The switcher takes
modifier(s) + Tab, snapping takes modifiers + an arrow key, Snap Layouts takes modifier(s) + any key. Combinations that
clash with macOS (⌘Tab) or with text editing (⌥← jumps a word) are refused with a reason. **Open at login** uses
macOS's own login-item system (System Settings → General → Login Items); install the app first (`./build.sh install`)
so the login item points at `~/Applications`, not `build/`.

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

## Diagnostics

**Linked resizing: no line appears, or it does not follow?** (No line after filling a layout means the group was not created.) Quit Switchmypanes from its menu, then run it from Terminal with logging:
`SWITCHMYPANES_DEBUG=1 ~/Applications/Switchmypanes.app/Contents/MacOS/Switchmypanes`, reproduce the problem (fill a
layout or pick a window in Snap Assist, then drag the divider) and send me the lines starting with `[linked]`. They show
whether the group was created, whether the apps report resizes, and what was decided. `Switchmypanes --selftest-linked`
runs a built-in check with two nearly invisible helper windows (about 15 seconds, bottom-right corner) and prints
PASS/FAIL.

`build/Switchmypanes.app/Contents/MacOS/Switchmypanes --list-windows` prints, in the terminal, the windows the
switcher would show (app, title, desktop / minimized status, and whether a thumbnail could be captured), then exits. Useful for "why is this window (not) listed".

## Menu bar and URL scheme

Menu: Preferences, Permissions, Pause / Resume, Quit. `open switchmypanes://pause`, `://resume`,
`://preferences`, `://permissions`.

## Known limits in Phase 1

A window minimized less than about a second ago may not be listed yet (the check runs in the background); thumbnails are captured when the overlay opens (placeholders
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
14. Snap Assist: snap a window Left (Control+Option+Left): after a moment, other windows appear over the right half with the first selected. Return fills it. Try: click a tile; Esc; clicking elsewhere; pressing Control+Option+Up right after the snap (it should close Assist AND make the top-left quarter, with no flash if you press quickly). Repeat with a drag to the right edge.
15. Spaces: create a second desktop (Mission Control, +) and put a window there; make an app full screen (green button). Go back to your first desktop and press Option+Tab: those windows appear, tagged "Desktop 2" / "Full screen". Select one and release Option: macOS should switch to its desktop and that window should be in front. Test both with the app having ONLY that one window, and with the app also having a window on your current desktop (the harder case). Then turn the two options off in Preferences and check they disappear.
16. Closing: open the overlay with 3+ windows (use throwaway windows, e.g. new Finder windows). Hover a tile: a red ✕ appears; click it: the window closes and the overlay re-flows. Press Option+Tab, Tab to a window, press Delete (then W): same. Try a TextEdit document with unsaved text: the save sheet appears and the tile stays. Close every window: the overlay should disappear on its own. Tiles for other desktops should show no ✕ and beep on Delete.
17. Minimized/hidden: minimize a window (yellow button) and hide another app (Cmd+H). Option+Tab lists them tagged "Minimized"/"Hidden"; selecting one brings it back. Quit-to-background apps (close Claude's window with the red button) should NOT appear.
18. Closing a full-screen window from the overlay (hover ✕) from another desktop: macOS should switch to it, close it, and usually return you. Tell me what you see.
19. Previews: work in two windows on desktop 1 for a few seconds each, switch to another desktop, Option+Tab: both should show pictures. In Preferences, add an app to "Never take previews of": its tile should show only the icon. Switch the toggle off and confirm new windows stop getting pictures. If Activity Monitor shows Switchmypanes using noticeable CPU/energy while idle, tell me.
20. Preferences: open it (it should fit your screen and scroll). Click the Snap Layouts shortcut, press ⌃⌥B: it changes; press Option+Z: it should now do nothing, ⌃⌥B opens the picker. Try ⌘Tab for the switcher (refused), ⌥← for snapping (refused). Record ⌃⌥Tab for the switcher: hold both, Tab cycles, releasing EITHER key commits. Use the reset arrows. While recording, pressing the current shortcut must NOT trigger it.
21. Open at login: turn it on from the installed copy. If macOS asks, approve it in System Settings → General → Login Items; log out and in (or restart) and check that the menu bar icon is back. Turn it off again to test that too.
22. Exclusions: in Preferences → Excluded apps, add Safari with only "Hide from switcher" ticked: its windows disappear from Option+Tab but still snap. Untick that and tick "Never snap": Control+Option+Left, dragging to an edge, and Snap Assist/Layouts all ignore Safari's windows. While IN an excluded app, Option+Tab should go to your most recent other window straight away. Remove the entry with the minus button: everything returns.
23. Linked resize: Option+Z, pick "Halves", place two windows: a coloured line with a grip should appear between them. Drag the LINE: both windows should resize together. Try "Grid 2 × 2" (dragging a vertical divider should move all four), "Three columns" (only the two beside the divider), and "Main + two stacked". Drag a window by its title bar away: it should leave the group and the others stop following. Try dragging the divider far, towards an app with a large minimum width (e.g. Calculator, System Settings): the divider should stop and nothing should overlap; then drag back: the link must still work. Same for Snap Assist: snap a window Left (Control+Option+Left), pick another for the right half, then drag the divider: both should move together; snapping either window again with a shortcut should release the link. Tell me which apps lag or refuse (some apps resize slowly).
24. Menu bar: Pause stops all shortcuts; Resume restores; Quit removes the icon.
