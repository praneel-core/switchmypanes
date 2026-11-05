# Switchmypanes: architecture

Native Swift/AppKit menu bar app. macOS 14+, Apple Silicon. Local only: no network code, no analytics.

## Folder structure

```
Package.swift
Sources/
  SwitchmypanesCore/          PURE logic. No UI, no permissions. Fully tested.
    Geometry.swift              coordinate conversion, DisplayInfo/DisplayLayout (multi-display)
    SnapEngine.swift            zone frames, zone detection, Win+Arrow state machine, RestoreMemory
    Switcher.swift              MRUList, SwitcherSelection (the "second window first" rule)
    LinkedResize.swift          shared-divider resize geometry (which windows follow, minimum sizes, gaps)
    SnapLayout.swift            the nine Snap Layouts presets + gap-aware zone frames
    ShortcutRules.swift         shortcut display names + ShortcutValidator (which combinations are allowed)
    AppExclusions.swift         per-app exclusion rules (switcher / snapping scopes) + shared bundle-ID matching
    PreviewPolicy.swift         never-capture list + when automatic captures may run
    KeyClassifier.swift         "what does this key press mean": the only place that decides what we swallow
  Switchmypanes/              The app
    main.swift, AppDelegate.swift      wiring, lifecycle, switchmypanes:// URLs
    StatusItemController.swift         menu bar icon + menu
    PermissionManager.swift, OnboardingWindow.swift   permission checks + plain-language checklist (live)
    SettingsStore.swift, PreferencesView.swift        settings (SwiftUI only here)
    ShortcutRecorder.swift, ModifierFlags.swift       click-to-record shortcut rows; the keyboard listener steps aside while recording
    LoginItem.swift                    open at login via SMAppService
    KeyboardMonitor.swift              the CGEventTap
    WindowInventory.swift              window list + MRU tracking
    WindowIDProvider.swift  (PRIVATE)  CGWindowID <-> AXUIElement, behind a protocol
    SpaceProvider.swift                Spaces info, behind a protocol (Phase 1: current Space only)
    ThumbnailService.swift             ScreenCaptureKit thumbnails + cache
    SwitcherController.swift, SwitcherPanel.swift     the Option+Tab overlay
    WindowActivator.swift              raise + focus a window
    SnapController.swift, WindowMover.swift           keyboard snapping; place() is shared by drag + layouts
    DragSnapController.swift, ZonePreviewOverlay.swift  drag-to-edge with preview
    LinkedGroupController.swift                        linked resizing of Snap Layouts groups (AX observers)
    SnapAssistController.swift                         Snap Assist (empty half after a half-snap)
    LayoutPickerController.swift, LayoutChoicePanel.swift  Snap Layouts (Option+Z), reuses SwitcherPanel for the window step
    DisplayProvider.swift              the ONLY NSScreen -> top-left coordinate conversion
    AX.swift                           small Accessibility helpers
  CoreChecks/main.swift       test runner for SwitchmypanesCore (`swift run CoreChecks`)
Support/Info.plist            LSUIElement (no Dock icon), URL scheme, bundle id
build.sh, tools/create-signing-identity.sh
```

Why a separate Core library: everything that can be wrong in subtle ways (geometry, the snap state machine,
ordering, which keys are ours) is plain Swift values in, values out, so it can be checked without a screen,
permissions or another app.

## Public vs private API

| Area | API | Public? |
|---|---|---|
| List windows on the current Space | `CGWindowListCopyWindowInfo` | public |
| Move / resize / raise / minimize | Accessibility (`AXUIElement`) | public |
| Window thumbnails | ScreenCaptureKit `SCScreenshotManager` | public |
| Keyboard shortcuts | `CGEventTap` | public |
| Match a CG window with its AX window | `_AXUIElementGetWindow` | **private**, looked up with `dlsym`; missing -> nil -> frame/title matching |
| Which Space a window is on, and Space kinds | `CGSCopySpacesForWindows`, `CGSCopyManagedDisplaySpaces`, `CGSMainConnectionID`, `CGSWindowIsOrderedIn` (optional) | **private**, `dlsym` + self-test in `CGSSpaceProvider`; failure -> `CurrentSpaceOnlyProvider` |
| List windows including other Spaces | `CGWindowListCopyWindowInfo(.optionAll)` | public |
| Reliable cross-app activation fallback (only if needed) | SkyLight `SLPS*` | **private**, would live inside `WindowActivator` |

