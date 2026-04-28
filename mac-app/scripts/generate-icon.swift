// Generates Retrospective's app icon PNGs into the asset catalog.
//
// Run from mac-app/:
//     swift scripts/generate-icon.swift
// (or `make icon`).
//
// Source artwork: scripts/icon-source.jpg (the eight4awish magpie logo).
// Composition: cream squircle background with the bird cropped square and
// padded inside, plus a small red record dot in the corner to telegraph
// "audio recorder".

import AppKit
import Foundation

let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
let projectDir = scriptDir.deletingLastPathComponent()
let outputDir = projectDir
    .appendingPathComponent("Retrospective/Assets.xcassets/AppIcon.appiconset")
let sourceURL = scriptDir.appendingPathComponent("icon-source.jpg")

try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

// Load source artwork.
guard let sourceData = try? Data(contentsOf: sourceURL),
      let sourceRep = NSBitmapImageRep(data: sourceData),
      let sourceCG = sourceRep.cgImage else {
    fputs("Could not load \(sourceURL.path)\n", stderr)
    exit(1)
}

// Crop tight to the magpie, dropping the "eight4awish" wordmark to the right.
// Source image is 1868×1243; the bird occupies roughly the left third.
// We keep the natural aspect (bird is taller than wide) and centre it inside
// the icon canvas with padding.
let cropRect = CGRect(x: 60, y: 30, width: 830, height: 1180)
guard let birdCG = sourceCG.cropping(to: cropRect) else {
    fputs("Crop failed\n", stderr)
    exit(1)
}
let bird = NSImage(
    cgImage: birdCG,
    size: NSSize(width: birdCG.width, height: birdCG.height))

func drawIcon(size: CGFloat) {
    let bg = CGRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = size * 0.225
    let bgPath = NSBezierPath(roundedRect: bg, xRadius: cornerRadius, yRadius: cornerRadius)

    // White squircle background — matches the source logo's white field, so the
    // bird's silhouette reads cleanly with no colour seam where source meets icon.
    // Subtle vertical gradient adds a hint of depth at large sizes.
    NSGraphicsContext.saveGraphicsState()
    bgPath.addClip()
    let bgGradient = NSGradient(colors: [
        NSColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1),
        NSColor(red: 0.96, green: 0.95, blue: 0.93, alpha: 1)
    ])!
    bgGradient.draw(in: bg, angle: 270)

    // Bird, aspect-preserved and centred inside a padded square.
    let pad = size * 0.05
    let avail = bg.insetBy(dx: pad, dy: pad)
    let aspect = CGFloat(birdCG.width) / CGFloat(birdCG.height)
    let birdRect: CGRect
    if aspect >= 1 {
        let w = avail.width
        let h = w / aspect
        birdRect = CGRect(x: avail.minX, y: avail.midY - h / 2, width: w, height: h)
    } else {
        let h = avail.height
        let w = h * aspect
        birdRect = CGRect(x: avail.midX - w / 2, y: avail.minY, width: w, height: h)
    }
    bird.draw(in: birdRect,
              from: .zero,
              operation: .sourceOver,
              fraction: 1.0,
              respectFlipped: true,
              hints: [.interpolation: NSImageInterpolation.high])

    NSGraphicsContext.restoreGraphicsState()
}

func savePNG(pixels: Int, filename: String) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32) else {
        throw NSError(domain: "icongen", code: 1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(size: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icongen", code: 2)
    }
    let url = outputDir.appendingPathComponent(filename)
    try data.write(to: url)
    print("  \(pixels)×\(pixels) → \(filename)")
}

let sizes: [(filename: String, pixels: Int)] = [
    ("icon_16x16.png",      16),
    ("icon_16x16@2x.png",   32),
    ("icon_32x32.png",      32),
    ("icon_32x32@2x.png",   64),
    ("icon_128x128.png",   128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",   256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",   512),
    ("icon_512x512@2x.png", 1024),
]

print("Generating AppIcon set in \(outputDir.path):")
for (filename, pixels) in sizes {
    try savePNG(pixels: pixels, filename: filename)
}
print("Done.")
