#!/usr/bin/env swift
import AppKit
import Foundation

let scriptDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let svgURL = scriptDirectory.appendingPathComponent("AppIcon.svg")
let iconsetURL = scriptDirectory.appendingPathComponent("AppIcon.iconset")

guard let svgImage = NSImage(contentsOf: svgURL) else {
    FileHandle.standardError.write("render-icon: couldn't load \(svgURL.path)\n".data(using: .utf8)!)
    exit(1)
}

try? FileManager.default.removeItem(at: iconsetURL)
do {
    try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write("render-icon: couldn't create \(iconsetURL.path): \(error)\n".data(using: .utf8)!)
    exit(1)
}

let sizes: [(pixels: Int, filename: String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

func render(pixels: Int) -> NSBitmapImageRep? {
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
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = context
    svgImage.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero,
        operation: .copy,
        fraction: 1.0
    )
    return rep
}

for (pixels, filename) in sizes {
    guard let rep = render(pixels: pixels), let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("render-icon: couldn't render \(filename) at \(pixels)px\n".data(using: .utf8)!)
        exit(1)
    }
    let outURL = iconsetURL.appendingPathComponent(filename)
    do {
        try data.write(to: outURL)
    } catch {
        FileHandle.standardError.write("render-icon: couldn't write \(outURL.path): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

print("render-icon: wrote \(sizes.count) PNGs to \(iconsetURL.path)")
