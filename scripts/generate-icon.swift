#!/usr/bin/env swift
// Renders the Sentinel app icon — an eye in a shield on a dark indigo
// squircle — as a .iconset directory of PNGs. `make icon` turns that into
// AppIcon.icns via iconutil.
//
// Usage: swift scripts/generate-icon.swift [output-dir]   (default: build/icon)
//
// Pure CoreGraphics + ImageIO: no AppKit and no WindowServer connection, so it
// runs headless on CI, and the output is deterministic (no PNG metadata).
// Geometry is authored in a 1024x1024 y-up reference space and scaled to each
// pixel size, so every size renders from vectors rather than downsampling.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("generate-icon: \(message)\n".utf8))
    exit(1)
}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [
        CGFloat((hex >> 16) & 0xFF) / 255,
        CGFloat((hex >> 8) & 0xFF) / 255,
        CGFloat(hex & 0xFF) / 255,
        alpha,
    ])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

func render(pixels: Int) -> CGImage {
    guard let ctx = CGContext(
        data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("could not create a \(pixels)px bitmap context") }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Scale geometry through the CTM; shadows are in device space and must be
    // scaled by hand. Below 64px the shadows, glow, pupil, and catchlight are
    // dropped and the iris oversized so the mark stays legible.
    let s = CGFloat(pixels) / 1024
    ctx.scaleBy(x: s, y: s)
    let detail = pixels >= 64

    // Squircle plate on the Apple icon grid (824pt plate on a 1024pt canvas).
    let plate = CGPath(
        roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
        cornerWidth: 185.4, cornerHeight: 185.4, transform: nil
    )
    if detail {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 20 * s, color: rgb(0x000000, 0.30))
        ctx.addPath(plate)
        ctx.setFillColor(rgb(0x0C112C))
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(0x2B3768)), (0.55, rgb(0x1B2348)), (1, rgb(0x0C112C))]),
        start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: []
    )
    if detail {
        ctx.drawRadialGradient(
            gradient([(0, rgb(0x3EE6D8, 0.14)), (1, rgb(0x3EE6D8, 0))]),
            startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
            endCenter: CGPoint(x: 512, y: 560), endRadius: 460, options: []
        )
    }

    // Shield: flat top with rounded corners, sides sweeping to a pointed tip.
    let shield = CGMutablePath()
    shield.move(to: CGPoint(x: 512, y: 780))
    shield.addLine(to: CGPoint(x: 746, y: 780))
    shield.addQuadCurve(to: CGPoint(x: 782, y: 744), control: CGPoint(x: 782, y: 780))
    shield.addCurve(
        to: CGPoint(x: 512, y: 250),
        control1: CGPoint(x: 782, y: 550), control2: CGPoint(x: 660, y: 340)
    )
    shield.addCurve(
        to: CGPoint(x: 242, y: 744),
        control1: CGPoint(x: 364, y: 340), control2: CGPoint(x: 242, y: 550)
    )
    shield.addQuadCurve(to: CGPoint(x: 278, y: 780), control: CGPoint(x: 242, y: 780))
    shield.closeSubpath()

    if detail {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8 * s), blur: 18 * s, color: rgb(0x000000, 0.28))
        ctx.addPath(shield)
        ctx.setFillColor(rgb(0xD5E1ED))
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(shield)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(0xF4F8FB)), (1, rgb(0xD5E1ED))]),
        start: CGPoint(x: 512, y: 780), end: CGPoint(x: 512, y: 250), options: []
    )
    ctx.restoreGState()

    // Eye almond: the lens where two circles overlap (half-width 190, lid
    // bulge 100 -> arc radius (190^2 + 100^2) / (2 * 100) = 230.5). Clipping
    // to both circles yields the lens exactly, with no arc-winding math.
    let lensRadius: CGFloat = 230.5
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: 512 - lensRadius, y: 422.5 - lensRadius, width: lensRadius * 2, height: lensRadius * 2))
    ctx.clip()
    ctx.addEllipse(in: CGRect(x: 512 - lensRadius, y: 683.5 - lensRadius, width: lensRadius * 2, height: lensRadius * 2))
    ctx.clip()
    ctx.setFillColor(rgb(0x142048))
    ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))

    // Iris. At small sizes it is taller than the lens so the lids crop it,
    // which reads as a wide-open eye.
    let irisRadius: CGFloat = detail ? 95 : 105
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: 512 - irisRadius, y: 553 - irisRadius, width: irisRadius * 2, height: irisRadius * 2))
    ctx.clip()
    ctx.drawRadialGradient(
        gradient([(0, rgb(0x6FF2E0)), (0.62, rgb(0x38C4CF)), (1, rgb(0x1C7FA8))]),
        startCenter: CGPoint(x: 512, y: 558), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 558), endRadius: irisRadius,
        options: [.drawsAfterEndLocation]
    )
    ctx.restoreGState()

    if detail {
        ctx.setFillColor(rgb(0x081021))
        ctx.fillEllipse(in: CGRect(x: 512 - 40, y: 553 - 40, width: 80, height: 80))
        ctx.setFillColor(rgb(0xFFFFFF, 0.88))
        ctx.fillEllipse(in: CGRect(x: 480 - 17, y: 596 - 17, width: 34, height: 34))
    }
    ctx.restoreGState()

    ctx.restoreGState()
    guard let image = ctx.makeImage() else { fail("could not snapshot the \(pixels)px context") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("could not create \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("could not write \(url.path)") }
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon"
let iconset = URL(fileURLWithPath: outDir).appendingPathComponent("Sentinel.iconset")
try? FileManager.default.removeItem(at: iconset)
do {
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
} catch {
    fail("could not create \(iconset.path): \(error.localizedDescription)")
}

let entries: [(name: String, pixels: Int)] = [
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
var rendered: [Int: CGImage] = [:]
for (name, pixels) in entries {
    let image = rendered[pixels] ?? render(pixels: pixels)
    rendered[pixels] = image
    writePNG(image, to: iconset.appendingPathComponent(name))
}
print(iconset.path)
