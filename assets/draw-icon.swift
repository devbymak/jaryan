// Draws assets/app-icon.png: an upload and a download arrow on a midnight tile, in the graph's colours.
// Run once with `xcrun swift assets/draw-icon.swift assets/app-icon.png`; build.sh uses the PNG.
import AppKit

let side = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}
// macOS icon grid: an 824 pt tile centred on the 1024 pt canvas.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowColor = rgb(0x000000, 0.35); shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
rgb(0x0f1a3a).setFill(); shape.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(colors: [rgb(0x24357a), rgb(0x0e1838)])!.draw(in: shape, angle: -90)
NSGradient(colors: [rgb(0xffffff, 0.10), rgb(0xffffff, 0)])!.draw(in: NSBezierPath(roundedRect: tile.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183), angle: -90)

/// A bold arrow with a rounded shaft, pointing up or down, centred on `x`.
func arrow(x: CGFloat, up: Bool, colors: [NSColor]) {
    let width: CGFloat = 170, head: CGFloat = 270, headHeight: CGFloat = 220, top: CGFloat = 760, bottom: CGFloat = 264
    let path = NSBezierPath()
    let tip = up ? top : bottom, base = up ? top - headHeight : bottom + headHeight, tail = up ? bottom : top
    path.move(to: NSPoint(x: x, y: tip))
    path.line(to: NSPoint(x: x + head / 2, y: base))
    path.line(to: NSPoint(x: x + width / 2, y: base))
    path.line(to: NSPoint(x: x + width / 2, y: tail))
    path.line(to: NSPoint(x: x - width / 2, y: tail))
    path.line(to: NSPoint(x: x - width / 2, y: base))
    path.line(to: NSPoint(x: x - head / 2, y: base))
    path.close()
    path.lineJoinStyle = .round
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow(); glow.shadowColor = colors[0].withAlphaComponent(0.55); glow.shadowBlurRadius = 40
    glow.set()
    colors[0].setFill(); path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: colors)!.draw(in: path, angle: up ? 90 : -90)
    rgb(0xffffff, 0.35).setStroke(); path.lineWidth = 6; path.stroke()
}
arrow(x: 370, up: true, colors: [rgb(0xff7a3d), rgb(0xffc49a)])
arrow(x: 654, up: false, colors: [rgb(0x3d8ff0), rgb(0xa9d1ff)])

NSGraphicsContext.current = nil
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
