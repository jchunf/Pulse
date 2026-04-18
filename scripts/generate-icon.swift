#!/usr/bin/env swift

// Renders the Pulse app icon at every size macOS needs for `.icns` and
// writes them to `apple/Pulse.iconset/`. `package.sh` then calls
// `iconutil -c icns apple/Pulse.iconset` to produce the final
// `apple/Pulse.icns` that ships inside `Contents/Resources/`.
//
// Run manually:
//   swift scripts/generate-icon.swift
//
// Deps: none beyond the macOS Swift toolchain (CoreGraphics + ImageIO
// are bundled). Safe to re-run — overwrites existing PNGs.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Vital Pulse palette (matches Sources/PulseApp/DesignSystem.swift)

let coral = CGColor(red: 0xF5/255.0, green: 0x65/255.0, blue: 0x65/255.0, alpha: 1)
let coralDark = CGColor(red: 0xE5/255.0, green: 0x4E/255.0, blue: 0x4E/255.0, alpha: 1)
let amber = CGColor(red: 0xE5/255.0, green: 0xA1/255.0, blue: 0x4A/255.0, alpha: 1)

// MARK: - Icon sizes

/// macOS `.icns` requires every one of these exact filenames inside the
/// `.iconset` directory. See Apple's HIG → "Optimizing Image Resources
/// for Retina Display".
let targets: [(name: String, size: Int)] = [
    ("icon_16x16",       16),
    ("icon_16x16@2x",    32),
    ("icon_32x32",       32),
    ("icon_32x32@2x",    64),
    ("icon_128x128",    128),
    ("icon_128x128@2x", 256),
    ("icon_256x256",    256),
    ("icon_256x256@2x", 512),
    ("icon_512x512",    512),
    ("icon_512x512@2x", 1024)
]

// MARK: - Render one tile

func drawIcon(side: Int) -> CGImage {
    let canvas = CGFloat(side)
    let space = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    // macOS "Big Sur" squircle — Apple uses r ≈ 22.37% × side; the
    // CGPath roundedRect is a circle-approximated rectangle which is
    // good enough at the sizes we ship.
    let cornerRadius = canvas * 0.2237
    let bounds = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    let squircle = CGPath(
        roundedRect: bounds,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )

    // Clip to the squircle so the gradient doesn't spill into the
    // corners (macOS masks the app icon with the same shape on
    // display but we want the PNG itself to have transparent corners).
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // Diagonal Coral → Amber gradient. Top-left to bottom-right is the
    // "morning light" angle; swap endpoints in CG's flipped y-axis by
    // starting at (0, side) and ending at (side, 0).
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [coral, amber] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: canvas),
        end: CGPoint(x: canvas, y: 0),
        options: []
    )

    // Secondary very-soft inner highlight so the face doesn't read as
    // a flat PowerPoint gradient. Low-alpha white circle at the
    // top-left quadrant, blurred via an oversized radius.
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
    ctx.fillEllipse(in: CGRect(
        x: -canvas * 0.1,
        y: canvas * 0.3,
        width: canvas * 0.9,
        height: canvas * 0.9
    ))

    // ECG heartbeat line — white, chunky stroke that reads at 16pt.
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineWidth(canvas * 0.068)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    let wave = CGMutablePath()
    let midY = canvas * 0.52  // slight visual centering bias (icons read
                              // heavier toward top)
    let lx = canvas * 0.18
    let rx = canvas * 0.82
    let span = rx - lx
    let step = span / 10

    // Flat lead-in
    wave.move(to: CGPoint(x: lx, y: midY))
    wave.addLine(to: CGPoint(x: lx + step * 3, y: midY))
    // P wave (small bump up)
    wave.addLine(to: CGPoint(x: lx + step * 3.6, y: midY - canvas * 0.06))
    wave.addLine(to: CGPoint(x: lx + step * 4.2, y: midY))
    // Q (small dip)
    wave.addLine(to: CGPoint(x: lx + step * 4.6, y: midY + canvas * 0.05))
    // R (big spike up — the "heartbeat")
    wave.addLine(to: CGPoint(x: lx + step * 5.0, y: midY - canvas * 0.24))
    // S (dip under baseline)
    wave.addLine(to: CGPoint(x: lx + step * 5.4, y: midY + canvas * 0.09))
    // Return to baseline
    wave.addLine(to: CGPoint(x: lx + step * 5.8, y: midY))
    wave.addLine(to: CGPoint(x: lx + step * 6.6, y: midY))
    // T wave (broad hill up)
    wave.addLine(to: CGPoint(x: lx + step * 7.4, y: midY - canvas * 0.07))
    wave.addLine(to: CGPoint(x: lx + step * 8.2, y: midY))
    // Flat tail-out
    wave.addLine(to: CGPoint(x: rx, y: midY))

    ctx.addPath(wave)
    ctx.strokePath()

    ctx.restoreGState()

    return ctx.makeImage()!
}

// MARK: - PNG writer

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw NSError(
            domain: "generate-icon",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "couldn't create PNG destination"]
        )
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(
            domain: "generate-icon",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "couldn't finalize PNG"]
        )
    }
}

// MARK: - Entry point

let fm = FileManager.default
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
let root = scriptURL.deletingLastPathComponent()
let iconsetURL = root
    .appendingPathComponent("apple", isDirectory: true)
    .appendingPathComponent("Pulse.iconset", isDirectory: true)

try? fm.removeItem(at: iconsetURL)
try fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

for target in targets {
    let image = drawIcon(side: target.size)
    let fileURL = iconsetURL.appendingPathComponent("\(target.name).png")
    try writePNG(image, to: fileURL)
    print("wrote \(fileURL.path) (\(target.size)px)")
}

print("done — run `iconutil -c icns \(iconsetURL.path)` to produce Pulse.icns")
