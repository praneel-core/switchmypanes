# Changelog

## Unreleased

- Type to search in the Option+Tab overlay: start typing and only windows whose app name or title contains your words stay (matching is in Core, tested). ⌫ edits the text, Esc clears it (a second Esc cancels). **Closing a window is now ⌘W** (Delete and W are typing keys); the ✕ still works. While the overlay is open the typed characters are read to search, never stored or logged.
- Respects macOS's *Reduce transparency*: the overlays switch to the solid Dark look automatically (rule in Core, tested).
- App icon: three glass windows with one lit and a divider grip, in the same glass style as the app (drawn in code by `tools/make-app-icon.swift`).
- Transparency slider for the overlay glass (default 35%): only the glass fades, the tiles and text stay sharp. The glass is now a separate layer behind the content.
- A new close button on tiles: a small dark glass disc with a thin ×, fading in on hover and turning soft red when pointed at, replacing the stock red icon.
- Removed the keyboard-hint bar from the overlays: it took up space the tiles need. The panels now size to their content alone.
- Down / Up in the overlay now go to the tile directly below / above (the nearest one when nothing is exactly there), which matters because a short last row is centred. The grid rule is shared by the drawing code and the navigation (`OverlayGrid`), and `--selftest-arrows` checks every move against the drawn positions.
- The divider line no longer floats over a window that is not in its group: it stays hidden whenever another window covers the seam.
- Overlay transparency: three looks (Glass, Frosted, Dark) in Preferences; Glass (default) is much clearer, using real Liquid Glass on macOS 26 and soft text shadows for legibility.
- New overlay look for the window switcher, Snap Assist and Snap Layouts: glass panels, a highlight that slides between tiles, colour-coded tags, a centred last row, and a quick fade-in.
- Snap animation: a glowing outline travels from where a window was to where it lands (keyboard, drag, Snap Assist, Snap Layouts); switchable in Preferences.
- The snap animation is a spring-animated outline (smoother, with a trailing echo, glow no longer clipped).
- Arrow keys in the overlays always do something: in a single row Down = next and Up = previous; in a grid they wrap around.
- Preferences reorganised into five tabs.
- Reduce motion is respected everywhere.
- New diagnostics: `--render-overlay`, `--selftest-motion`.

## 0.1.0

First release. Windows-style Alt-Tab and window snapping for macOS (14+, Apple Silicon), as a menu bar app.
Free, fully local: no accounts, no network calls, no analytics.

**Window switcher (Option+Tab)**
- Switches between individual windows in most-recently-used order, with thumbnails; the second window is preselected so a quick tap toggles between the last two.
- Lists windows on other desktops and full-screen apps, and minimized / hidden windows, each tagged. Going to a window on another desktop switches to that desktop (through the Dock) and focuses that exact window, even when the same app also has a window on the current desktop.
- Close a window from the overlay (hover ✕, Delete or W). Apps that close windows to the background (Claude, Slack) and helper windows are not listed.
- Previews of windows on other desktops come from a privacy-conscious cache: captured when you leave a window, in memory only, never for password managers, off when locked / idle / in Low Power Mode.

**Snapping**
- Keyboard shortcuts with Windows Win+Arrow logic (halves, maximize, restore, quarters, move to another display), configurable gap.
- Drag a window to an edge or corner, with a translucent preview.
- Snap Assist: fill the empty half with another window after a half-snap.
- Snap Layouts (Option+Z): nine layouts, choose a window for each area.
- Linked resizing: windows placed by Snap Layouts or Snap Assist resize together by dragging a divider line that appears when you hover the middle of the seam. Handles apps that resize late and apps with large minimum sizes.

**Settings**
- Click-to-record shortcuts that refuse combinations clashing with macOS or text editing; toggles for every feature; per-app exclusions (hide from the switcher / never snap); open at login; permission checklist with live status.

**Quality**
- The logic lives in a separate, tested library (`swift run CoreChecks`). Self-tests exercise the app against real windows (`--selftest-linked`, `--selftest-spaces`, `--list-windows`; see `--help`).
- Private macOS APIs are isolated behind protocols with fallbacks, and documented in ARCHITECTURE.md.

**Known limits**: snapping works on the current desktop only; linked resizing covers Snap Layouts and Snap Assist groups; no "all screens / current screen" switcher setting yet (single-display tested only).