Two private rows exist today (window IDs, Spaces). Everything private is optional: losing it degrades, never crashes.

## Alt-Tab flow

```
key event ──► KeyboardMonitor (event tap, main run loop)
                │  KeyClassifier.classifyKeyDown(keyCode, modifiers, switcherActive, config)
                ▼
   passThrough ─► event goes on to the app untouched
   switcherOpen ─► SwitcherController.begin
                     snapshot windows (MRU order) ─► SwitcherSelection(count) → index 1 ("previous window")
                     isActive = true, watchdog timer starts
                     after 120 ms: show SwitcherPanel (cached thumbnails), start fresh captures
   Tab / Shift+Tab / arrows ─► selection moves ─► panel highlights
   mouse hover / click ─► hover selects (ignored until the mouse really moves) / click commits
   Option released (flagsChanged, or watchdog sees it up) ─► commit
   Esc ─► cancel
commit: end() (panel hidden, timers off) ─► WindowActivator.activate ─► WindowInventory.markUsed (MRU)
```

A quick tap commits before the 120 ms delay, so the overlay never flashes; MRU then makes the next quick tap
go back to where you came from. Stuck-state protection: tap disabled by macOS -> cancel; Option physically up
-> commit; open > 60 s -> cancel; app quit -> overlay and tap torn down.

## Snapping state machine

State is **detected, not remembered**: `detectZone` compares the window's real frame with each zone's frame
(12 pt tolerance), so it works even if you moved the window by hand in between.
Only the *pre-snap frame* is remembered (`RestoreMemory`) for restore.

```
unsnapped: ← left half   → right half   ↑ maximize        ↓ minimize
maximize:  ← left half   → right half   ↑ -               ↓ restore
left:      ← next display (as right half) | → restore     ↑ top-left      ↓ bottom-left
right:     ← restore     → next display (as left half)    ↑ top-right     ↓ bottom-right
top-left:  ← prev display | → top-right ↑ maximize         ↓ bottom-left
top-right: ← top-left    → next display | ↑ maximize       ↓ bottom-right
bottom-left:  ← prev display | → bottom-right  ↑ top-left  ↓ restore
bottom-right: ← bottom-left  → next display | ↑ top-right  ↓ restore
Shift + ←/→ : move to the neighbouring display keeping the zone (or relative position if unsnapped)
```
(The full table is `SnapEngine.transition`, covered by `CoreChecks`.) Coordinates: AppKit is bottom-left, the
Accessibility API is top-left; all logic uses top-left and converts once, in `DisplayProvider`.

## Permissions

| Permission | Used for | Required |
|---|---|---|
| Accessibility | move/raise windows, window titles; also needed for the event tap to swallow keys | yes |
| Input Monitoring | the event tap seeing the shortcut keys | yes (shown as such; the live "Shortcuts active" line is the real test) |
| Screen Recording | thumbnails and window titles from `CGWindowList` | optional (icons + titles instead) |

## Phase 2 plan (slots into the above)

