import AppKit
import CoreGraphics

/// Everything that sets how smooth scrolling feels, in one place.
enum SmoothTuning {
    /// Pixels per line of wheel scrolling. Browsers scroll 40 px per line, so there a notch covers the
    /// same ground as before; native lists (Finder…) use their row height and move a bit further.
    static let pixelsPerLine: Double = 40
    /// How quickly a glide settles (s): about 95% of the distance is covered after 3× this.
    static let settleTime: Double = 0.08
    /// Steps per second. Well above the screen's refresh, so every redraw gets an even share.
    static let rate: Double = 240
}

/// Turns each wheel notch into a short eased glide of the same distance, sent as a
/// trackpad-style scroll gesture (began / changed / ended), which apps animate most smoothly.
/// `add` is called on the main thread (from the event tap); steps come from a timer on its own
/// thread, so the shared state sits behind a lock.
final class SmoothScroller {
    static let shared = SmoothScroller()

    private let lock = NSLock()
    /// Distance still to scroll (px, CG convention: positive = toward the top / left).
    private var pendingX = 0.0, pendingY = 0.0
    /// Fractions of a pixel not sent yet.
    private var carryX = 0.0, carryY = 0.0
    private var flags: CGEventFlags = []
    private var lastStep: TimeInterval = 0
    /// A gesture has begun and not ended yet.
    private var gliding = false
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "local.scrollmate.smooth", qos: .userInteractive)

    // kCGScrollWheelEventScrollPhase and its values.
    private static let phaseField = CGEventField(rawValue: 99)
    private static let began: Int64 = 1, changed: Int64 = 2, ended: Int64 = 4

    /// Adds one wheel event's worth of scrolling, in lines.
    func add(linesX: Double, linesY: Double, flags: CGEventFlags) {
        let x = linesX * SmoothTuning.pixelsPerLine, y = linesY * SmoothTuning.pixelsPerLine
        lock.lock()
        // Turning the wheel the other way stops the current glide at once.
        if y != 0, pendingY != 0, (y > 0) != (pendingY > 0) { pendingY = 0; carryY = 0 }
        if x != 0, pendingX != 0, (x > 0) != (pendingX > 0) { pendingX = 0; carryX = 0 }
        pendingX += x
        pendingY += y
        self.flags = flags
        let start = timer == nil
        if start {
            lastStep = ProcessInfo.processInfo.systemUptime - 1 / SmoothTuning.rate
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            t.schedule(deadline: .now(), repeating: 1 / SmoothTuning.rate, leeway: .microseconds(500))
            t.setEventHandler { [weak self] in self?.step() }
            timer = t
        }
        let started = timer
        lock.unlock()
        if start { started?.resume() }
    }

    /// One step: move a fixed fraction of what's left (an ease-out curve). Runs on `queue`.
    private func step() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let dt = min(now - lastStep, 0.05)
        lastStep = now
        let fraction = 1 - exp(-dt / SmoothTuning.settleTime)
        var stepX = pendingX * fraction, stepY = pendingY * fraction
        if abs(pendingX - stepX) < 0.5 { stepX = pendingX }   // finish instead of creeping forever
        if abs(pendingY - stepY) < 0.5 { stepY = pendingY }
        pendingX -= stepX
        pendingY -= stepY
        carryX += stepX
        carryY += stepY
        let wholeX = carryX.rounded(.towardZero), wholeY = carryY.rounded(.towardZero)
        carryX -= wholeX
        carryY -= wholeY
        let done = pendingX == 0 && pendingY == 0
        let moves = wholeX != 0 || wholeY != 0
        let phase = gliding ? SmoothScroller.changed : SmoothScroller.began
        let endGesture = done && (gliding || moves)
        gliding = moves ? !done : gliding && !done
        let flags = self.flags
        if done {
            carryX = 0
            carryY = 0
            timer?.cancel()
            timer = nil
        }
        lock.unlock()

        if moves {
            post(x: wholeX, y: wholeY, phase: phase, flags: flags)
        }
        if endGesture {
            post(x: 0, y: 0, phase: SmoothScroller.ended, flags: flags)
        }
    }

    private func post(x: Double, y: Double, phase: Int64, flags: CGEventFlags) {
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                              wheel1: Int32(y), wheel2: Int32(x), wheel3: 0) else { return }
        if let field = SmoothScroller.phaseField { e.setIntegerValueField(field, value: phase) }
        // Location stays at the pointer: a posted event's location moves the cursor there.
        e.flags = flags
        e.tagAsOurs()
        e.post(tap: .cgSessionEventTap)
    }
}
