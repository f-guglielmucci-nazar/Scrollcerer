# Task: add Windows-style autoscroll to MouseRemap

You are picking up an existing, working macOS menu-bar app (Swift, AppKit + a little SwiftUI) that remaps mouse buttons. Add **Windows-style middle-button autoscroll**, behaving as close to Windows (Chrome/Edge on Windows) as possible, without breaking middle-click on links (open in new tab) or other normal middle-click uses.

The user tests on their Mac and will report how it feels. Build, run and iterate yourself; ask the user only for things you can't check (how scrolling feels, whether a click did the right thing in a given app).

---

## 1. The project as it is now

```
MouseRemap/
  build.sh            builds build/MouseRemap.app, installs to /Applications, launches it
  Info.plist          bundle id local.mouseremap, LSUIElement (menu-bar only), macOS 13+
  README.md           user-facing instructions
  Sources/
    main.swift        NSApplication bootstrap (accessory app)
    AppDelegate.swift status-bar menu, Settings window, Accessibility permission polling
    Remapper.swift    CGEvent tap (session, head insert, active filter) on otherMouseDown/Up/Dragged + scrollWheel
    Actions.swift     ActionKind enum (all choices in the pop-ups), synthesizing keys/media keys/middle click
    Config.swift      Config (UserDefaults-backed ObservableObject), AppStatus, Permissions
    SettingsView.swift SwiftUI Settings window, per-button rows with a "lights up when pressed" dot, shortcut recorder
```

How it works:
- `Remapper.handle` gets every extra-button and scroll event. Button numbers: 2 = wheel click, 3/4 = side buttons. Each button maps to a `ButtonAction` (`ActionKind` + optional recorded `Shortcut`).
- Wheel **tilt** arrives as sideways-only, non-continuous scroll events. It's turned into pseudo-buttons `Config.tiltLeft` (100) / `Config.tiltRight` (101) in `handleTilt`, debounced so a held tilt fires once. (Sign was verified on the user's mouse: `DeltaAxis2 > 0` = tilt **right**.)
- Optional "reverse scroll" flips vertical deltas of non-continuous (notched wheel) scroll events only.
- `Actions.middleClick()` posts synthetic middle clicks to `.cgAnnotatedSessionEventTap` so our own tap doesn't see them again.

### Build environment constraints (learned the hard way)
- The user has **Command Line Tools only, no Xcode**. Build with `bash build.sh` (uses `xcrun swiftc`, ad-hoc `codesign`).
- **Do not use SwiftUI macros**: `@State`, `@Observable`, `@Bindable`, `#Preview`, etc. fail with `plugin for module 'SwiftUIMacros' not found`. Keep state in `ObservableObject` classes with `@Published` and `@ObservedObject` (these work).
- `build.sh` runs under macOS's **bash 3.2**: write `${VAR}`, never put non-ASCII characters directly after `$VAR`.
- Swift language mode 5 (`-swift-version 5`), target `$(uname -m)-apple-macos13.0`. The user's Mac is Apple silicon. Check `sw_vers` for the OS version.
- Every rebuild changes the ad-hoc signature, so `build.sh` resets the Accessibility approval (`tccutil reset Accessibility local.mouseremap`) and the user has to re-allow it. Avoid rebuild loops that need the user each time. Batch changes, and tell the user when a build needs re-approval.
- Suggest putting the folder under git before starting (`git init`, first commit), so each step can be reverted.

---

## 2. Exact behaviour to build (Windows autoscroll)

Add a new `ActionKind.autoscroll`, titled **"Autoscroll (Windows style)"**, selectable for any button but meant for the wheel click (button 2). Make it the default for button 2 only if the user agrees; otherwise leave the default as "Default (no change)".

