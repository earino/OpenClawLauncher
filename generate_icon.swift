#!/usr/bin/env swift

import AppKit
import Foundation

// Generate an app icon with a lobster and rocket on a gradient background
func generateIcon(size: Int) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let s = CGFloat(size)

    // Draw rounded-rect background with gradient
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.18, yRadius: s * 0.18)
    let gradient = NSGradient(colors: [
        NSColor(red: 0.08, green: 0.08, blue: 0.20, alpha: 1.0),   // deep navy
        NSColor(red: 0.12, green: 0.05, blue: 0.25, alpha: 1.0),   // deep purple
        NSColor(red: 0.20, green: 0.03, blue: 0.15, alpha: 1.0),   // dark magenta
    ])!
    gradient.draw(in: path, angle: -45)

    // Subtle inner glow
    let glowPath = NSBezierPath(roundedRect: rect.insetBy(dx: s * 0.02, dy: s * 0.02),
                                 xRadius: s * 0.16, yRadius: s * 0.16)
    let glowGradient = NSGradient(colors: [
        NSColor(red: 0.3, green: 0.1, blue: 0.4, alpha: 0.3),
        NSColor(red: 0.1, green: 0.1, blue: 0.3, alpha: 0.0),
    ])!
    glowGradient.draw(in: glowPath, angle: -45)

    // Draw emoji characters
    let lobsterSize = s * 0.48
    let rocketSize = s * 0.36

    // Lobster — centered, slightly lower
    let lobsterFont = NSFont.systemFont(ofSize: lobsterSize)
    let lobsterStr = NSAttributedString(string: "🦞", attributes: [
        .font: lobsterFont
    ])
    let lobsterBounds = lobsterStr.boundingRect(with: NSSize(width: s, height: s), options: [.usesLineFragmentOrigin])
    let lobsterX = (s - lobsterBounds.width) / 2 - s * 0.02
    let lobsterY = (s - lobsterBounds.height) / 2 - s * 0.08
    lobsterStr.draw(at: NSPoint(x: lobsterX, y: lobsterY))

    // Rocket — upper right, slightly overlapping
    let rocketFont = NSFont.systemFont(ofSize: rocketSize)
    let rocketStr = NSAttributedString(string: "🚀", attributes: [
        .font: rocketFont
    ])
    let rocketBounds = rocketStr.boundingRect(with: NSSize(width: s, height: s), options: [.usesLineFragmentOrigin])
    let rocketX = s * 0.55
    let rocketY = s * 0.52
    rocketStr.draw(at: NSPoint(x: rocketX, y: rocketY))

    img.unlockFocus()
    return img
}

func savePNG(image: NSImage, size: Int, path: String) {
    // Create a bitmap at exact pixel dimensions
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                pixelsWide: size,
                                pixelsHigh: size,
                                bitsPerSample: 8,
                                samplesPerPixel: 4,
                                hasAlpha: true,
                                isPlanar: false,
                                colorSpaceName: .deviceRGB,
                                bytesPerRow: 0,
                                bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
               from: NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height),
               operation: .sourceOver,
               fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()

    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

// macOS icon sizes needed (pixels): 16, 32, 64, 128, 256, 512, 1024
let iconsetDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] :
    FileManager.default.currentDirectoryPath + "/OpenClawLauncher/Assets.xcassets/AppIcon.appiconset"

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for entry in sizes {
    let img = generateIcon(size: entry.pixels)
    let path = iconsetDir + "/" + entry.name
    savePNG(image: img, size: entry.pixels, path: path)
    print("Generated \(entry.name) (\(entry.pixels)x\(entry.pixels)px)")
}

print("\nDone! Generated \(sizes.count) icon files.")
