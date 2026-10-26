import AppKit
import CoreGraphics

/// Watches mouse button and scroll events system-wide and rewrites them.
final class Remapper {
    static let shared = Remapper()

    /// Called on every extra-button press (button numbers: 2 = wheel, 3/4 = side buttons).
    var onButton: ((Int) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    /// Starts the event tap. Fails until Accessibility permission is granted.
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }

        let mask: CGEventMask =
            (CGEventMask(1) << CGEventType.otherMouseDown.rawValue) |
            (CGEventMask(1) << CGEventType.otherMouseUp.rawValue) |
            (CGEventMask(1) << CGEventType.otherMouseDragged.rawValue) |
            (CGEventMask(1) << CGEventType.scrollWheel.rawValue)

        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                             place: .headInsertEventTap,
                                             options: .defaultTap,
                                             eventsOfInterest: mask,
                                             callback: remapperTapCallback,
                                             userInfo: nil) else {
            return false
        }
        let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        tap = newTap
        source = newSource
        return true
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        // Our own synthetic events (autoscroll, replayed middle clicks) go through untouched.
        if event.isOurs { return pass }

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switches taps off if they're ever slow; switch it straight back on.
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass

        case .scrollWheel:
            let config = Config.shared
            // Continuous = trackpad / Magic Mouse. Only touch a regular notched wheel.
            let isMouseWheel = event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0

            // A real scroll or tilt ends autoscroll and goes through as it is.
            if Autoscroller.shared.isScrolling {
                Autoscroller.shared.realScroll()
                let now = ProcessInfo.processInfo.systemUptime
                lastTiltTime[Config.tiltLeft] = now   // a held tilt shouldn't then fire its action
                lastTiltTime[Config.tiltRight] = now
                return pass
            }

            // Wheel tilt: a sideways-only scroll from the mouse wheel (Shift+scroll is left alone).
            if isMouseWheel, !event.flags.contains(.maskShift) {
                let horizontal = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
                let vertical = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
                if horizontal != 0 && vertical == 0 {
                    return handleTilt(horizontal > 0 ? Config.tiltRight : Config.tiltLeft, event: event)
                }
            }

            guard config.enabled, isMouseWheel else { return pass }
            DebugLog.write("scroll in:  \(Remapper.describe(event))")

            // Ctrl (or ⌘) + wheel zooms, as on Windows.
            let zoomModifier: CGEventFlags = config.zoomWithCommand ? .maskCommand : .maskControl
            if config.wheelZoom,
               event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]) == zoomModifier {
                let amount = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
                if amount != 0 {
                    // Natural scrolling has already flipped the delta; undo that to get the physical direction.
                    let inverted = NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice ?? false
                    let awayFromUser = (amount > 0) != inverted
                    DispatchQueue.main.async { Actions.zoom(in: awayFromUser) }
                    return nil
                }
            }

            // Lines per notch: with acceleration off every notch scrolls exactly that many lines;
            // with it on, the accelerated amount is multiplied instead.
            let lines = Double(config.wheelLines)
            let shape: (Double) -> Double
            if config.linearWheel {
                let perNotch = lines > 0 ? lines : 1
                shape = { $0 < 0 ? -perNotch : perNotch }
            } else if lines > 0 {
                shape = { $0 * lines }
            } else {
                shape = { $0 }
            }
            let flip: Double = config.reverseWheel ? -1 : 1
            Remapper.rewrite(event, Remapper.vertical) { flip * shape($0) }
            Remapper.rewrite(event, Remapper.horizontal, shape)

            DebugLog.write("scroll out: \(Remapper.describe(event))")

            // Smooth scrolling: swallow the jump and glide the same distance instead.
            if config.smoothScroll {
                let lines = (x: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
                             y: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
                if lines.x != 0 || lines.y != 0 {
                    SmoothScroller.shared.add(linesX: lines.x, linesY: lines.y, flags: event.flags)
                    return nil
                }
            }
            return pass

        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            if type == .otherMouseDown {
                DispatchQueue.main.async { self.onButton?(button) }
            }

            switch Autoscroller.shared.intercept(type: type, event: event, button: button) {
            case .swallow: return nil
            case .pass: return pass
            case .notMine: break
            }

            let config = Config.shared
            guard config.enabled else { return pass }
            let action = config.action(for: button)

            switch action.kind {
            case .passthrough:
                return pass
            case .autoscroll:
                if type == .otherMouseDown { Autoscroller.shared.begin(button: button, event: event) }
                return nil // the down/drag/up are held back until we know whether it's a click
            case .middleClick:
                // Re-label the event as a middle-button event; drags keep working.
                event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
                return pass
            case .disabled:
                return nil
            default:
                if type == .otherMouseDown {
                    DispatchQueue.main.async { Actions.perform(action) }
                }
                return nil // swallow the original button press, release and drag
            }

        default:
            return pass
        }
    }

    // MARK: - Wheel deltas

    private struct Axis {
        let lines: CGEventField   // integer lines
        let points: CGEventField  // pixels
        let fixed: CGEventField   // fractional lines (what most apps read)
    }
    private static let vertical = Axis(lines: .scrollWheelEventDeltaAxis1,
                                       points: .scrollWheelEventPointDeltaAxis1,
                                       fixed: .scrollWheelEventFixedPtDeltaAxis1)
    private static let horizontal = Axis(lines: .scrollWheelEventDeltaAxis2,
                                         points: .scrollWheelEventPointDeltaAxis2,
                                         fixed: .scrollWheelEventFixedPtDeltaAxis2)

    /// Makes one axis of a wheel event scroll `transform(lines)` lines, scaling all three delta fields
    /// together so macOS's pixels-per-line stays as it was. Everything is read before anything is
    /// written, because writing the line delta makes CoreGraphics recompute the other two.
    private static func rewrite(_ event: CGEvent, _ axis: Axis, _ transform: (Double) -> Double) {
        let lines = event.getIntegerValueField(axis.lines)
        let points = event.getIntegerValueField(axis.points)
        let fixed = event.getDoubleValueField(axis.fixed)
        let amount = fixed != 0 ? fixed : Double(lines)
        guard amount != 0 else { return }
        let target = transform(amount)
        guard target != amount else { return }
        let scale = target / amount

        var newLines = (Double(lines) * scale).rounded()
        if newLines == 0 { newLines = target < 0 ? -1 : 1 } // a notch always moves at least a line
        event.setIntegerValueField(axis.lines, value: Int64(newLines))
        event.setIntegerValueField(axis.points, value: Int64((Double(points) * scale).rounded()))
        event.setDoubleValueField(axis.fixed, value: fixed != 0 ? fixed * scale : target)
    }

    private static func describe(_ e: CGEvent) -> String {
        "lines \(e.getIntegerValueField(.scrollWheelEventDeltaAxis1))/\(e.getIntegerValueField(.scrollWheelEventDeltaAxis2)) " +
            "points \(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))/\(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)) " +
            "fixed \(e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))/\(e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))"
    }

    /// When was the last scroll event seen for each tilt direction.
    private var lastTiltTime: [Int: TimeInterval] = [:]

    /// Holding the wheel tilted sends a stream of sideways scrolls; treat a stream
    /// as one "press" so the action fires once per tilt.
    private func handleTilt(_ tilt: Int, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let now = ProcessInfo.processInfo.systemUptime
        let isNewPress = now - (lastTiltTime[tilt] ?? 0) > 0.35
        lastTiltTime[tilt] = now

        if isNewPress {
            DispatchQueue.main.async { self.onButton?(tilt) }
        }

        let config = Config.shared
        guard config.enabled else { return pass }
        let action = config.action(for: tilt)

        switch action.kind {
        case .passthrough, .autoscroll: // a tilt has no press/release, so autoscroll doesn't apply
            return pass
        case .disabled:
            return nil
        case .middleClick:
            if isNewPress { DispatchQueue.main.async { Actions.middleClick() } }
            return nil
        default:
            if isNewPress { DispatchQueue.main.async { Actions.perform(action) } }
            return nil
        }
    }
}

/// C callback for the event tap.
private func remapperTapCallback(proxy: CGEventTapProxy,
                                 type: CGEventType,
                                 event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    return Remapper.shared.handle(type: type, event: event)
}