### 2.1 Starting
When the autoscroll button goes **down**:
1. Decide whether this press should autoscroll or be passed through as a normal middle click (see §3, link and target detection).
2. If it's a pass-through, the app it lands on must see a completely normal middle click: down, any drags, and up, at the original position, in order.
3. If it's autoscroll, the **anchor** is the pointer position at the moment of the press. Show the marker (§2.5) centred on the anchor. Don't let the original down/up reach the app.

### 2.2 Two modes, decided on release (as on Windows)
- **Toggle mode:** press and release **without moving the pointer beyond the dead zone** while held. Autoscroll stays on after release, and the user moves the mouse freely to scroll.
- **Hold mode:** press, and while still holding, move beyond the dead zone. Scrolling happens while held and **stops when the button is released**.

### 2.3 Scrolling
- The offset from the anchor sets the scroll velocity, on both axes independently.
- **Dead zone:** inside a radius around the anchor (start ~15 px), nothing scrolls.
- **Speed curve:** speed grows with distance beyond the dead zone, gently at first and quickly far out, as in Chrome on Windows. Start with something like `v = k * (d - deadZone)^1.5`, capped. Put the constants in one place so they're easy to tune. Expose a single "Autoscroll speed" slider in Settings if it's cheap to do.
- **Direction is Windows-style:** pointer below the anchor means the content moves as if scrolling **down** (toward the end of the document). Likewise for up, left and right. This must hold whatever the user's macOS "Natural scrolling" setting is. Check how synthetic scroll events interact with that setting and correct for it.
- **Smooth:** post pixel-unit scroll events (`CGEvent(scrollWheelEvent2Source:units: .pixel, ...)`) from a ~60–120 Hz timer (or a display link). Accumulate sub-pixel remainders so slow speeds still creep smoothly.
- **Target:** on Windows the scrolling stays with the window where autoscroll started, even when the pointer wanders over another window. On macOS, scroll events go to the window under the event's location, so **set each synthetic scroll event's location to the anchor** (and check this works in Safari, Chrome and Finder).
- Synthetic scroll events must be ignored by our own tap's tilt detection and "reverse scroll" logic. Tag them, for example with `eventSourceUserData` set to a magic value, and skip tagged events at the top of the scroll handler.
- If the target area can only scroll on one axis, ignore the other axis (Windows does this). Use the AX scroll bars (§3) when you can tell; otherwise allow both.

### 2.4 Ending (toggle mode)
Autoscroll ends, and the marker disappears, on any of these:
- **any mouse button press** (left, right, middle, side). That click is **consumed** and does not reach the app, as on Windows/Chrome;
- **Esc** (consumed);
- any other key press (ends autoscroll; the key is passed through);
- a real wheel scroll or tilt (ends autoscroll; pass the scroll through);
- the frontmost app changing, or the screen locking or sleeping.
Hold mode ends on release of the button.

Keyboard events need to be watched only while autoscroll is active. Either add a second keyboard event tap created and removed with the session, or add `keyDown` to the main tap's mask and return immediately when inactive. Keep the inactive path negligible.

### 2.5 Marker (the round icon)
- A borderless, transparent, click-through window (`ignoresMouseEvents = true`), at a level above normal windows (e.g. `.statusBar` or higher), shown on all Spaces (`collectionBehavior` `.canJoinAllSpaces`, `.stationary`, `.fullScreenAuxiliary`), centred on the anchor.
- Look: like Windows, a ~28–32 px circle with a light fill and dark outline, a dot in the centre, and small triangles pointing in the scrollable directions (up/down, left/right, or all four). It should read well in light and dark mode.
- Nice to have: a small direction indicator near the pointer while scrolling. On Windows the pointer itself becomes a directional arrow; macOS doesn't let us change another app's cursor, so only do this as an overlay if it looks good. Optional.

---

## 3. Link, tab and target detection (must keep new-tab clicks working)

Rule: **autoscroll only when the pointer is over a scrollable area and not over a link.** Everything else passes through as a normal middle click. That covers:
- links, which open in a new tab;
- browser tabs, where middle-click closes the tab;
- Dock icons, menu bar items, and anything that isn't a scroll area.

