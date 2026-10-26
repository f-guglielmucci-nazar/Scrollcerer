import AppKit
import ApplicationServices
import CoreGraphics

/// Everything that sets how autoscroll feels, in one place.
enum AutoscrollTuning {
    /// Radius around the anchor (px) where nothing scrolls. Also how far the pointer has to
    /// move while the button is held to count as "hold mode".
    static let deadZone: CGFloat = 15
    /// Speed per axis in px/s: gain × (Settings slider) × (distance past the dead zone)^exponent.
    static let gain: Double = 1.5
    static let exponent: Double = 1.5
    static let maxSpeed: Double = 8000
    /// How often scroll events are posted (Hz).
    static let tickRate: Double = 120
    /// If the link/scroll-area check hasn't answered by then, the press becomes a normal middle click.
    static let decisionTimeout: TimeInterval = 0.35
    /// Per-call Accessibility timeout (s).
    static let axTimeout: Float = 0.15
    /// Sign of a synthetic scroll delta that moves toward the end of the document (down / right).
    /// macOS applies "Natural scrolling" in the HID layer, before events reach CGEvent, so
    /// synthetic events are never flipped and this stays fixed whatever that setting is.
    static let towardEnd: Double = -1
}

/// Put in `eventSourceUserData` of every event we post, so our own taps leave them alone.
let syntheticEventTag: Int64 = 0x4D52_4153 // "MRAS"

extension CGEvent {
    var isOurs: Bool { getIntegerValueField(.eventSourceUserData) == syntheticEventTag }
    func tagAsOurs() { setIntegerValueField(.eventSourceUserData, value: syntheticEventTag) }
}

/// Windows-style middle-button autoscroll. Everything runs on the main thread
/// (event tap callbacks included), except the Accessibility lookup.
final class Autoscroller {
    static let shared = Autoscroller()

    enum Verdict { case notMine, swallow, pass }

    private enum State {
        case idle
        /// Waiting for the link / scroll-area check. The press and anything after it is held back.
        case deciding(button: Int, generation: Int, queued: [CGEvent])
        /// Decided to be a normal middle click; the rest of this press goes through as button 2.
        case passthrough(button: Int)
        /// Autoscrolling while the button is still down. `moved` = left the dead zone (hold mode).
        case held(button: Int, moved: Bool)
        /// Clicked and released without moving: scrolls until something ends it.
        case toggled
    }

    private var state: State = .idle
    private var generation = 0
    private var anchor = CGPoint.zero
    private var axes = ScrollAxes(horizontal: true, vertical: true)
    private var timer: Timer?
    private var lastTick: TimeInterval = 0
    private var carryX = 0.0, carryY = 0.0
    /// The window under the anchor, and whether the pointer is still over it (rechecked a few times a second).
    private var target: TargetWindow?
    private var pointerOnTarget = true
    private var lastTargetCheck: TimeInterval = 0
    /// Where the pointer is while the button is held. Its drags are swallowed, and then the system's
    /// "current location" stays where it last saw an event, so we follow the drags ourselves.
    private var dragPointer: CGPoint?
    /// `defaults write local.scrollmate debugScroll -bool true` also logs autoscroll ticks.
    private let debug = UserDefaults.standard.bool(forKey: "debugScroll")
    private var lastDebugLog: TimeInterval = 0

    /// Presses that ended autoscroll are eaten; so are their drags and releases.
    private var swallowButtons = Set<Int>()
    private var swallowLeft = false, swallowRight = false, swallowEscUp = false

    private let marker = AutoscrollMarker()
    /// Left/right buttons and keys, needed only while autoscrolling: enabled on demand.
    private var auxTap: CFMachPort?

    var isScrolling: Bool {
        switch state {
        case .held, .toggled: return true
        default: return false
        }
    }

