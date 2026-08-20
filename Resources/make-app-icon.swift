#!/usr/bin/env swift
//
// Regenerates Resources/AppIcon.icns — the bundle icon shown in Finder, in the
// input-source list and in the Input Sources settings pane. Run from the repo
// root:
//
//     swift Resources/make-app-icon.swift
//
// The design is the usual macOS one: a warm rounded square canvas with a dark
// tile on top of it carrying the glyph. `iconutil` needs the intermediate
// .iconset directory, so it is written next to the .icns and removed after.
import AppKit

let glyph = "V"

/// Icon sizes macOS asks for, as (pixels, iconset file name).
let variants: [(pixels: Int, name: String)] = [
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

// Everything below is expressed as a fraction of the icon's edge, so one set of
// numbers draws every size.
let canvasInset: CGFloat = 0.10      // Apple leaves a margin around the artwork
let canvasCornerRatio: CGFloat = 0.2246  // of the canvas edge — the squircle look
let tileFraction: CGFloat = 0.62     // dark tile, as a fraction of the canvas
let tileCornerRatio: CGFloat = 0.26  // of the tile edge
let glyphFraction: CGFloat = 0.60    // glyph ink, as a fraction of the tile

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

let canvasTop = color(0xF6C08A)   // light peach, top-left
let canvasBottom = color(0xE07C3C)  // deeper orange, bottom-right
let tileColor = color(0x2A2220)   // near-black, slightly warm
let glyphColor = color(0xF7CFA4)  // the canvas's light tone, on the dark tile

/// The tight bounding box of the drawn glyph at the given font size.
func inkBounds(fontSize: CGFloat, in context: CGContext) -> CGRect {
    let attributed = NSAttributedString(
        string: glyph,
        attributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .bold)]
    )
    return CTLineGetImageBounds(CTLineCreateWithAttributedString(attributed), context)
}

let iconset = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for variant in variants {
    let pixels = variant.pixels
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
    ) else {
        fatalError("could not create a \(pixels)×\(pixels) bitmap")
    }

    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .high
    let context = graphics.cgContext

    let edge = CGFloat(pixels)

    // ── Canvas ────────────────────────────────────────────────────────────────
    let canvasEdge = edge * (1 - 2 * canvasInset)
    let canvas = CGRect(
        x: (edge - canvasEdge) / 2,
        y: (edge - canvasEdge) / 2,
        width: canvasEdge,
        height: canvasEdge
    )
    let canvasPath = NSBezierPath(
        roundedRect: canvas,
        xRadius: canvasEdge * canvasCornerRatio,
        yRadius: canvasEdge * canvasCornerRatio
    )
    context.saveGState()
    canvasPath.addClip()
    // Top-left to bottom-right: in AppKit's flipped-up coordinates that is an
    // angle of -45°, which NSGradient takes measured from the +x axis.
    NSGradient(starting: canvasBottom, ending: canvasTop)?
        .draw(in: canvas, angle: 45)
    context.restoreGState()

    // ── Dark tile ─────────────────────────────────────────────────────────────
    let tileEdge = canvasEdge * tileFraction
    let tile = CGRect(
        x: (edge - tileEdge) / 2,
        y: (edge - tileEdge) / 2,
        width: tileEdge,
        height: tileEdge
    )
    context.saveGState()
    // A soft shadow lifts the tile off the canvas; at 16px it would only muddy
    // the artwork, so it is skipped there.
    if pixels >= 32 {
        context.setShadow(
            offset: CGSize(width: 0, height: -tileEdge * 0.03),
            blur: tileEdge * 0.07,
            color: NSColor(white: 0, alpha: 0.30).cgColor
        )
    }
    tileColor.setFill()
    NSBezierPath(
        roundedRect: tile,
        xRadius: tileEdge * tileCornerRatio,
        yRadius: tileEdge * tileCornerRatio
    ).fill()
    context.restoreGState()

    // ── Glyph ─────────────────────────────────────────────────────────────────
    // Measure once at a reference size, then scale the font so the *ink* — not
    // the font's line box — fills the intended fraction of the tile.
    let target = tileEdge * glyphFraction
    let referenceInk = inkBounds(fontSize: tileEdge, in: context)
    let fitted = tileEdge * min(target / referenceInk.width, target / referenceInk.height)
    let ink = inkBounds(fontSize: fitted, in: context)
    let font = NSFont.systemFont(ofSize: fitted, weight: .bold)
    NSAttributedString(
        string: glyph,
        attributes: [.font: font, .foregroundColor: glyphColor]
    ).draw(at: NSPoint(
        // `draw(at:)` takes the bottom-left of the line box, which sits
        // `descender` below the baseline the ink bounds are measured from.
        x: tile.midX - ink.width / 2 - ink.minX,
        y: tile.midY - ink.height / 2 - ink.minY + font.descender
    ))

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(variant.name)")
    }
    try png.write(to: iconset.appendingPathComponent(variant.name))
}

let icns = URL(fileURLWithPath: "Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil failed (\(iconutil.terminationStatus)); \(iconset.path) kept for inspection")
}
try FileManager.default.removeItem(at: iconset)

let bytes = (try Data(contentsOf: icns)).count
print("wrote \(icns.path) (\(bytes) bytes, \(variants.map { "\($0.pixels)" }.joined(separator: "/"))px)")