Implementation:
- `AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), x, y, &element)`, then walk up `kAXParentAttribute` (cap ~25 levels):
  - if any element on the way has role `AXLink` (`kAXLinkRole`), it's a **link**: pass through;
  - if you reach `AXScrollArea` or `AXWebArea` first (before any link), it's **autoscroll**. Remember that scroll area's `AXVerticalScrollBar` / `AXHorizontalScrollBar` to decide which axes are allowed;
  - if you reach the window or app element without finding either, **pass through**.
- **Chromium and Electron apps** (Chrome, Edge, Brave, Arc, VS Code, Slack, Discord…) only expose a full AX tree when asked. Set `AXEnhancedUserInterface` (Chromium) or `AXManualAccessibility` (Electron) to `true` on the app's `AXUIElementCreateApplication(pid)` once per pid, and cache that. The very first lookup in such an app may come back too shallow; consider retrying once after setting the attribute. Watch for known side effects of `AXEnhancedUserInterface` (e.g. odd window animations) and mention any you see.
- **Speed and safety:**
  - Never block the event tap callback. Call `AXUIElementSetMessagingTimeout` with a short value (~0.1–0.2 s) on the elements you query, and run the lookup off the tap callback, for example on a serial background queue.
  - Because the lookup is asynchronous, **swallow the original middle-down** and queue any following drag/up events for that button until the decision arrives. Then either replay the queued events in order at their original positions as a normal click (posted so our tap skips them, tagged or via `.cgAnnotatedSessionEventTap`), or start autoscroll.
  - If the lookup times out or fails, fall back to **pass through**.
  - Note the delay this adds to normal middle-clicks; it should be imperceptible.
- **Firefox:** Firefox has its own autoscroll setting (off by default on Mac). If it's on, ours and Firefox's would fight. Test Firefox with its setting off; mention this in the README.

---

## 4. Settings UI

- Add the new action to the pop-ups in `ActionKind.groups`. A sensible place is the first group, after "Middle click".
- When a row is set to Autoscroll, show a one-line caption under it: *"Click to toggle, or hold and move. Links and tabs still get a normal middle click."*
- Optional "Autoscroll speed" slider (stored in `Config`, `@Published` + UserDefaults, no SwiftUI macros).
- Update `README.md`, including the Firefox note.

---

## 5. Test checklist (go through it with the user)

Autoscroll, in each of Safari, Chrome, Firefox (its own autoscroll off), Finder (list view of a big folder), TextEdit or Notes with a long document, Preview (multi-page PDF), and VS Code:
- [ ] quick click → marker appears, moving away scrolls, speed grows with distance, nothing scrolls inside the dead zone
- [ ] pointer below anchor scrolls toward the end of the document, with Natural scrolling **on** and **off**
- [ ] hold + move → scrolls; release → stops
- [ ] in toggle mode, a left click ends it **and is not passed through**; Esc ends it; another key ends it and types; a wheel scroll ends it
- [ ] the pointer wandering over another window keeps scrolling the original one
- [ ] horizontally scrollable content (wide table/page) scrolls sideways; vertical-only content ignores sideways movement

Middle click still normal:
- [ ] middle-click a link in Safari, Chrome and Firefox → opens in a new tab, no marker
- [ ] middle-click a browser tab → closes it
- [ ] middle-click a Dock icon / non-scrollable UI → normal middle click
- [ ] no noticeable delay on normal middle clicks

Nothing else broken:
- [ ] side buttons and wheel tilt actions still work; tilt still debounced
- [ ] "Reverse scroll" still affects only the real wheel, never autoscroll's synthetic events
- [ ] Settings dots still light up for each button
- [ ] no "event tap disabled" stalls (`log stream --predicate 'process == "MouseRemap"'` while testing)

## 6. Done means
Every box above is checked by the user. The code builds cleanly with `bash build.sh` on Command Line Tools. The README is updated. Changes are committed in small, described steps.
