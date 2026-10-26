import AppKit
import CoreGraphics
import CoreVideo

/// Everything that sets how smooth scrolling feels, in one place.
enum SmoothTuning {
    /// Pixels per line of wheel scrolling. Browsers scroll 40 px per line, so there a notch covers the
    /// same ground as before; native lists (Finder…) use their row height and move a bit further.
    static let pixelsPerLine: Double = 40
    /// How quickly a glide settles (s): about 95% of the distance is covered after 3× this.
    static let settleTime: Double = 0.08
}

/// Turns each wheel notch into a short eased glide of the same distance.
/// `add` is called on the main thread (from the event tap); frames are posted from a display link,
/// in step with the screen's refresh, so the shared state sits behind a lock.
final class SmoothScroller {
    static let shared = SmoothScroller()

    private let lock = NSLock()
    /// Distance still to scroll (px, CG convention: positive = toward the top / left).
    private var pendingX = 0.0, pendingY = 0.0
    /// Fractions of a pixel not yet sent in the whole-pixel fields.
    private var carryX = 0.0, carryY = 0.0
    private var flags: CGEventFlags = []
    private var lastFrame: TimeInterval = 0

    private var link: CVDisplayLink?

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
        let pending = (pendingX, pendingY)
        lock.unlock()
        DebugLog.write("smooth: +\(x),\(y) px → pending \(pending.0),\(pending.1)")
        startLink()
    }

    func stop() {
        lock.lock()
        pendingX = 0; pendingY = 0
        carryX = 0; carryY = 0
        lock.unlock()
        if let link = link { CVDisplayLinkStop(link) }
    }

    // MARK: - Display link

    private func startLink() {
        if link == nil {
            var newLink: CVDisplayLink?
            CVDisplayLinkCreateWithActiveCGDisplays(&newLink)
            guard let created = newLink else { return }
            CVDisplayLinkSetOutputCallback(created, { _, _, _, _, _, context in
                Unmanaged<SmoothScroller>.fromOpaque(context!).takeUnretainedValue().frame()
                return kCVReturnSuccess
            }, Unmanaged.passUnretained(self).toOpaque())
            link = created
        }
        guard let link = link, !CVDisplayLinkIsRunning(link) else { return }
        // Follow the refresh of the screen the pointer is on (60 Hz, 120 Hz ProMotion…).
        var display = CGMainDisplayID(), count: UInt32 = 0
        let pointer = CGEvent(source: nil)?.location ?? .zero
        CGGetDisplaysWithPoint(pointer, 1, &display, &count)
        CVDisplayLinkSetCurrentCGDisplay(link, display)
        lock.lock()
        lastFrame = ProcessInfo.processInfo.systemUptime - 1.0 / 120
        lock.unlock()
        CVDisplayLinkStart(link)
    }

    /// One screen refresh: move a fixed fraction of what's left (an ease-out curve).
    private func frame() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let dt = min(now - lastFrame, 0.05)
        lastFrame = now
        let fraction = 1 - exp(-dt / SmoothTuning.settleTime)
        var stepX = pendingX * fraction, stepY = pendingY * fraction
        if abs(pendingX - stepX) < 0.2 { stepX = pendingX }   // finish instead of creeping forever
        if abs(pendingY - stepY) < 0.2 { stepY = pendingY }
        pendingX -= stepX
        pendingY -= stepY
        carryX += stepX
        carryY += stepY
        let wholeX = carryX.rounded(.towardZero), wholeY = carryY.rounded(.towardZero)
        carryX -= wholeX
        carryY -= wholeY
        let idle = pendingX == 0 && pendingY == 0
        if idle { carryX = 0; carryY = 0 }
        let flags = self.flags
        lock.unlock()

        if stepX != 0 || stepY != 0,
           let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                           wheel1: Int32(wholeY), wheel2: Int32(wholeX), wheel3: 0) {
            // Whole pixels for apps that read those; the exact sub-pixel step (in macOS's
            // 10-px "lines") for apps that read the fine value, so slow ends of a glide stay smooth.
            e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: stepY / 10)
            e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: stepX / 10)
            // Location stays at the pointer: a posted event's location moves the cursor there.
            e.flags = flags
            e.tagAsOurs()
            e.post(tap: .cgSessionEventTap)
        }

        if idle {
            DispatchQueue.main.async { [weak self] in self?.stopIfIdle() }
        }
    }

    private func stopIfIdle() {
        lock.lock()
        let idle = pendingX == 0 && pendingY == 0
        lock.unlock()
        if idle, let link = link { CVDisplayLinkStop(link) }
    }
}
