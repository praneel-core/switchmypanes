# Switchmypanes

Windows-style **Alt-Tab** and **window snapping** for macOS, in a small menu bar app.

- **Option+Tab** switches between individual *windows* (not apps), most recently used first, with thumbnails.
- **Snapping**: keyboard shortcuts, drag to a screen edge, **Snap Assist**, **Snap Layouts**, and linked resizing of snapped windows.
- Free and fully local: no accounts, no network calls, no analytics.

Built for Apple Silicon Macs on macOS 14 or later. [ARCHITECTURE.md](ARCHITECTURE.md) explains how it works.

## Install

You need the Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not required.

```bash
git clone https://github.com/praneel-core/switchmypanes.git && cd switchmypanes

# One time, recommended: a stable signing identity, so macOS remembers the permissions between builds.
./tools/create-signing-identity.sh      # asks for your login password; creates "Switchmypanes Local Dev"

./build.sh install                      # builds, copies to ~/Applications, and launches
```

Without the identity `build.sh` still works but signs ad-hoc, and macOS forgets the permissions after every rebuild.
To reuse an identity you already have: `SIGN_IDENTITY="Your Identity Name" ./build.sh`.
Other commands: `./build.sh` (build only), `./build.sh run` (build and launch from `build/`).

**First launch:** a checklist window asks for three permissions. Click each button, switch Switchmypanes on in System
Settings, and come back (the status updates live). If it still says the shortcuts are inactive, click *Relaunch*.

| Permission | Why | Required |
|---|---|---|
| Accessibility | move, resize and raise other apps' windows | yes |
| Input Monitoring | notice its own shortcuts (Option+Tab and the snap keys) | yes |
| Screen Recording | the small window previews in the overlay | optional (icons and titles without it) |

## Shortcuts at a glance

All of these can be changed in Preferences (menu bar icon → Preferences).

| Do this | To |
|---|---|
| **Option+Tab** (hold Option, tap Tab) | open the window switcher; release Option to switch |
| Tab / Shift+Tab / arrow keys | move through the windows. ←/→ step through them (and wrap); ↑/↓ move between rows, and with a single row ↓ = next and ↑ = previous |
| Esc | cancel |
| Delete or W | close the highlighted window |
| **Control+Option+←/→** | snap to the left / right half |
| Control+Option+↑ | maximize |
| Control+Option+↓ | restore the old size (or minimize if the window is not snapped) |
| Left then Up (or Down) | top-left (bottom-left) quarter; the same for the right side |
| add **Shift** to a snap shortcut | move the window to another display |
| **Option+Z** | Snap Layouts picker |
| drag a window's title bar to an edge or corner | snap it, with a preview |