    private init() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification,
                     NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.stop() }
        }
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            self?.stop()
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                TargetProbe.prepareInBackground(app)
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"),
                                                            object: nil, queue: .main) { [weak self] _ in self?.stop() }
        if let front = NSWorkspace.shared.frontmostApplication { TargetProbe.prepareInBackground(front) }
    }

    // MARK: - Wheel-click (other mouse) events, from the main tap

    /// Looks at every other-mouse event before the button mapping does.
    func intercept(type: CGEventType, event: CGEvent, button: Int) -> Verdict {
        if type == .otherMouseDown {
            switch state {
            case .held(let held, _):
                swallowButtons.insert(held)
                fallthrough
            case .toggled:
                // Any press ends autoscroll and doesn't reach the app, as on Windows.
                stop()
                swallowButtons.insert(button)
                return .swallow
            case .deciding(let b, let g, let queued) where b == button:
                state = .deciding(button: b, generation: g, queued: queued + [event.copy()].compactMap { $0 })
                return .swallow
            default:
                swallowButtons.remove(button)
                return .notMine
            }
        }

        // Drag or release.
        if swallowButtons.contains(button) {
            if type == .otherMouseUp { swallowButtons.remove(button) }
            return .swallow
        }
        switch state {
        case .deciding(let b, let g, let queued) where b == button:
            state = .deciding(button: b, generation: g, queued: queued + [event.copy()].compactMap { $0 })
            return .swallow
        case .passthrough(let b) where b == button:
            event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
            if type == .otherMouseUp { state = .idle }
            return .pass
        case .held(let b, let moved) where b == button:
            dragPointer = event.location
            let beyond = moved || outsideDeadZone(event.location)
            if type == .otherMouseUp {
                if beyond { stop() } else { state = .toggled }   // hold mode ends; a plain click toggles
            } else {
                state = .held(button: b, moved: beyond)
            }
            return .swallow
        default:
            return .notMine
        }
    }

    /// The autoscroll button went down (and nothing else claimed it).
    func begin(button: Int, event: CGEvent) {
        generation += 1
        let gen = generation
        state = .deciding(button: button, generation: gen, queued: [event.copy()].compactMap { $0 })
        let point = event.location
        TargetProbe.queue.async {
            let result = TargetProbe.probe(at: point)
            DispatchQueue.main.async { self.decided(gen, result) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + AutoscrollTuning.decisionTimeout) {
            self.decided(gen, nil)
        }
    }

    /// `axes` nil = pass the click through.
    private func decided(_ gen: Int, _ result: ScrollAxes?) {
        guard case .deciding(let button, let g, let queued) = state, g == gen, let first = queued.first else { return }
        let released = queued.last?.type == .otherMouseUp

        guard let result = result else {
            // A normal middle click: replay it, in order, where it happened.
            state = released ? .idle : .passthrough(button: button)
            for e in queued {
                e.setIntegerValueField(.mouseEventButtonNumber, value: 2)
                e.tagAsOurs()
                e.post(tap: .cgSessionEventTap)
            }
            return
        }

        anchor = first.location
        axes = result
        dragPointer = queued.last { $0.type == .otherMouseDragged }?.location
        let beyond = outsideDeadZone(currentPointer())
        if released {
            if beyond { state = .idle; return }   // a whole hold-and-move happened before we knew
            state = .toggled
        } else {
            state = .held(button: button, moved: beyond)
        }
        startScrolling()
    }

    // MARK: - Ending

    /// Called for every real (non-synthetic) scroll: the wheel or the trackpad ends autoscroll.
    func realScroll() {
        if isScrolling { stop() }
    }

    func stop() {
        if case .deciding = state { return }   // not started yet; the decision handles it
        if case .passthrough = state { return }
        state = .idle
        timer?.invalidate()
        timer = nil
        marker.hide()
        updateAuxTap()
    }

    // MARK: - Scrolling

    private func startScrolling() {
        carryX = 0
        carryY = 0
        lastTick = ProcessInfo.processInfo.systemUptime
        target = TargetWindow.at(anchor)
        pointerOnTarget = true
        lastTargetCheck = lastTick
        marker.show(at: anchor, axes: axes)
        updateAuxTap()
        timer?.invalidate()
        let t = Timer(timeInterval: 1 / AutoscrollTuning.tickRate, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(now - lastTick, 0.05)
        lastTick = now

        let p = currentPointer()
        let dx = Double(p.x - anchor.x), dy = Double(p.y - anchor.y)
        if case .held(let b, false) = state, outsideDeadZone(p) {
            state = .held(button: b, moved: true)
        }
        guard outsideDeadZone(p) else {
            carryX = 0
            carryY = 0
            return
        }

        // Pointer below / right of the anchor = toward the end of the document.
        carryY += axes.vertical ? AutoscrollTuning.towardEnd * speed(for: dy) * dt : 0
        carryX += axes.horizontal ? AutoscrollTuning.towardEnd * speed(for: dx) * dt : 0
        let stepY = carryY.rounded(.towardZero), stepX = carryX.rounded(.towardZero)
        carryY -= stepY
        carryX -= stepX
        guard stepX != 0 || stepY != 0,
              let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                              wheel1: Int32(stepY), wheel2: Int32(stepX), wheel3: 0) else { return }
        e.tagAsOurs()
        if debug, now - lastDebugLog > 0.5 {
            lastDebugLog = now
            NSLog("Scrollmate autoscroll: \(state) pointer \(p) system \(CGEvent(source: nil)?.location ?? .zero) anchor \(anchor) step \(stepX),\(stepY) onTarget \(pointerOnTarget)")
        }
        if now - lastTargetCheck > 0.1, let target = target {
            lastTargetCheck = now
            pointerOnTarget = TargetWindow.at(p)?.id == target.id
        }
        if pointerOnTarget || target == nil {
            // Keep the event at the pointer: a posted event's location moves the cursor there.
            e.post(tap: .cgSessionEventTap)
        } else if let target = target {
            // The pointer wandered over another window: keep scrolling the original one (as on Windows)
            // by sending straight to its app, which doesn't move the cursor.
            e.location = anchor
            e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.id))
            e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(target.id))
            e.postToPid(target.pid)
        }
    }

    /// Signed px/s for an offset along one axis.
    private func speed(for offset: Double) -> Double {
        let past = max(0, abs(offset) - Double(AutoscrollTuning.deadZone))
        let v = min(AutoscrollTuning.maxSpeed,
                    AutoscrollTuning.gain * Config.shared.autoscrollSpeed * pow(past, AutoscrollTuning.exponent))
        return offset < 0 ? -v : v
    }

    private func outsideDeadZone(_ p: CGPoint) -> Bool {
        hypot(p.x - anchor.x, p.y - anchor.y) > AutoscrollTuning.deadZone
    }

    private func currentPointer() -> CGPoint {
        if case .held = state, let p = dragPointer { return p }
        return CGEvent(source: nil)?.location ?? anchor
    }

    // MARK: - Left/right buttons and keys (second tap, on only while needed)

    private func updateAuxTap() {
        let needed = isScrolling || swallowLeft || swallowRight || swallowEscUp
        if needed && auxTap == nil {
            var mask: CGEventMask = 0
            for t: CGEventType in [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                   .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                   .keyDown, .keyUp] {
                mask |= CGEventMask(1) << t.rawValue
            }
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                              options: .defaultTap, eventsOfInterest: mask,
                                              callback: autoscrollTapCallback, userInfo: nil) else {
                NSLog("Scrollmate: couldn't create the autoscroll key/click tap")
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            auxTap = tap
        }
        if let tap = auxTap, CGEvent.tapIsEnabled(tap: tap) != needed {
            CGEvent.tapEnable(tap: tap, enable: needed)
        }
    }

    fileprivate func handleAux(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            updateAuxTap()
            if let tap = auxTap, isScrolling { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass

        case .leftMouseDown, .rightMouseDown:
            let left = type == .leftMouseDown
            guard isScrolling else {
                if left { swallowLeft = false } else { swallowRight = false }
                updateAuxTap()
                return pass
            }
            if case .held(let b, _) = state { swallowButtons.insert(b) }
            if left { swallowLeft = true } else { swallowRight = true }
            stop()
            return nil

        case .leftMouseUp, .leftMouseDragged:
            guard swallowLeft else { return pass }
            if type == .leftMouseUp { swallowLeft = false; updateAuxTap() }
            return nil

        case .rightMouseUp, .rightMouseDragged:
            guard swallowRight else { return pass }
            if type == .rightMouseUp { swallowRight = false; updateAuxTap() }
            return nil

        case .keyDown:
            guard isScrolling else { return pass }
            let isEsc = event.getIntegerValueField(.keyboardEventKeycode) == 53
            if isEsc { swallowEscUp = true }
            stop()
            return isEsc ? nil : pass   // Esc is eaten; any other key also types

        case .keyUp:
            guard swallowEscUp, event.getIntegerValueField(.keyboardEventKeycode) == 53 else { return pass }
            swallowEscUp = false
            updateAuxTap()
            return nil

        default:
            return pass
        }
    }
}

