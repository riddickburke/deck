#!/usr/bin/env swift
// Draws the iOS app icon: a single full-bleed 1024x1024 PNG.
//
// Deliberately not a resize of the macOS iconset. The two platforms want opposite
// things from the source art:
//
//   macOS  — the app supplies the silhouette. Artwork is inset to 824/1024 and the
//            superellipse plate is drawn by us, because the surrounding 100px is where
//            the system paints the icon's shadow.
//   iOS    — the system supplies the silhouette. Artwork must be a full-bleed square
//            with square corners; iOS applies its own mask and shadow.
//
// Feeding the macOS art to iOS would inset an already-inset icon and then round off
// corners that were already round, leaving a small icon floating in a large empty
// square. So the plate here fills the canvas edge to edge and the glyph is scaled to
// the canvas rather than to an inner plate.

import AppKit

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "./AppIcon.png"

// The same two colours as the desktop icon, from the "dark" palette.
let plate = NSColor(srgbRed: 0.106, green: 0.106, blue: 0.114, alpha: 1)   // #1b1b1d
let accent = NSColor(srgbRed: 0.541, green: 0.706, blue: 0.973, alpha: 1)  // #8ab4f8

/// Renders at an exact pixel size, opaque.
///
/// As on macOS, the bitmap rep is created explicitly: NSImage.lockFocus would adopt the
/// main display's backing scale and silently produce a 2048px image.
///
/// Three samples per pixel, not four: an iOS app icon must have no alpha channel, and
/// App Store validation rejects one that does. `hasAlpha: false` alongside
/// `samplesPerPixel: 4` is rejected outright by NSBitmapImageRep as an inconsistent
/// description, so the sample count has to drop with it.
func drawIcon(size: Int) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(size)
    let canvas = NSRect(x: 0, y: 0, width: s, height: s)

    // Full bleed, square corners. iOS rounds it.
    plate.setFill()
    NSBezierPath(rect: canvas).fill()

    // The same three level bars as the desktop icon — the app's signature, and the only
    // element that survives being drawn at 40pt on a home screen.
    //
    // Scaled slightly smaller relative to the canvas than on macOS (0.115 vs 0.125 bar
    // width) because iOS's mask crops the corners: art tuned to the full square reads as
    // too tight once the corners are taken away.
    let heights: [CGFloat] = [0.45, 1.0, 0.68]
    let barWidth = s * 0.115
    let gap = s * 0.088
    let count = CGFloat(heights.count)
    let totalWidth = barWidth * count + gap * (count - 1)
    let startX = canvas.midX - totalWidth / 2
    let tallest = s * 0.42
    let baseline = canvas.midY - tallest / 2

    accent.setFill()
    for (i, fraction) in heights.enumerated() {
        let x = startX + CGFloat(i) * (barWidth + gap)
        NSBezierPath(rect: NSRect(
            x: x, y: baseline, width: barWidth, height: tallest * fraction)).fill()
    }

    return rep
}

guard let rep = drawIcon(size: 1024),
      let png = rep.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write(Data("failed to render icon\n".utf8))
    exit(1)
}

try png.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath)")