Cmd+Tab and Cmd+\` are never touched: they stay with macOS.

## Features

### Window switcher (Option+Tab)
An overlay shows a thumbnail, app icon and title for each window, in most-recently-used order. The **second** window is
preselected, so a quick tap toggles between your last two windows. Hover highlights (once the mouse really moves), click
switches, and the overlay never takes keyboard focus until you commit. It can also list:
- **Windows on other desktops and full-screen apps**, tagged "Desktop 2" / "Full screen". Choosing one switches to
  that desktop (by pressing your own "Move left/right a space" shortcut, so the Dock does it properly) and focuses that
  exact window, even if the same app also has a window on your current desktop.
- **Minimized windows and windows of hidden (Cmd+H) apps**, tagged "Minimized" / "Hidden"; choosing one restores it.

Apps that "close" a window to the background without destroying it (Claude, Slack, …) and helper windows that are not
real windows are not listed. Each kind can be switched off in Preferences.

Hover a tile and click the red ✕, or press **Delete / W**, to close a window. It closes exactly as if you had clicked
its close button, so "Save changes?" prompts still appear. For a window on another desktop it switches there first.

### Snapping
- **Keyboard**: the shortcuts above follow the Windows Win+Arrow logic. A gap between windows is optional.
- **Animation**: when a window snaps (by keyboard, dragging, Snap Assist or Snap Layouts) a soft glowing outline glides from where it was to where it lands (a spring: it accelerates, overshoots a touch and settles, with a fainter echo trailing it) and fades. The window itself still snaps instantly. Switch it off in Preferences → Snapping; it is also skipped when macOS's Reduce motion is on.
- **Drag to an edge**: left / right edge = half, top edge = maximize, corners = quarters. A translucent preview shows
  where the window will land. Edges shared with another display are ignored.
- **Snap Assist**: after a window is snapped to a half, thumbnails of your other windows appear over the empty half.
  Pick one and it fills the space. Esc, a click elsewhere, or any other key closes it (and that key then does its normal job).
- **Snap Layouts** (Option+Z): nine layouts (halves, thirds, three columns, 2×2 grid, main + two stacked, …). Pick one
  with the arrows and Return, the digits 1–9, or the mouse; then choose a window for each outlined area. Space skips an
  area; Esc stops, keeping what is placed.

### Linked resizing
Windows placed by **Snap Layouts**, and the pair you make with **Snap Assist**, are linked. Move the cursor to the
**middle of the seam** between them: a thin line with a grip fades in, meaning "these windows are linked". **Drag the
line** and the windows on both sides resize together and stay flush (in a 2×2 grid a whole row or column moves). The line
stops where a window cannot get any smaller. A window leaves its group when you drag it away, snap it elsewhere, or
close it. Windows lined up by hand are not linked. Some apps apply a resize a moment late; after you let go they may take
up to a second to settle into place.

### Excluded apps
In Preferences → Excluded apps, choose apps to leave alone: *Hide from switcher* (not listed in Option+Tab) and/or
*Never snap* (the snap shortcuts, dragging, Snap Assist and Snap Layouts ignore it).

### Previews
macOS cannot take a picture of a window that is not showing, so tiles for windows on other desktops show the last
picture taken while the window was visible. Switchmypanes takes one when you *leave* a window and once after you settle into
it, plus a slow refresh if you stay long. Pictures live in memory only and are never saved or sent. It does nothing while
the screen is locked, you are idle, or Low Power Mode is on; password managers are never captured by default; the whole
thing can be switched off, and apps can be added to a never-capture list, in Preferences.

## Preferences and menu bar
Preferences has five tabs (General, Shortcuts, Switcher, Snapping, Apps). The overlays share one glass look (three choices in Preferences → Switcher: **Glass**, the clearest and the default, which is real Liquid Glass on macOS 26; **Frosted**; and **Dark**, the heaviest and easiest to read over a busy desktop) with a keyboard-hint bar at the bottom, a highlight that slides to the selected tile, colour-coded tags, and a quick fade-in (all motion is skipped when macOS's Reduce motion is on). Preferences has click-to-record **shortcuts** (clashes with macOS or with text editing, such as ⌘Tab or ⌥←, are refused
with a reason), toggles for every feature, the gap between snapped windows, the never-capture and excluded-app lists, and
**Open at login** (via macOS's own login items; install with `./build.sh install` first so it points at `~/Applications`).

The menu bar menu has Preferences, Permissions, Pause / Resume and Quit. A `switchmypanes://` URL scheme also works:
`open switchmypanes://pause`, `://resume`, `://preferences`, `://permissions`.

## Privacy
Everything stays on your Mac. The keyboard listener (a CGEventTap) looks only at the key code and which modifier keys
are held, to see whether it is one of its own shortcuts; everything else passes through untouched. It never reads
characters, stores or logs what you type, and cannot see into password fields (macOS hides those from every app). It
swallows only Option+Tab, the snap and layout shortcuts, and, while an overlay is open, Tab / arrows / Esc / Return.

## Troubleshooting
- **Shortcuts do nothing:** open Permissions from the menu bar icon; Accessibility and Input Monitoring must both be on.
  After granting, click *Relaunch*.
- **Permissions reset after every build:** you are signing ad-hoc; run `./tools/create-signing-identity.sh` once.
- **Option+Z types "Ω" / does nothing:** that is the Snap Layouts shortcut; change it in Preferences.
- **Desktop switching needs the macOS shortcuts "Move left a space" / "Move right a space"** (System Settings →
  Keyboard → Keyboard Shortcuts → Mission Control; on by default as ⌃← / ⌃→). If you turned them off, a direct switch is
  used as a last resort and can leave stale Mission Control or Dock UI on screen; `killall Dock` fixes that harmlessly.
- **A window is missing from the switcher:** run `Switchmypanes --list-windows` (below) to see what macOS reports.
- **Linked resizing does not react:** no line when you hover the middle of the seam means the group was not created.
  Quit Switchmypanes, run it from Terminal with `SWITCHMYPANES_DEBUG=1 ~/Applications/Switchmypanes.app/Contents/MacOS/Switchmypanes`,
  reproduce it, and keep the lines starting with `[linked]` for a bug report.

## Diagnostics
Run the binary with a flag: `~/Applications/Switchmypanes.app/Contents/MacOS/Switchmypanes <flag>` (or the copy in
`build/`). `--help` lists them.

