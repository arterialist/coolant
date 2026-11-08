#!/usr/bin/env swift
// Draws the app icon and writes it as an .icns file.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns [preview.png]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func mix(_ a: [CGFloat], _ b: [CGFloat], _ t: CGFloat) -> [CGFloat] { zip(a, b).map { $0 + ($1 - $0) * t } }

func polar(_ radius: CGFloat, _ degrees: CGFloat) -> CGPoint {
    let a = degrees * .pi / 180
    return CGPoint(x: radius * cos(a), y: radius * sin(a))
}

func linear(_ top: CGColor, _ bottom: CGColor) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray, locations: [0, 1])!
}

/// Coordinates are a 1024 canvas with the origin at the centre once drawing starts.
func draw(in c: CGContext) {
    // Body on Apple's macOS icon grid: 824 square in a 1024 canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let outline = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
    c.addPath(outline)
    c.setFillColor(rgb(8, 34, 48))
    c.fillPath()
    c.restoreGState()

    c.saveGState()
    c.addPath(outline)
    c.clip()
    c.drawLinearGradient(linear(rgb(20, 72, 92), rgb(5, 22, 34)), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    c.restoreGState()

    c.translateBy(x: 512, y: 512)

    // Shroud ring, amber at the top right running round to ice blue.
    let warm: [CGFloat] = [255, 158, 64], cold: [CGFloat] = [96, 226, 245]
    let ringRadius: CGFloat = 318
    c.setLineWidth(34)
    c.setLineCap(.butt)
    let steps = 360
    for i in 0..<steps {
        let t = CGFloat(i) / CGFloat(steps - 1)
        let eased = t * t * (3 - 2 * t)
        let color = mix(warm, cold, eased)
        let start = (60 - CGFloat(i)) * .pi / 180
        c.setStrokeColor(rgb(color[0], color[1], color[2]))
        c.addArc(center: .zero, radius: ringRadius, startAngle: start, endAngle: start - 1.6 * .pi / 180, clockwise: true)
        c.strokePath()
    }

    // Five swept blades.
    let hub: CGFloat = 78, tip: CGFloat = 272
    for blade in 0..<5 {
        c.saveGState()
        c.rotate(by: CGFloat(blade) * 2 * .pi / 5 + 0.3)
        let path = CGMutablePath()
        path.move(to: polar(hub * 0.8, -26))
        path.addCurve(to: polar(tip, 8), control1: polar(hub * 2.1, -30), control2: polar(tip * 0.92, -22))
        path.addCurve(to: polar(tip * 0.86, 40), control1: polar(tip * 1.03, 22), control2: polar(tip * 0.97, 34))
        path.addCurve(to: polar(hub * 0.8, 36), control1: polar(tip * 0.62, 38), control2: polar(hub * 1.5, 12))
        path.closeSubpath()
        c.addPath(path)
        c.clip()
        c.drawLinearGradient(linear(rgb(255, 255, 255), rgb(120, 214, 236)), start: polar(tip, 15), end: polar(hub * 0.6, 15), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        c.restoreGState()
    }

    // Hub.
    c.setFillColor(rgb(9, 38, 52))
    c.fillEllipse(in: CGRect(x: -hub, y: -hub, width: hub * 2, height: hub * 2))
    c.setFillColor(rgb(150, 232, 247))
    let cap = hub * 0.42
    c.fillEllipse(in: CGRect(x: -cap, y: -cap, width: cap * 2, height: cap * 2))
}

func render(_ pixels: Int) -> CGImage {
    let c = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    draw(in: c)
    return c.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let out = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(out, image, nil)
    guard CGImageDestinationFinalize(out) else { fatalError("cannot write \(url.path)") }
}

let args = CommandLine.arguments
guard args.count >= 2 else { fatalError("usage: make-icon.swift <output.icns> [preview.png]") }
let set = FileManager.default.temporaryDirectory.appendingPathComponent("Coolant-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: set) }
for points in [16, 32, 128, 256, 512] {
    writePNG(render(points), to: set.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(render(points * 2), to: set.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", args[1], set.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
if args.count > 2 { writePNG(render(512), to: URL(fileURLWithPath: args[2])) }
