import AppKit
import CoreGraphics
import CoreVideo

/// Everything that sets how smooth scrolling feels, in one place.
enum SmoothTuning {
    /// Pixels per line of wheel scrolling. Browsers scroll 40 px per line, so there a notch covers the
    /// same ground as before; native lists (Finder…) use their row height and move a bit further.
    static let pixelsPerLine: Double = 40

    // While tuning, these can be changed without rebuilding:
    //   defaults write local.scrollmate <key> <value>   then restart Scrollmate.
    private static let d = UserDefaults.standard
    /// How quickly a glide settles (s): about 95% of the distance is covered after 3× this.  Key: smoothSettle
    static let settleTime: Double = d.object(forKey: "smoothSettle") as? Double ?? 0.08
    /// What paces the frames.  Key: smoothClock = "main" (timer on the main thread),
    /// "thread" (timer on its own thread) or "display" (the screen's refresh).
    static let clock: String = d.string(forKey: "smoothClock") ?? "thread"
    /// Frames per second for the "main" and "thread" clocks.  Key: smoothRate
    static let rate: Double = d.object(forKey: "smoothRate") as? Double ?? 120
    /// Also send the exact sub-pixel step, not only whole pixels.  Key: smoothFraction
    static let fraction: Bool = d.object(forKey: "smoothFraction") as? Bool ?? false
    /// Mark each glide as a gesture (began / changed / ended), like trackpad scrolling.  Key: smoothPhases
    static let phases: Bool = d.object(forKey: "smoothPhases") as? Bool ?? false
}

/// Turns each wheel notch into a short eased glide of the same distance.
/// `add` is called on the main thread (from the event tap); frames may come from another thread,
/// so the shared state sits behind a lock.
final class SmoothScroller {
    static let shared = SmoothScroller()

    private let lock = NSLock()
    /// Distance still to scroll (px, CG convention: positive = toward the top / left).
    private var pendingX = 0.0, pendingY = 0.0
    /// Fractions of a pixel not yet sent in the whole-pixel fields.
    private var carryX = 0.0, carryY = 0.0
    private var flags: CGEventFlags = []
    private var lastFrame: TimeInterval = 0
    /// A glide is under way (for the gesture phases).
    private var gliding = false
    private var running = false

    private var link: CVDisplayLink?
    private var mainTimer: Timer?
    private var threadTimer: DispatchSourceTimer?
    private let frameQueue = DispatchQueue(label: "local.scrollmate.smooth", qos: .userInteractive)

    private init() {
        DebugLog.write("smooth settings: clock \(SmoothTuning.clock) rate \(SmoothTuning.rate) settle \(SmoothTuning.settleTime) fraction \(SmoothTuning.fraction) phases \(SmoothTuning.phases)")
    }

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
        let start = !running
        if start {
            running = true
            lastFrame = ProcessInfo.processInfo.systemUptime - 1.0 / SmoothTuning.rate
        }
        lock.unlock()
        DebugLog.write("smooth: +\(x),\(y) px → pending \(pending.0),\(pending.1)")
        if start { startClock() }
    }

    // MARK: - Clocks

    private func startClock() {
        switch SmoothTuning.clock {
        case "display":
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
            guard let link = link else { return }
            var display = CGMainDisplayID(), count: UInt32 = 0
            CGGetDisplaysWithPoint(CGEvent(source: nil)?.location ?? .zero, 1, &display, &count)
            CVDisplayLinkSetCurrentCGDisplay(link, display)
            CVDisplayLinkStart(link)
        case "main":
            let t = Timer(timeInterval: 1 / SmoothTuning.rate, repeats: true) { [weak self] _ in self?.frame() }
            RunLoop.main.add(t, forMode: .common)
            mainTimer = t
            frame()
        default: // "thread"
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: frameQueue)
            t.schedule(deadline: .now(), repeating: 1 / SmoothTuning.rate, leeway: .microseconds(500))
            t.setEventHandler { [weak self] in self?.frame() }
            t.resume()
            threadTimer = t
        }
    }

    private func stopClock() {
        if let link = link { CVDisplayLinkStop(link) }
        mainTimer?.invalidate()
        mainTimer = nil
        threadTimer?.cancel()
        threadTimer = nil
    }

    // MARK: - Frames

    /// One frame: move a fixed fraction of what's left (an ease-out curve).
    private func frame() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let dt = min(now - lastFrame, 0.05)
        lastFrame = now
        let fraction = 1 - exp(-dt / SmoothTuning.settleTime)
        var stepX = pendingX * fraction, stepY = pendingY * fraction
        let finishBelow = SmoothTuning.fraction ? 0.2 : 0.5
        if abs(pendingX - stepX) < finishBelow { stepX = pendingX }   // finish instead of creeping forever
        if abs(pendingY - stepY) < finishBelow { stepY = pendingY }
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
        let began = !gliding
        gliding = !idle
        if idle { running = false }
        lock.unlock()

        let moves = SmoothTuning.fraction ? (stepX != 0 || stepY != 0) : (wholeX != 0 || wholeY != 0)
        if moves {
            post(wholeX: wholeX, wholeY: wholeY, stepX: stepX, stepY: stepY, flags: flags,
                 phase: began ? 1 : 2)  // kCGScrollPhaseBegan / Changed
        }
        if idle {
            if SmoothTuning.phases { post(wholeX: 0, wholeY: 0, stepX: 0, stepY: 0, flags: flags, phase: 4) } // Ended
            if Thread.isMainThread { stopClock() } else { DispatchQueue.main.async { self.stopIfIdle() } }
        }
    }

    private func stopIfIdle() {
        lock.lock()
        let idle = !running
        lock.unlock()
        if idle { stopClock() }
    }

    private func post(wholeX: Double, wholeY: Double, stepX: Double, stepY: Double, flags: CGEventFlags, phase: Int64) {
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                              wheel1: Int32(wholeY), wheel2: Int32(wholeX), wheel3: 0) else { return }
        if SmoothTuning.fraction {
            // The fine value is in macOS's 10-px "lines".
            e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: stepY / 10)
            e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: stepX / 10)
        }
        if SmoothTuning.phases, let field = CGEventField(rawValue: 99) { // kCGScrollWheelEventScrollPhase
            e.setIntegerValueField(field, value: phase)
        }
        // Location stays at the pointer: a posted event's location moves the cursor there.
        e.flags = flags
        e.tagAsOurs()
        e.post(tap: .cgSessionEventTap)
    }
}
