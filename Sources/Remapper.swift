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

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switches taps off if they're ever slow; switch it straight back on.
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass

        case .scrollWheel:
            let config = Config.shared
            // Continuous = trackpad / Magic Mouse. Only touch a regular notched wheel.
            let isMouseWheel = event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0

            // Wheel tilt: a sideways-only scroll from the mouse wheel (Shift+scroll is left alone).
            if isMouseWheel, !event.flags.contains(.maskShift) {
                let horizontal = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
                let vertical = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
                if horizontal != 0 && vertical == 0 {
                    return handleTilt(horizontal > 0 ? Config.tiltRight : Config.tiltLeft, event: event)
                }
            }

            if config.enabled, config.reverseWheel, isMouseWheel {
                event.setIntegerValueField(.scrollWheelEventDeltaAxis1,
                                           value: -event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
                event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1,
                                           value: -event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
                event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1,
                                          value: -event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
            }
            return pass

        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            if type == .otherMouseDown {
                DispatchQueue.main.async { self.onButton?(button) }
            }

            let config = Config.shared
            guard config.enabled else { return pass }
            let action = config.action(for: button)

            switch action.kind {
            case .passthrough:
                return pass
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
        case .passthrough:
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