private func autoscrollTapCallback(proxy: CGEventTapProxy,
                                   type: CGEventType,
                                   event: CGEvent,
                                   refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if event.isOurs { return Unmanaged.passUnretained(event) }
    return Autoscroller.shared.handleAux(type: type, event: event)
}

/// An on-screen window of another app.
struct TargetWindow {
    let id: CGWindowID
    let pid: pid_t

    /// The frontmost window at a point (CG coordinates), skipping our own (the marker, Settings).
    static func at(_ p: CGPoint) -> TargetWindow? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        let me = getpid()
        for w in list { // front to back
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.contains(p) else { continue }
            return TargetWindow(id: id, pid: pid)
        }
        return nil
    }
}

struct ScrollAxes: Equatable {
    var horizontal: Bool
    var vertical: Bool
}

// MARK: - What's under the pointer

/// Decides, with the Accessibility API, whether a press should autoscroll:
/// only over a scroll area or web page, and never over a link or a tab.
enum TargetProbe {
    static let queue = DispatchQueue(label: "local.scrollmate.autoscroll-probe")

    private static let systemWide: AXUIElement = {
        let e = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(e, AutoscrollTuning.axTimeout) // on the system-wide element: applies to all
        return e
    }()

    /// Pids we've already asked to expose their full AX tree (touched on `queue` only).
    private static var prepared = Set<pid_t>()