- DONE: drag-to-edge (`DragSnapController`, `ZonePreviewOverlay`) and Snap Layouts (`LayoutPickerController`; modal keys are classified in `KeyClassifier` with a `pickerActive` flag; safety nets: outside click, 3-minute timeout, tap-disabled, pause and quit all cancel it).
- DONE: Snap Assist (`SnapAssistController`): `SnapController.onSnapped` -> 0.25 s delay -> `SwitcherPanel` centred on the empty half; `KeyClassifier` assist mode (`pickerDismiss` closes it and re-classifies the same key). Halves only; quarters are a possible follow-up.
- DONE: other desktops + full-screen apps in the switcher (`SpaceClassifier` in Core decides what to include; `CGSSpaceProvider` supplies the data; `WindowActivator` asks the app to come forward, then retries the exact raise while the Space switch settles). Snap Layouts / Assist deliberately stay on the current Space: Accessibility cannot move windows on other Spaces.
- DONE: close from the overlay (hover ✕, Delete / W): `KeyAction.switcherClose`, `WindowActivator.close` presses the AX close button, `SwitcherController.removeIfGone` re-checks after 0.25 s and 0.7 s so "Save changes?" windows keep their tile.
- DONE: minimized + hidden windows. macOS reports both as "not drawn, on the current Space" (`hiddenOrMinimized`); `WindowInventory` confirms through Accessibility in the BACKGROUND (never on the key-press path) and caches the label. Windows on other desktops that are not "ordered in" (`orderedOutElsewhere`, via private `CGSWindowIsOrderedIn`) are closed-to-background ghosts and are only listed if they were verified minimized earlier.
- DONE: closing a window on another desktop = switch there (`WindowActivator.onOtherSpace`), then press its close button once Accessibility can see it.
- DONE: event-driven preview cache. `WindowInventory.onFrontWindowChanged` -> `PreviewKeeper` captures the window you left, and the one you settled into (3 s), plus a 60 s refresh of that single window; gated by `PreviewPolicy` (Core, tested: off / paused / locked / idle / Low Power) and an exclusion list enforced in ONE place, `ThumbnailService.isAllowed` (capture AND display). Memory only, capped at 60.
- Switcher still to do: all-screens / current-screen option, live thumbnails.
- DONE: shortcut recorder (validated in Core by `ShortcutValidator`; `KeyboardMonitor.isSuspended` while recording) and launch at login (`SMAppService.mainApp`). Phase 2 is complete apart from the optional "all screens / current screen only" switcher setting.

## Phase 3 plan

- DONE (Snap Layouts groups only): linked resizing. `LinkedResize` (Core, tested) computes the new frames when a shared divider is dragged (flood fill along the divider, gap-preserving, minimum-size stop); `LinkedGroupController` registers the groups `LayoutPickerController` creates, watches members with public AX observers (resized / moved / destroyed), and applies the result with `WindowMover`. Apps with a bigger minimum than the default are handled by `MinSizeLearning` (Core, tested): the model keeps the INTENDED frames, `verify` compares with reality, and an app that is too big on two consecutive checks (so a slow app is not mistaken for a stubborn one) gets its real minimum remembered per app, after which `resolve` stops the divider there. Non-resizable windows are not linked. A window leaves its group when dragged away, snapped (`SnapController.onWillMoveWindow`) or closed. NOT built: raising a group together, groups from manual snaps / Snap Assist.
- Remaining: groups from other sources (manual snaps, Snap Assist) if wanted.
- DONE: per-app exclusions. `AppExclusion` (Core, tested) has two scopes; `WindowInventory.snapshot(for:)` filters the switcher and the Snap Assist / Snap Layouts lists, and `SnapController` / `DragSnapController` check before moving a window. Stored as JSON in UserDefaults.
- Task View-style overview.
- Live-updating thumbnails.
- Optional small item: "all screens / current screen only" switcher setting.

## Decisions

- **Cmd+Tab is never overridden** (cancelled 2026-11-05). Swallowing it and disabling the native shortcut needs private
  APIs that can leave the system shortcut disabled if the app crashes. Cmd+Tab and Cmd+` always belong to macOS; the
  shortcut recorder refuses to assign them.
- **No Option+` per-app cycling** (built, then dropped). macOS already cycles an app's windows with Cmd+`, and Windows'
  Alt+Tab has no such mode, so it added a shortcut without adding capability. The code is preserved on the unmerged
  branch `feature/per-app-cycling` if it is ever wanted.
