#!/usr/bin/env swift
// Draws the app icon procedurally and writes an .iconset, so the repo carries no binary
// assets. Run via build.sh; output is handed to iconutil.

import AppKit

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./deck.iconset"
try? FileManager.default.createDirectory(
    atPath: outputDir, withIntermediateDirectories: true)

// Tokyo Night, matching the app's default theme.
let bg = NSColor(srgbRed: 0.102, green: 0.106, blue: 0.180, alpha: 1)
let accent = NSColor(srgbRed: 0.478, green: 0.635, blue: 0.968, alpha: 1)
let green = NSColor(srgbRed: 0.620, green: 0.808, blue: 0.416, alpha: 1)
let yellow = NSColor(srgbRed: 0.878, green: 0.686, blue: 0.408, alpha: 1)
let red = NSColor(srgbRed: 0.969, green: 0.463, blue: 0.557, alpha: 1)
let muted = NSColor(srgbRed: 0.337, green: 0.373, blue: 0.537, alpha: 1)

func drawIcon(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    defer { image.unlockFocus() }

    let inset = s * 0.06
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)

    // Terminal window body. Square corners, 1px-equivalent border.
    bg.setFill()
    NSBezierPath(rect: rect).fill()
    muted.withAlphaComponent(0.6).setStroke()
    let border = NSBezierPath(rect: rect)
    border.lineWidth = max(1, s * 0.008)
    border.stroke()

    // Titlebar strip with three traffic-light dots.
    let barHeight = rect.height * 0.16
    let barRect = NSRect(
        x: rect.minX, y: rect.maxY - barHeight, width: rect.width, height: barHeight)
    NSColor(srgbRed: 0.086, green: 0.090, blue: 0.165, alpha: 1).setFill()
    NSBezierPath(rect: barRect).fill()

    let dotRadius = barHeight * 0.17
    for (i, color) in [red, yellow, green].enumerated() {
        color.setFill()
        let x = rect.minX + barHeight * 0.45 + CGFloat(i) * dotRadius * 3.1
        let y = barRect.midY
        NSBezierPath(ovalIn: NSRect(
            x: x - dotRadius, y: y - dotRadius,
            width: dotRadius * 2, height: dotRadius * 2)).fill()
    }

    // Spectrum bars — the app's signature element.
    let heights: [CGFloat] = [0.30, 0.55, 0.80, 0.45, 0.95, 0.62, 0.38, 0.72, 0.25]
    let usable = rect.insetBy(dx: rect.width * 0.14, dy: 0)
    let barArea = NSRect(
        x: usable.minX, y: rect.minY + rect.height * 0.18,
        width: usable.width, height: rect.height * 0.52)
    let gap = barArea.width * 0.028
    let barWidth = (barArea.width - gap * CGFloat(heights.count - 1)) / CGFloat(heights.count)

    for (i, fraction) in heights.enumerated() {
        let h = barArea.height * fraction
        let x = barArea.minX + CGFloat(i) * (barWidth + gap)
        let color: NSColor = fraction > 0.85 ? red : (fraction > 0.6 ? yellow : accent)
        color.setFill()
        NSBezierPath(rect: NSRect(x: x, y: barArea.minY, width: barWidth, height: h)).fill()
    }

    return image
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
    let image = drawIcon(size: size)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(outputDir)/\(name).png"))
}

print("wrote iconset to \(outputDir)")
