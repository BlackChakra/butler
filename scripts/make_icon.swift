import AppKit

// Draws the app icon: a dark squircle with a thin storage ring, mostly full, with a green arc for what can go.
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let rect = NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(white: 0.17, alpha: 1), NSColor(white: 0.04, alpha: 1)])!.draw(in: squircle, angle: -90)
    NSColor(white: 1, alpha: 0.08).setStroke(); squircle.lineWidth = s * 0.004; squircle.stroke()

    let c = NSPoint(x: s / 2, y: s / 2), r = s * 0.25, w = s * 0.062
    func arc(_ from: CGFloat, _ to: CGFloat, _ color: NSColor) {
        let p = NSBezierPath()
        p.appendArc(withCenter: c, radius: r, startAngle: from, endAngle: to, clockwise: true)
        p.lineWidth = w; p.lineCapStyle = .round; color.setStroke(); p.stroke()
    }
    arc(90, -270, NSColor(white: 1, alpha: 0.14))                       // track
    arc(90, -140, NSColor(white: 1, alpha: 0.88))                       // used
    arc(-150, -232, NSColor(red: 0.20, green: 0.84, blue: 0.58, alpha: 1))  // reclaimable
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
// (points, scale) pairs required by an .iconset
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(pt)x\(pt)" + (scale == 2 ? "@2x" : "") + ".png"
    try! render(pt * scale).write(to: URL(fileURLWithPath: out + "/" + name))
}
