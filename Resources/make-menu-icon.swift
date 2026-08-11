#!/usr/bin/env swift
//
// Regenerates Resources/MenuIcon.tiff — the glyph shown in the input-source
// menu bar item. Run from the repo root:
//
//     swift Resources/make-menu-icon.swift
//
// The icon is drawn as a black glyph on transparency at 16pt and 32pt (@2x) in
// one multi-representation TIFF. macOS treats a menu-bar icon as a template:
// only the alpha channel matters, so the glyph inverts correctly in dark mode
// and when the menu bar item is highlighted.
import AppKit
import CoreText

let glyph = "し"
let pointSize = 16          // the icon's size in points
let scales = [1, 2]         // 16px and 32px representations
/// Fraction of the tile the glyph's ink is allowed to fill. A menu-bar item is
/// short, so a kana is scaled to its *ink* rather than its font line box —
/// し in particular has a tall line box and very little ink in it.
let inkFraction: CGFloat = 0.88

/// The tight bounding box of the drawn glyph, in the given font size.
func inkBounds(fontSize: CGFloat, in context: CGContext) -> CGRect {
    let attributed = NSAttributedString(
        string: glyph,
        attributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium)]
    )
    return CTLineGetImageBounds(CTLineCreateWithAttributedString(attributed), context)
}

let image = NSImage(size: NSSize(width: pointSize, height: pointSize))

for scale in scales {
    let pixels = pointSize * scale
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
    // Point size stays 16 for every representation; that is what marks the
    // larger bitmap as the @2x variant rather than a separate icon.
    rep.size = NSSize(width: pointSize, height: pointSize)

    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext

    // Setting `rep.size` to the point size gives the context a matching scale
    // transform, so all drawing below is in *points* — 16 units wide whatever
    // the bitmap's pixel resolution. Drawing in pixels here would double
    // everything on the @2x pass.
    let tile = CGFloat(pointSize)
    let target = tile * inkFraction

    // Measure once at a reference size, then scale the font so the ink fits.
    let reference = tile
    let referenceInk = inkBounds(fontSize: reference, in: context)
    let fitted = reference * min(target / referenceInk.width, target / referenceInk.height)

    let font = NSFont.systemFont(ofSize: fitted, weight: .medium)
    let text = NSAttributedString(
        string: glyph,
        attributes: [.font: font, .foregroundColor: NSColor.black]
    )
    // Centre on the ink, not on the text origin: offset by where the ink sits
    // relative to the drawing origin.
    let ink = inkBounds(fontSize: fitted, in: context)
    text.draw(at: NSPoint(
        x: (tile - ink.width) / 2 - ink.minX,
        y: (tile - ink.height) / 2 - ink.minY
    ))

    NSGraphicsContext.restoreGraphicsState()
    image.addRepresentation(rep)
}

guard let tiff = image.tiffRepresentation else {
    fatalError("could not encode the TIFF")
}
let out = URL(fileURLWithPath: "Resources/MenuIcon.tiff")
try tiff.write(to: out)
print("wrote \(out.path) (\(tiff.count) bytes, \(scales.map { "\(pointSize * $0)" }.joined(separator: "/"))px)")
