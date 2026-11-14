#!/usr/bin/env swift
// Renders Bundling/AppIcon.png (1024x1024) from Design/AppIcon.svg.
//
// Swift Bundler turns a .png into the macOS .icns with sips/iconutil, so this
// is the macOS icon: the line drawing on the light fill AppIcon.icon/icon.json
// uses, set in the standard macOS icon shape (824 pt rounded square centred on
// the 1024 pt canvas, with the soft drop shadow). The iOS icon is the separate
// Icon Composer bundle Bundling/AppIcon.icon, which tools/generate_ios_icons.py
// produces.
//
// Needs only the macOS SDK (AppKit renders the SVG): no Inkscape or Xcode.
//
//   swift tools/render_app_icon.swift [Design/AppIcon.svg] [Bundling/AppIcon.png]

import AppKit

let arguments = CommandLine.arguments
let svgPath = arguments.count > 1 ? arguments[1] : "Design/AppIcon.svg"
let outPath = arguments.count > 2 ? arguments[2] : "Bundling/AppIcon.png"

let canvas: CGFloat = 1024
let plate: CGFloat = 824
let cornerRadius: CGFloat = 185
/// Fraction of the plate the drawing's longest side may occupy.
let artworkFill: CGFloat = 0.62

// 0.90980 in icon.json's extended-sRGB fill, top lightened a touch for depth.
let plateTop = NSColor(srgbRed: 0.965, green: 0.965, blue: 0.965, alpha: 1)
let plateBottom = NSColor(srgbRed: 0.8745, green: 0.8745, blue: 0.8745, alpha: 1)
let ink = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1)

guard let svg = NSImage(contentsOf: URL(fileURLWithPath: svgPath)) else {
    FileHandle.standardError.write(Data("cannot read \(svgPath)\n".utf8))
    exit(1)
}

func bitmap(_ side: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: side, height: side)
    return rep
}

func withContext(_ rep: NSBitmapImageRep, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    body()
    NSGraphicsContext.restoreGraphicsState()
}

// 1. Rasterise the stroke drawing large and find its tight bounds, so the
//    artwork can be centred and scaled regardless of the SVG's page margins.
let probeSide = 2048
let probe = bitmap(probeSide)
withContext(probe) {
    let side = CGFloat(probeSide)
    let fit = min(side / svg.size.width, side / svg.size.height)
    let size = NSSize(width: svg.size.width * fit, height: svg.size.height * fit)
    svg.draw(
        in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height),
        from: .zero, operation: .sourceOver, fraction: 1
    )
}
var minX = probeSide, minY = probeSide, maxX = -1, maxY = -1
for y in 0 ..< probeSide {
    for x in 0 ..< probeSide where (probe.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX >= 0 else {
    FileHandle.standardError.write(Data("the SVG rendered empty\n".utf8))
    exit(1)
}
// Bitmap rows count from the top; drawing coordinates from the bottom.
let bounds = NSRect(x: minX, y: probeSide - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1)

// 2. Tint the strokes: use the probe as a mask over a solid ink fill.
let tinted = NSImage(size: NSSize(width: probeSide, height: probeSide))
tinted.lockFocus()
NSImage(size: probe.size, flipped: false) { rect in
    probe.draw(in: rect)
    return true
}.draw(in: NSRect(origin: .zero, size: probe.size))
ink.setFill()
NSRect(origin: .zero, size: probe.size).fill(using: .sourceIn)
tinted.unlockFocus()

// 3. Compose the icon.
let icon = bitmap(Int(canvas))
withContext(icon) {
    let plateRect = NSRect(x: (canvas - plate) / 2, y: (canvas - plate) / 2, width: plate, height: plate)
    let shape = NSBezierPath(roundedRect: plateRect, xRadius: cornerRadius, yRadius: cornerRadius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 22
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    plateBottom.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: plateTop, ending: plateBottom)?.draw(in: shape, angle: -90)

    let scale = (plate * artworkFill) / max(bounds.width, bounds.height)
    let target = NSSize(width: bounds.width * scale, height: bounds.height * scale)
    let drawRect = NSRect(
        x: (canvas - target.width) / 2, y: (canvas - target.height) / 2,
        width: target.width, height: target.height
    )
    tinted.draw(in: drawRect, from: bounds, operation: .sourceOver, fraction: 1)
}

guard let png = icon.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(Int(canvas))x\(Int(canvas)))")
