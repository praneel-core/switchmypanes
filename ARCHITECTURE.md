# Switchmypanes: architecture

A native Swift / AppKit menu bar app for macOS 14+ (Apple Silicon). Local only: no network code, no analytics.

## Design principles

1. **Logic is separate from the screen.** Everything that can be wrong in subtle ways (geometry, the snapping state
   machine, ordering, which keys are ours, linked-resize maths, shortcut rules) lives in `SwitchmypanesCore` as plain
   Swift values in, values out. It is checked by `swift run CoreChecks` without a screen, permissions or other apps.
2. **Private APIs are isolated, optional and self-checking.** Each one sits behind a small protocol, is looked up by name
   at runtime (`dlsym`), and has a fallback. If macOS removes one, the app degrades; it never crashes.
3. **Never leave the screen in a stuck state.** Every overlay has a way out: tap disabled by macOS, modifier released,
   timeout, outside click, pause, quit. The event tap and all overlays are torn down on exit.
4. **Do not trust an app to do what it was asked.** Apps apply resizes late, drop half of a size-plus-position pair, or
   refuse sizes. Anything that depends on a window's real frame is decided from a settled reading, not an instant one.

## Folder structure

```
Package.swift
Sources/
  SwitchmypanesCore/            pure logic, fully tested
    Geometry.swift                coordinate conversion (AppKit <-> top-left), DisplayInfo, DisplayLayout
    SnapEngine.swift              zone frames and detection, the Win+Arrow state machine, drag-to-edge zones, RestoreMemory
    SnapLayout.swift              the nine Snap Layouts presets with gap-aware zone frames
    SnapMotion.swift              when the snap animation plays and how long (`SnapMotionPolicy`)
    LinkedResize.swift            shared-divider resizing, dividers, hover zones, MinSizeLearning
    Switcher.swift                MRUList, SwitcherSelection (the "second window first" rule, spatial arrow keys), OverlayGrid (the grid layout rule shared by drawing and navigation)
    SpaceClassifier.swift         which windows belong in the switcher (current / other desktop / minimized / junk)
    KeyClassifier.swift           what a key press means: the ONLY place that decides which keys we swallow
    ShortcutRules.swift           shortcut display names and ShortcutValidator (which combinations are allowed)
    AppExclusions.swift           per-app exclusion rules (switcher / snapping scopes), bundle-ID matching
    PreviewPolicy.swift           never-capture list and when automatic captures may run
  Switchmypanes/                the app
    main.swift                    entry point, diagnostic flags (--help, --list-windows, --selftest-*)
    AppDelegate.swift             wiring and lifecycle, the switchmypanes:// URL scheme
    StatusItemController.swift    menu bar icon and menu
    PermissionManager.swift, OnboardingWindow.swift    permission checks and the live checklist
    SettingsStore.swift, PreferencesView.swift         settings (SwiftUI is used only for Preferences)
    ShortcutRecorder.swift, ModifierFlags.swift        click-to-record shortcuts
    LoginItem.swift               open at login (SMAppService)
    KeyboardMonitor.swift         the CGEventTap
    WindowInventory.swift         window list, MRU tracking, minimized/hidden confirmation, exclusions
    SwitcherController.swift, SwitcherPanel.swift      the Option+Tab overlay
    ThumbnailService.swift, PreviewKeeper.swift        previews: capture, in-memory cache, when to capture
    WindowActivator.swift         bring a window forward / close it, across desktops
    SnapController.swift, WindowMover.swift            keyboard snapping, applying frames to windows
    DragSnapController.swift, ZonePreviewOverlay.swift drag to an edge, with a preview
    SnapMotion.swift              the snap animation: spring-animated Core Animation layers in one click-through panel (rules: Core `SnapMotionPolicy`)
    OverlayTheme.swift            the shared overlay look: three glass styles (real Liquid Glass `NSGlassEffectView` on macOS 26+, system blur materials before), tags, fade-in (and Reduce-motion handling)
    OverlayPreview.swift          `--render-overlay`: draws the overlays and Preferences offscreen to PNG for checking the look
    SnapAssistController.swift    the empty half after a half-snap
    LayoutPickerController.swift, LayoutChoicePanel.swift   Snap Layouts
    LinkedGroupController.swift, DividerOverlay.swift  linked resizing and the draggable line
    DisplayProvider.swift         the ONLY NSScreen -> top-left conversion
    AX.swift                      small, forgiving Accessibility helpers
    WindowIDProvider.swift  (private)   CGWindowID <-> AXUIElement
    SpaceProvider.swift     (private)   desktops: list, which window is where, switching
    WindowFocusProvider.swift (private) focus one exact window on any desktop
  CoreChecks/main.swift         the test runner (XCTest is not available with only the Command Line Tools)
Support/Info.plist              no Dock icon, URL scheme, bundle id
build.sh, tools/create-signing-identity.sh
```