| Flag | What it does | Side effects |
|---|---|---|
| `--list-windows` | prints the windows the switcher would show, with desktop / minimized status and whether a preview could be captured; `--exclude=<bundle id>` tries an exclusion | none |
| `--render-overlay <folder>` | draws the overlays and the Preferences window offscreen, with sample windows, into PNG files (the blur is approximated by a flat fill) | none |
| `--selftest-overlay` | opens the real overlay once per look (Glass / Frosted / Dark) and checks it comes up and goes away | the overlay flashes on screen three times, about a second each |
| `--selftest-motion` | plays the snap animation once and checks it appears and then disappears completely | flashes a glowing rectangle on screen for about half a second |
| `--selftest-linked` | links helper windows and drags the divider through Accessibility (normal apps, a stubborn app, slow apps, and the hover behaviour); prints PASS/FAIL | opens nearly invisible helper windows in the bottom-right corner for about a minute |
| `--selftest-spaces` | checks going to a window on another desktop whose app also has a window here | **switches your desktop and back**; says SKIPPED if you have no such setup |
| `SWITCHMYPANES_DEBUG=1` (environment variable) | logs what linked resizing is doing | none |

## Known limits
- Windows on other desktops are shown with their last picture (or the app icon if none yet); snapping features only
  work on the current desktop, because Accessibility cannot move windows on desktops that are not showing.
- A window minimized less than about a second ago may not be listed yet.
- With a very large number of windows the overlay shows only as many as fit the screen.
- Linked resizing covers Snap Layouts and Snap Assist groups only, and apps differ in how quickly they follow a resize.
- Not covered by automated tests, because they need real screens and permission dialogs: multiple displays and
  Spaces behaviour on other Macs, and real-app feel. Please report what you find.

## Testing
```bash
swift run CoreChecks     # the logic (geometry, snapping state machine, ordering, shortcut rules, linked resizing...)
```
XCTest is not available with only the Command Line Tools, so the logic checks are a plain executable
(`Sources/CoreChecks`). The self-tests above exercise the app against real windows.

<details>
<summary>Manual test checklist</summary>

1. **Setup**: `./build.sh install`, grant the permissions; the checklist should say the shortcuts are active.
2. **Switcher**: with 4+ windows in 2+ apps, hold Option and tap Tab: the second window is preselected; Tab, Shift+Tab and the arrows move; releasing Option switches; Esc cancels; clicking a tile switches. Two quick taps toggle between the last two windows.
3. **Close**: hover a tile and click ✕, or press Delete / W: the window closes and the overlay re-flows. A TextEdit document with unsaved text keeps its tile (the save sheet appears).
4. **Minimized / hidden**: minimize a window and hide another app (Cmd+H): both appear tagged; choosing one brings it back.
5. **Desktops**: put an app full screen and keep another of its windows on your main desktop. From the main desktop open the switcher and pick the full-screen one (and back): the slide animation plays, the right window is in front, and no Mission Control or Dock UI lingers.
6. **Previews**: work in two windows for a few seconds each, switch desktop, open the switcher: both have pictures. Add an app to "never take previews": its tile shows only the icon.
7. **Keyboard snapping**: Control+Option+←/→/↑/↓, then Left then Up (and Down) for quarters; Down on a snapped window restores it; Down on an unsnapped window minimizes it. Add Shift with a second display to move the window across.
8. **Drag to snap**: drag a title bar to each edge and corner; the preview follows; release snaps; dragging across the middle of two displays does not snap.
9. **Snap Assist**: snap a window Left; other windows appear over the right half; Return fills it; Esc, a click elsewhere, or Control+Option+Up right after the snap closes it.
10. **Snap Layouts**: Option+Z, press 3 ("Three columns"), place three windows with Return; try Space (skip), Esc, and a click outside. Set a gap in Preferences and repeat: gaps are even.
11. **Linked resizing**: after "Halves" no line is visible; hover the middle of the seam: it fades in; drag it: both windows resize; move away: it fades out; hovering near the ends of the seam does nothing. Try "Grid 2 × 2", "Three columns", and a Snap Assist pair. Drag toward an app with a large minimum width: the line stops, nothing overlaps, dragging back works. Drag a window away by its title bar: it leaves the group.
12. **Exclusions**: add Safari with only "Hide from switcher": it disappears from the switcher but still snaps; with only "Never snap": the snap shortcuts, dragging and Assist ignore it.
13. **Preferences**: record a new Snap Layouts shortcut (⌃⌥B) and check the old one stops working; ⌘Tab and ⌥← are refused; record ⌃⌥Tab for the switcher (releasing either key commits); the reset arrows work; while recording, the current shortcut does not trigger.
14. **Open at login**: turn it on from the installed copy, approve it in System Settings if asked, log out and in: the menu bar icon returns.
15. **Look and animation**: open the switcher: a glass panel, a hint bar along the bottom, tags on other-desktop / minimized tiles, and a highlight ring that slides as you press Tab. Snap a window with Control+Option+Left, drag one to an edge, and fill a layout: a glowing outline travels to where each window lands and fades. Turn Reduce motion on in System Settings → Accessibility → Display: the overlays appear instantly and nothing animates.
16. **Menu bar**: Pause stops every shortcut; Resume restores them; Quit removes the icon.
</details>