    /// nil = not a place to autoscroll (pass the click through).
    static func probe(at p: CGPoint) -> ScrollAxes? {
        guard let element = element(at: p) else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if prepare(pid: pid) {
            // A Chromium/Electron app was just asked for its full tree; the first answer is often too shallow.
            if let first = classify(element) { return first }
            usleep(80_000)
            return self.element(at: p).flatMap(classify)
        }
        return classify(element)
    }

    static func prepareInBackground(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        queue.async { _ = prepare(pid: pid) }
    }

    private static func element(at p: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &element)
        return err == .success ? element : nil
    }

    /// `defaults write local.scrollmate debugScroll -bool true` logs what was found under the pointer.
    private static let debug = UserDefaults.standard.bool(forKey: "debugScroll")

    /// Lists and tables are scrollable content even when the app (Mac Catalyst / UIKit apps such as
    /// WhatsApp) doesn't put a scroll area around them.
    private static let listRoles: Set<String> = [kAXListRole, kAXTableRole, kAXOutlineRole, kAXBrowserRole]

    private static func classify(_ start: AXUIElement) -> ScrollAxes? {
        var chain: [String] = []
        let result = walk(from: start, chain: &chain)
        if debug {
            NSLog("Scrollmate probe: \(result.map { "scroll h:\($0.horizontal) v:\($0.vertical)" } ?? "pass") ← \(chain.joined(separator: " > "))")
        }
        return result
    }

    private static func walk(from start: AXUIElement, chain: inout [String]) -> ScrollAxes? {
        var current: AXUIElement? = start
        var sawList = false
        let both = ScrollAxes(horizontal: true, vertical: true)
        for _ in 0..<25 {
            guard let el = current else { break }
            let role = string(el, kAXRoleAttribute) ?? ""
            let subrole = string(el, kAXSubroleAttribute) ?? ""
            chain.append(subrole.isEmpty ? role : "\(role)/\(subrole)")
            switch role {
            case "AXLink", kAXTabGroupRole:
                return nil
            case "AXWebArea":
                // Web pages: inner scrollable boxes don't show up as scroll areas, so allow both.
                return both
            case kAXScrollAreaRole:
                let v = has(el, kAXVerticalScrollBarAttribute)
                let h = has(el, kAXHorizontalScrollBarAttribute)
                if !v && !h { return both } // can't tell
                return ScrollAxes(horizontal: h, vertical: v)
            case kAXWindowRole, kAXApplicationRole:
                return sawList ? both : nil
            case kAXMenuBarRole, kAXMenuRole, kAXMenuItemRole, "AXDockItem":
                return nil
            default:
                if listRoles.contains(role) { sawList = true }
            }
            if subrole == "AXTabButton" { return nil }
            current = parent(el)
        }
        return sawList ? both : nil
    }

    /// Chromium and Electron apps only build their AX tree when asked. Returns true if we just asked.
    private static func prepare(pid: pid_t) -> Bool {
        guard pid > 0, !prepared.contains(pid) else { return false }
        prepared.insert(pid)
        guard let app = NSRunningApplication(processIdentifier: pid),
              let attribute = accessibilitySwitch(for: app) else { return false }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElement, attribute as CFString, kCFBooleanTrue)
        NSLog("Scrollmate: set \(attribute) on \(app.bundleIdentifier ?? "pid \(pid)")")
        return true
    }

    private static let chromiumBundleIDs: Set<String> = [
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium",
    ]

    private static func accessibilitySwitch(for app: NSRunningApplication) -> String? {
        guard let url = app.bundleURL else { return nil }
        let frameworks = (try? FileManager.default.contentsOfDirectory(
            atPath: url.appendingPathComponent("Contents/Frameworks").path)) ?? []
        if frameworks.contains("Electron Framework.framework") { return "AXManualAccessibility" }
        let chromium = frameworks.contains { name in
            name.hasSuffix("Framework.framework") &&
                ["Chrome", "Chromium", "Edge", "Brave", "Vivaldi", "Opera"].contains { name.contains($0) }
        }
        if chromium || chromiumBundleIDs.contains(app.bundleIdentifier ?? "") { return "AXEnhancedUserInterface" }
        return nil
    }

    private static func string(_ el: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func has(_ el: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success && value != nil
    }

    private static func parent(_ el: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
}

// MARK: - The round marker

/// Click-through round icon at the anchor, like the one Windows shows.
final class AutoscrollMarker {
    private static let size: CGFloat = 32
    private var panel: NSPanel?
    private let view = MarkerView(frame: NSRect(x: 0, y: 0, width: AutoscrollMarker.size, height: AutoscrollMarker.size))

    func show(at anchor: CGPoint, axes: ScrollAxes) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        view.axes = axes
        view.needsDisplay = true
        // CG coordinates have their origin at the top-left of the main display; Cocoa's at the bottom-left.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let s = AutoscrollMarker.size
        panel.setFrame(NSRect(x: anchor.x - s / 2, y: mainHeight - anchor.y - s / 2, width: s, height: s),
                       display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let s = AutoscrollMarker.size
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: s, height: s),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.contentView = view
        return p
    }
}