## Public vs private API

| Area | API | Public? |
|---|---|---|
| List windows | `CGWindowListCopyWindowInfo` (`.optionOnScreenOnly`, or `.optionAll` to include other desktops) | public |
| Move, resize, raise, minimize, close | Accessibility (`AXUIElement`, `AXObserver`) | public |
| Window thumbnails | ScreenCaptureKit `SCScreenshotManager` | public |
| Keyboard shortcuts | `CGEventTap` | public |
| Mouse (drag to edge, hover) | `NSEvent` global monitors (no extra permission) | public |
| Open at login | `SMAppService.mainApp` | public |
| Match a CG window with its AX window | `_AXUIElementGetWindow` | **private**, `dlsym`; missing -> match by frame and title |
| Which desktop a window is on, desktop kinds, "is it really showing" | `CGSCopySpacesForWindows`, `CGSCopyManagedDisplaySpaces`, `CGSMainConnectionID`, `CGSWindowIsOrderedIn` | **private**, `CGSSpaceProvider` with a self-test; failure -> `CurrentSpaceOnlyProvider` (current desktop only) |
| Switch to a window's desktop | the user's own "Move left/right a space" shortcut, read with `CGSGetSymbolicHotKeyValue` and pressed with synthetic key events, so the Dock switches | **private** (the shortcut lookup only), in `CGSSpaceProvider.switchToSpace` |
| Focus one exact window | SkyLight `_SLPSSetFrontProcessWithOptions` + `SLPSPostEventRecordTo`, `GetProcessForPID` | **private**, `SkyLightWindowFocus`; missing -> ask the app to come forward |
| (last resort only) direct desktop switch | `CGSManagedDisplaySetCurrentSpace` | **private**; it bypasses the Dock, which then shows stale Mission Control UI, so it is used only if the shortcut route fails |

## Permissions

| Permission | Used for | Required |
|---|---|---|
| Accessibility | move/raise windows, read titles; lets the event tap swallow keys | yes |
| Input Monitoring | the event tap seeing the shortcut keys | yes (the live "shortcuts active" line is the real test) |
| Screen Recording | previews, and window titles from `CGWindowList` | optional |

## How the main flows work

### Option+Tab
```
key event ─► KeyboardMonitor (event tap, main run loop)
              KeyClassifier.classifyKeyDown(keyCode, modifiers, switcherActive, ...)
   passThrough ─► the app receives the key untouched
   switcherOpen ─► SwitcherController.begin
                    window snapshot in MRU order, selection starts on index 1
                    after 120 ms the panel appears (a quick tap commits before that: no flash)
   Tab / Shift+Tab / arrows / mouse ─► selection moves
   modifier released (event, or the 0.1 s watchdog sees it up) ─► commit ─► WindowActivator ─► MRU updated
   Esc ─► cancel
```
The window list comes from `CGWindowList`; `SpaceClassifier` (Core) decides what to include; windows that look
minimized/hidden are confirmed through Accessibility in the BACKGROUND (never on the key-press path). A window on
another desktop that is not "ordered in" is a closed-to-background ghost (Claude, Slack…) and is dropped unless it was
verified minimized earlier. Untitled windows that Accessibility does not recognise (Chrome's full-screen toolbar strip)
are dropped too.

### Going to a window on another desktop
`WindowActivator`: (1) `SpaceProvider.switchToSpace` presses the user's "Move left/right a space" shortcut once per
desktop to cross, and waits until macOS has really arrived; (2) `WindowFocusProvider` focuses that exact window; (3) the
Accessibility raise is retried until the window becomes reachable. Asking only the APP to come forward is not enough:
if the app also has a window on the current desktop, macOS focuses that one and never switches. Closing a window on
another desktop uses the same path, then presses the close button.

### Snapping
State is **detected, not remembered**: `detectZone` compares the window's real frame with each zone (12 pt tolerance), so
it works even if you moved the window by hand. Only the pre-snap frame is remembered, for restore.

```
unsnapped: ← left half   → right half   ↑ maximize        ↓ minimize
maximize:  ← left half   → right half   ↑ -               ↓ restore
left:      ← next display (as right half) | → restore     ↑ top-left      ↓ bottom-left
right:     ← restore     → next display (as left half)    ↑ top-right     ↓ bottom-right
top-left:  ← prev display | → top-right ↑ maximize         ↓ bottom-left
top-right: ← top-left    → next display | ↑ maximize       ↓ bottom-right
bottom-left:  ← prev display | → bottom-right  ↑ top-left  ↓ restore
bottom-right: ← bottom-left  → next display | ↑ top-right  ↓ restore
Shift + ←/→ : move to the neighbouring display keeping the zone
```
(The full table is `SnapEngine.transition`.) Coordinates: AppKit is bottom-left, Accessibility is top-left; all logic uses
top-left and converts once, in `DisplayProvider`. Drag to an edge, Snap Assist and Snap Layouts all place windows through
`SnapController.place`, so restore and linked-group release behave the same everywhere.

Snap Layouts and Snap Assist are modal: while one is open, `KeyClassifier` (with a `pickerActive` / assist flag) owns the
keyboard. Safety nets: outside click, timeout, tap disabled, pause and quit all close it. Assist is lighter: any key that is
not its own closes it and is then re-classified normally, so chained snaps still work.

### Linked resizing
`LayoutPickerController` and `SnapAssistController` report the windows they placed; `LinkedGroupController` records
a group. The pieces:

- **Geometry (Core, tested):** `LinkedResize.dividers` finds each divider (flood fill along a shared line, gap-aware);
  `dragDivider` computes every window's frame for a line position as an absolute function of (layout when grabbed, line
  position, learned minimum sizes); `resolve` does the same for a window dragged by its own edge.
