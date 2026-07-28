#!/usr/bin/env swift
// Draws the app icon procedurally and writes an .iconset, so the repo carries no binary
// assets. Run via build.sh; output is handed to iconutil.
//
// The geometry is measured from the platform rather than invented. Sampling the system
// icons on macOS 26 gives 824x824 of artwork centred in a 1024x1024 canvas — a 100px
// inset on every side, which is where the system draws the icon's shadow. A full-bleed
// square sits visibly proud of everything else in the Dock.
//
// The silhouette is a superellipse, not a circular-corner rounded rectangle: Apple's
// shape is a continuous curve, and NSBezierPath(roundedRect:) produces a visible
// straight-to-arc transition that reads as subtly wrong beside real icons. The exponent
// was solved against the same measurement — n = 7 reproduces the system corner profile
// (23.8% of the plate width, against 23.7% measured on Music, Calculator and App Store).

import AppKit

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./deck.iconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

// From the "dark" palette, the app's default theme.
let plate = NSColor(srgbRed: 0.106, green: 0.106, blue: 0.114, alpha: 1)   // #1b1b1d
let accent = NSColor(srgbRed: 0.541, green: 0.706, blue: 0.973, alpha: 1)  // #8ab4f8

/// Fraction of the canvas the plate occupies, matching the measured system grid.
let artFraction: CGFloat = 824.0 / 1024.0

/// Superellipse |x/a|^n + |y/b|^n = 1.
func squircle(in rect: NSRect, n: CGFloat = 7) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let exponent = 2 / n
    let steps = 1440

    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        // Signed power keeps each point in its own quadrant.
        let x = cx + a * (ct < 0 ? -1 : 1) * pow(abs(ct), exponent)
        let y = cy + b * (st < 0 ? -1 : 1) * pow(abs(st), exponent)
        if i == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

/// Renders at an exact pixel size.
///
/// NSImage.lockFocus adopts the main display's backing scale, so on a Retina Mac every
/// bitmap came out at twice its nominal size and the whole iconset was shifted one step
/// — icon_16x16.png was really 32x32.
func drawIcon(size: Int) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(size)
    let art = s * artFraction
    let origin = (s - art) / 2
    let plateRect = NSRect(x: origin, y: origin, width: art, height: art)

    plate.setFill()
    squircle(in: plateRect).fill()

    // Three level bars. The spectrum is the app's signature, and it is the one element
    // that still reads at 16pt — anything more detailed turns to mud at that size.
    let heights: [CGFloat] = [0.45, 1.0, 0.68]
    let barWidth = art * 0.125
    let gap = art * 0.095
    let count = CGFloat(heights.count)
    let totalWidth = barWidth * count + gap * (count - 1)
    let startX = plateRect.midX - totalWidth / 2
    let tallest = art * 0.46
    let baseline = plateRect.midY - tallest / 2

    accent.setFill()
    for (i, fraction) in heights.enumerated() {
        let x = startX + CGFloat(i) * (barWidth + gap)
        NSBezierPath(rect: NSRect(
            x: x, y: baseline, width: barWidth, height: tallest * fraction)).fill()
    }

    return rep
}

// The sizes macOS expects in an iconset.
let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

for (size, name) in sizes {
    guard let rep = drawIcon(size: size),
          let png = rep.representation(using: .png, properties: [:])
    else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(outputDir)/\(name).png"))
}

print("wrote iconset to \(outputDir)")