private final class MarkerView: NSView {
    var axes = ScrollAxes(horizontal: true, vertical: true)

    override func draw(_ dirtyRect: NSRect) {
        // Fixed light fill + dark outline, as on Windows: readable on light and dark backgrounds.
        let ring = bounds.insetBy(dx: 2, dy: 2)
        let circle = NSBezierPath(ovalIn: ring)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor(white: 0.98, alpha: 0.95).setFill()
        circle.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 0.15, alpha: 0.9).setStroke()
        circle.lineWidth = 1.25
        circle.stroke()

        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        NSColor(white: 0.15, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)).fill()

        // Small triangles pointing the ways this area can scroll.
        let tip: CGFloat = 11, base: CGFloat = 6, half: CGFloat = 3.5
        func triangle(_ dx: CGFloat, _ dy: CGFloat) {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: c.x + dx * tip, y: c.y + dy * tip))
            p.line(to: NSPoint(x: c.x + dx * base - dy * half, y: c.y + dy * base - dx * half))
            p.line(to: NSPoint(x: c.x + dx * base + dy * half, y: c.y + dy * base + dx * half))
            p.close()
            p.fill()
        }
        if axes.vertical { triangle(0, 1); triangle(0, -1) }
        if axes.horizontal { triangle(1, 0); triangle(-1, 0) }
    }
}
