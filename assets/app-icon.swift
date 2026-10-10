// Draw the Jarian app icon: an upload and a download arrow on a navy tile.
// Regenerate assets/app-icon.png with: xcrun swift assets/app-icon.swift assets/app-icon.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0
func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, alpha: 1)
}

// A closed polygon whose corners are rounded with the given radii.
func roundedPolygon(_ points: [CGPoint], radii: [Double]) -> CGPath {
    let path = CGMutablePath()
    let count = points.count
    let start = CGPoint(x: (points[count - 1].x + points[0].x) / 2, y: (points[count - 1].y + points[0].y) / 2)
    path.move(to: start)
    for index in 0..<count {
        path.addArc(tangent1End: points[index], tangent2End: points[(index + 1) % count], radius: radii[index])
    }
    path.closeSubpath()
    return path
}

// An upward arrow centred on x, spanning top...bottom (y grows downwards).
func upArrow(x: Double, top: Double, bottom: Double) -> [CGPoint] {
    let head = 248.0, headHeight = 160.0, shaft = 124.0
    // Rounding the tip shaves about 14 pt off it, so the tip reaches past top to look level with the flat end.
    return [
        CGPoint(x: x, y: top - 14),
        CGPoint(x: x + head / 2, y: top + headHeight),
        CGPoint(x: x + shaft / 2, y: top + headHeight),
        CGPoint(x: x + shaft / 2, y: bottom),
        CGPoint(x: x - shaft / 2, y: bottom),
        CGPoint(x: x - shaft / 2, y: top + headHeight),
        CGPoint(x: x - head / 2, y: top + headHeight)
    ]
}
let radii = [22.0, 16, 6, 26, 26, 6, 16]

let context = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Flip so y grows downwards, like the design coordinates.
context.translateBy(x: 0, y: size)
context.scaleBy(x: 1, y: -1)

// The macOS icon grid: an 824 pt tile centred on the 1024 pt canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
context.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
context.setFillColor(color(0x101B32))
context.fillPath()

let top = 512.0 - 236, bottom = 512.0 + 236
context.addPath(roundedPolygon(upArrow(x: 512 - 150, top: top, bottom: bottom), radii: radii))
context.setFillColor(color(0xF47B42))
context.fillPath()

// The download arrow is the upload arrow turned upside down.
let down = upArrow(x: 512 + 150, top: top, bottom: bottom).map { CGPoint(x: $0.x, y: top + bottom - $0.y) }
context.addPath(roundedPolygon(down, radii: radii))
context.setFillColor(color(0x3987E5))
context.fillPath()

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
CGImageDestinationFinalize(destination)