- **The line (`DividerOverlay`):** one thin, non-activating panel per divider, hidden and click-through until the cursor
  hovers the middle of the seam (`Divider.revealZone` / `keepZone`); driven by global and local mouse-moved monitors.
- **Driving the windows:** dragging the line sets every window itself, shrinking window first, and with NO read-backs
  mid-drag, because apps apply resizes late and can drop either the size or the position of a back-to-back pair.
- **Settling:** after you pause, `verify` compares reality with the intent. A window that is off gets the missing change
  re-sent, one change at a time. Only a window that stays too big after repairs, on two readings, has its minimum learned
  (`MinSizeLearning`), and the group is re-applied from the grab-time layout.
- **Resizing a window by its own edge** is still noticed, by AX notifications and by polling on mouse-drag events.
- **When the line may show:** only where the seam is really visible. `Divider.probePoints` / `isUncovered` (Core, tested) look at the topmost window just inside each side of the seam; if it is not one of the group's windows on that side (even another window of the same app) the line stays hidden and cannot be revealed. It is re-checked whenever the front window or the desktop changes, and right before the line fades in.
- **Leaving a group:** dragging a window away, snapping it (`SnapController.onWillMoveWindow`) or closing it.

`--selftest-linked` proves all of this against separate helper processes, including windows that apply sizes late and a
window that refuses to shrink.

### Previews
A window cannot be captured while it is not showing, so `PreviewKeeper` captures a window when you leave it, and once after
you settle into it, with a slow refresh for a long stay. It is gated by `PreviewPolicy` (off, paused, locked, idle, Low
Power) and by the never-capture list, which is enforced in one place (`ThumbnailService.isAllowed`) for both capturing and
displaying. Pictures live in memory only (capped).

## Decisions

- **Snap animation is a travelling outline, not a sliding window.** Stepping a real window's frame stutters, because apps apply
  resizes late and drop half of an update (see linked resizing); a picture of the window sliding needs the real window hidden
  meanwhile, which macOS does not allow cleanly, and would otherwise show two copies. A glowing outline that travels from the
  old frame to the new one and pulses shows the motion with no such risk, needs no screen-capture permission, and cannot
  disturb the window.
- **Overlays keep most-recently-used order.** They do not group "this desktop" / "other desktops" into sections, because that
  would reorder the list and break the quick-tap toggle; colour-coded tags carry that information instead.
- **Cmd+Tab and Cmd+\` are never overridden.** Swallowing them and disabling the native shortcut needs private APIs that can
  leave the system shortcut disabled if the app crashes. The shortcut recorder refuses to assign them.
- **No Option+\` per-app cycling.** Built, then dropped: macOS already cycles an app's windows with Cmd+\`, and Windows'
  Alt-Tab has no such mode. The code is on the unmerged branch `feature/per-app-cycling`.
- **Switch desktops through the Dock.** The direct `CGSManagedDisplaySetCurrentSpace` call works but leaves the Dock out
  of sync (stale Mission Control strip, Dock over a full-screen window, broken navigation back). Pressing the user's own
  shortcut keeps the Dock in charge.
- **No "all screens / current screen only" switcher setting yet.** It was in the original brief but only matters with more
  than one display; it can be added later as a filter on the window list using `DisplayLayout`.

## Not built (ideas)
Linked groups from windows lined up by hand (needs guessing from positions); raising a group together; a Task View-style
overview; live-updating thumbnails while the overlay is open; the all-screens setting above.
