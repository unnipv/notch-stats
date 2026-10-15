// Generates the NotchStats app icon into an .iconset directory.
// Usage: swift scripts/make-icon.swift <output-iconset-dir>

import AppKit
import Foundation

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./icon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func drawRing(_ ctx: CGContext, center: CGPoint, radius: CGFloat, color: CGColor, progress: CGFloat) {
    let lineWidth = max(1, radius * 0.44)
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)

    ctx.setStrokeColor(color.copy(alpha: 0.22) ?? color)
    ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    ctx.setStrokeColor(color)
    ctx.addArc(center: center, radius: radius,
               startAngle: -.pi / 2, endAngle: -.pi / 2 + .pi * 2 * progress, clockwise: false)
    ctx.strokePath()
}

func draw(in ctx: CGContext, size: CGFloat) {
    let inset = size * 0.055
    let bg = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = bg.width * 0.232

    // Rounded-square body with a soft vertical charcoal gradient.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: bg, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [color(0.11, 0.12, 0.15), color(0.02, 0.02, 0.03)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: bg.maxY),
                           end: CGPoint(x: 0, y: bg.minY),
                           options: [])
    ctx.restoreGState()

    // Subtle inner hairline.
    ctx.setStrokeColor(color(1, 1, 1, 0.10))
    ctx.setLineWidth(max(1, size * 0.006))
    ctx.addPath(CGPath(roundedRect: bg, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.strokePath()

    // The island pill.
    let pillWidth = bg.width * 0.70
    let pillHeight = bg.height * 0.235
    let pill = CGRect(x: bg.midX - pillWidth / 2,
                      y: bg.midY - pillHeight / 2,
                      width: pillWidth,
                      height: pillHeight)
    let pillRadius = pillHeight * 0.34
    ctx.setFillColor(color(0, 0, 0))
    ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pillRadius, cornerHeight: pillRadius, transform: nil))
    ctx.fillPath()

    // Two usage rings, echoing the widget.
    let ringRadius = pillHeight * 0.30
    drawRing(ctx,
             center: CGPoint(x: pill.minX + pillHeight * 0.66, y: pill.midY),
             radius: ringRadius, color: color(0.06, 0.64, 0.50), progress: 0.88)
    drawRing(ctx,
             center: CGPoint(x: pill.maxX - pillHeight * 0.66, y: pill.midY),
             radius: ringRadius, color: color(0.71, 0.48, 1.0), progress: 0.55)
}

func renderPNG(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    if let ctx = NSGraphicsContext.current?.cgContext {
        draw(in: ctx, size: CGFloat(pixels))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for variant in variants {
    guard let data = renderPNG(pixels: variant.pixels) else { continue }
    try? data.write(to: URL(fileURLWithPath: "\(outDir)/\(variant.name)"))
}

print("Wrote \(variants.count) icon files to \(outDir)")
