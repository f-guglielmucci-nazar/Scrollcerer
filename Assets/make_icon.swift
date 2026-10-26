// Draws the Scrollmate logo and builds the app icon.
// Usage:  bash Assets/make_icon.sh   (or: xcrun swift Assets/make_icon.swift [mouse|marker] [output folder])
// Writes logo.png (1024 px) and AppIcon.icns into the output folder.
import AppKit

let args = CommandLine.arguments
let concept = args.count > 1 ? args[1] : "mouse"
let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "Assets")

// Brand colours.
let gradientTop = NSColor(srgbRed: 0.39, green: 0.40, blue: 0.95, alpha: 1)    // indigo
let gradientBottom = NSColor(srgbRed: 0.02, green: 0.71, blue: 0.83, alpha: 1) // cyan
let ink = NSColor(srgbRed: 0.12, green: 0.16, blue: 0.27, alpha: 1)            // dark outline

/// The autoscroll marker: white disc, dark ring, centre dot, arrows.
func drawMarker(center c: NSPoint, radius r: CGFloat, fourWay: Bool) {
    let disc = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    NSColor.white.setFill()
    disc.fill()
    ink.setStroke()
    disc.lineWidth = r * 0.075
    disc.stroke()

    ink.setFill()
    let dot = r * 0.13
    NSBezierPath(ovalIn: NSRect(x: c.x - dot, y: c.y - dot, width: 2 * dot, height: 2 * dot)).fill()

    let tip = r * 0.72, base = r * 0.36, half = r * 0.24
    func arrow(_ dx: CGFloat, _ dy: CGFloat) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: c.x + dx * tip, y: c.y + dy * tip))
        p.line(to: NSPoint(x: c.x + dx * base - dy * half, y: c.y + dy * base - dx * half))
        p.line(to: NSPoint(x: c.x + dx * base + dy * half, y: c.y + dy * base + dx * half))
        p.close()
        p.fill()
    }
    arrow(0, 1); arrow(0, -1)
    if fourWay { arrow(1, 0); arrow(-1, 0) }
}

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)   // draw on a 1024 grid

    // macOS icon shape: 824 px rounded square inside the 1024 canvas, with a soft shadow.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    gradientTop.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: gradientTop, ending: gradientBottom)!.draw(in: tile, angle: -90)

    switch concept {
    case "marker":
        drawMarker(center: NSPoint(x: 512, y: 512), radius: 290, fourWay: true)

    default: // "mouse": a mouse whose wheel is the autoscroll marker
        let body = NSBezierPath(roundedRect: NSRect(x: 322, y: 196, width: 380, height: 600), xRadius: 190, yRadius: 190)
        NSGraphicsContext.saveGraphicsState()
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.25)
        s.shadowBlurRadius = 30
        s.shadowOffset = NSSize(width: 0, height: -14)
        s.set()
        NSColor.white.setFill()
        body.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Split between the two buttons, and the line under them (kept inside the body).
        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        let split = NSBezierPath()
        split.move(to: NSPoint(x: 512, y: 820))
        split.line(to: NSPoint(x: 512, y: 470))
        split.move(to: NSPoint(x: 300, y: 470))
        split.curve(to: NSPoint(x: 724, y: 470), controlPoint1: NSPoint(x: 400, y: 440), controlPoint2: NSPoint(x: 624, y: 440))
        split.lineWidth = 12
        split.lineCapStyle = .round
        gradientBottom.withAlphaComponent(0.55).setStroke()
        split.stroke()
        NSGraphicsContext.restoreGraphicsState()

        drawMarker(center: NSPoint(x: 512, y: 640), radius: 100, fourWay: false)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(_ rep: NSBitmapImageRep, to url: URL) {
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
save(drawIcon(size: 1024), to: outDir.appendingPathComponent("logo.png"))

// Every size macOS wants in an .icns.
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    save(drawIcon(size: CGFloat(base)), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    save(drawIcon(size: CGFloat(base * 2)), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
