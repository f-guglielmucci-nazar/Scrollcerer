import AppKit
import CoreGraphics

/// Everything that sets how smooth scrolling feels, in one place.
enum SmoothTuning {
    /// Pixels per line of wheel scrolling. Browsers scroll 40 px per line, so there a notch covers the
    /// same ground as before; native lists (Finder…) use their row height and move a bit further.
    static let pixelsPerLine: Double = 40
    /// How quickly a glide settles (s): about 95% of the distance is covered after 3× this.
    static let settleTime: Double = 0.07
    /// How often scroll events are posted while gliding (Hz).
    static let tickRate: Double = 120
}

/// Turns each wheel notch into a short eased glide of the same distance.
/// Runs on the main thread (called from the event tap).
final class SmoothScroller {
    static let shared = SmoothScroller()

    /// Distance still to scroll (px, CG convention: positive = toward the top / left).
    private var pendingX = 0.0, pendingY = 0.0
    /// Sub-pixel remainders not posted yet.
    private var carryX = 0.0, carryY = 0.0
    private var flags: CGEventFlags = []
    private var timer: Timer?
    private var lastTick: TimeInterval = 0

    /// Adds one wheel event's worth of scrolling, in lines.
    func add(linesX: Double, linesY: Double, flags: CGEventFlags) {
        let x = linesX * SmoothTuning.pixelsPerLine, y = linesY * SmoothTuning.pixelsPerLine
        // Turning the wheel the other way stops the current glide at once.
        if y != 0, pendingY != 0, (y > 0) != (pendingY > 0) { pendingY = 0; carryY = 0 }
        if x != 0, pendingX != 0, (x > 0) != (pendingX > 0) { pendingX = 0; carryX = 0 }
        pendingX += x
        pendingY += y
        self.flags = flags
        DebugLog.write("smooth: +\(x),\(y) px → pending \(pendingX),\(pendingY)")

        if timer == nil {
            lastTick = ProcessInfo.processInfo.systemUptime - 1 / SmoothTuning.tickRate
            let t = Timer(timeInterval: 1 / SmoothTuning.tickRate, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            tick() // start moving right away rather than one tick later
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pendingX = 0; pendingY = 0
        carryX = 0; carryY = 0
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(now - lastTick, 0.05)
        lastTick = now

        // Ease out: each tick covers a fixed fraction of what's left.
        let fraction = 1 - exp(-dt / SmoothTuning.settleTime)
        var stepX = pendingX * fraction, stepY = pendingY * fraction
        if abs(pendingX - stepX) < 0.5 { stepX = pendingX }   // finish instead of creeping forever
        if abs(pendingY - stepY) < 0.5 { stepY = pendingY }
        pendingX -= stepX
        pendingY -= stepY

        carryX += stepX
        carryY += stepY
        let outX = carryX.rounded(.towardZero), outY = carryY.rounded(.towardZero)
        carryX -= outX
        carryY -= outY

        if (outX != 0 || outY != 0),
           let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                           wheel1: Int32(outY), wheel2: Int32(outX), wheel3: 0) {
            // Location stays at the pointer: a posted event's location moves the cursor there.
            e.flags = flags
            e.tagAsOurs()
            e.post(tap: .cgSessionEventTap)
        }

        if pendingX == 0 && pendingY == 0 {
            timer?.invalidate()
            timer = nil
            carryX = 0
            carryY = 0
        }
    }
}
