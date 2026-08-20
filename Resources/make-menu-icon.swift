#!/usr/bin/env swift
//
// Regenerates Resources/MenuIcon.tiff — the icon shown in the input-source menu
// bar item and in the Input Sources list — from the hand-drawn artwork in
// Resources/MenuIcon-source.tiff. Run from the repo root:
//
//     swift Resources/make-menu-icon.swift [artwork]
//
// Two things stand between artwork and a usable menu-bar icon.
//
// 1. macOS treats the icon as a *template*: it discards the colours and keeps
//    only the alpha channel, which is what makes the icon invert by itself in
//    dark mode and under the menu highlight. Artwork exported from a drawing
//    app is normally opaque black-on-white with no alpha, and a template shows
//    that as one solid block. So ink darkness is converted into opacity here.
//
// 2. The menu bar renders the icon into a fixed *square* slot: a non-square
//    image gets scaled to fit it, distorting the artwork (a 23×16pt icon came
//    out with its character visibly stretched tall). So the canvas here is
//    always 16×16pt like Apple's own icons — but the *tile* inside it keeps
//    the artwork's aspect ratio, drawn full-width and letterboxed with
//    transparency above and below. The tile may be a wide rectangle; the
//    image never is.
//
// The artwork's *margins* are still discarded: only the tile and the character
// knocked out of it are measured, and both are re-laid out onto the canvas.
import AppKit

let artwork = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/MenuIcon-source.tiff")

let pointSize: CGFloat = 16     // the square canvas's edge in points
let scales = [1, 2]             // @1x and @2x representations
/// Proportions as fractions of the tile's height, measured off Apple's
/// Hiragana.tiff except where noted.
let cornerFraction: CGFloat = 4.0 / 32   // corner radius: 4px of 32
/// The character's longer side. Apple's あ is 20/32 of a tile that fills the
/// icon's full height; this tile is letterboxed to keep the artwork's aspect
/// ratio, so the same fraction of a shorter tile reads too small next to it.
let glyphFraction: CGFloat = 24.0 / 32
/// Alpha below/above which a pixel counts as background/ink when the artwork is
/// analysed. Anti-aliased edges sit between the two.
let inkThreshold = 0.5

// ── Read the artwork as a template ────────────────────────────────────────────
guard let source = NSImage(contentsOf: artwork) else {
    fatalError("could not read the artwork at \(artwork.path)")
}

/// An RGBA bitmap of the given pixel dimensions whose `size` is its size in
/// points — that is what marks a 2×-resolution bitmap as the @2x variant of an
/// icon rather than a separate, larger icon, and it is also why the artwork's
/// own DPI does not matter here.
func makeRep(pixelsWide: Int, pixelsHigh: Int, points: NSSize) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelsWide,
        pixelsHigh: pixelsHigh,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("could not create a \(pixelsWide)×\(pixelsHigh) bitmap")
    }
    rep.size = points
    return rep
}

/// Renders the artwork at `width`×`height` and returns its ink as opacity: 1
/// where the artwork is black, 0 where it is white or already transparent.
func inkAlpha(width: Int, height: Int) -> [[Double]] {
    let rep = makeRep(pixelsWide: width, pixelsHigh: height,
                      points: NSSize(width: width, height: height))
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .high
    // White underneath, so artwork that is transparent rather than white-backed
    // comes through the conversion the same way.
    let canvas = NSRect(x: 0, y: 0, width: width, height: height)
    NSColor.white.setFill()
    canvas.fill()
    source.draw(in: canvas, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    // Row 0 is the top row, matching `colorAt`; the drawing above is the only
    // place that cares which way up the bitmap is.
    return (0..<height).map { y in
        (0..<width).map { x in
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 0 }
            return (1 - Double(c.brightnessComponent)) * Double(c.alphaComponent)
        }
    }
}

// The artwork is analysed on its own pixel grid — that is all the detail there
// is, and keeping its aspect ratio here is what keeps the tile undistorted. Both
// output representations are then laid out from that one analysis.
let sourceWidth = source.representations.map(\.pixelsWide).max() ?? 32
let sourceHeight = source.representations.map(\.pixelsHigh).max() ?? 32
let analysisWidth = max(32, sourceWidth)
let analysisHeight = max(1, Int((CGFloat(analysisWidth) * CGFloat(sourceHeight)
                                / CGFloat(sourceWidth)).rounded()))
let ink = inkAlpha(width: analysisWidth, height: analysisHeight)

// ── Find the tile and the character ───────────────────────────────────────────
// The artwork is a filled tile with the character knocked out of it, so the
// character is the *hole*: background-coloured pixels enclosed by the tile.
var tile = (minX: analysisWidth, minY: analysisHeight, maxX: -1, maxY: -1)
for y in 0..<analysisHeight {
    for x in 0..<analysisWidth where ink[y][x] > inkThreshold {
        tile = (min(tile.minX, x), min(tile.minY, y), max(tile.maxX, x), max(tile.maxY, y))
    }
}
guard tile.maxX >= tile.minX else { fatalError("the artwork at \(artwork.path) is blank") }
let tileWidth = tile.maxX - tile.minX + 1
let tileHeight = tile.maxY - tile.minY + 1

// "Enclosed" has to be taken literally: the tile's own rounded corners are
// background-coloured and sit inside the tile's bounding box, so a plain scan of
// that box finds a "character" the size of the whole tile and the icon comes out
// a solid blob. Flooding the background inwards from the artwork's edges marks
// everything the tile does *not* enclose — corners included — and whatever
// background is left over is the character.
var outside = [[Bool]](repeating: [Bool](repeating: false, count: analysisWidth),
                       count: analysisHeight)
var queue = [(Int, Int)]()
for x in 0..<analysisWidth {
    for y in [0, analysisHeight - 1] where !outside[y][x] && ink[y][x] < inkThreshold {
        outside[y][x] = true
        queue.append((x, y))
    }
}
for y in 0..<analysisHeight {
    for x in [0, analysisWidth - 1] where !outside[y][x] && ink[y][x] < inkThreshold {
        outside[y][x] = true
        queue.append((x, y))
    }
}
while let (x, y) = queue.popLast() {
    for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
    where nx >= 0 && ny >= 0 && nx < analysisWidth && ny < analysisHeight
        && !outside[ny][nx] && ink[ny][nx] < inkThreshold {
        outside[ny][nx] = true
        queue.append((nx, ny))
    }
}

var hole = (minX: analysisWidth, minY: analysisHeight, maxX: -1, maxY: -1)
for y in tile.minY...tile.maxY {
    for x in tile.minX...tile.maxX where ink[y][x] < inkThreshold && !outside[y][x] {
        hole = (min(hole.minX, x), min(hole.minY, y), max(hole.maxX, x), max(hole.maxY, y))
    }
}
guard hole.maxX >= hole.minX else {
    fatalError("no knocked-out character found inside the tile in \(artwork.path)")
}
let holeWidth = hole.maxX - hole.minX + 1
let holeHeight = hole.maxY - hole.minY + 1

// The character as its own image: opaque where the artwork had a hole. This is
// what gets stamped back out of the new tile, so it carries the artwork's own
// curves — including their anti-aliasing, as partial alpha.
let character = makeRep(pixelsWide: holeWidth, pixelsHigh: holeHeight,
                        points: NSSize(width: holeWidth, height: holeHeight))
for y in 0..<holeHeight {
    for x in 0..<holeWidth {
        let sx = hole.minX + x, sy = hole.minY + y
        let alpha = outside[sy][sx] ? 0 : 1 - ink[sy][sx]
        character.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: CGFloat(alpha)), atX: x, y: y)
    }
}
let characterImage = NSImage(size: NSSize(width: holeWidth, height: holeHeight))
characterImage.addRepresentation(character)

// ── Draw the icon ─────────────────────────────────────────────────────────────
// The canvas is square; the tile inside it spans the full width, with its
// height set by the artwork's aspect ratio and the leftover rows transparent.
// (A tile taller than wide would span the full height instead.)
let iconPoints = NSSize(width: pointSize, height: pointSize)
let tileAspect = CGFloat(tileWidth) / CGFloat(tileHeight)
let tileSize = tileAspect >= 1
    ? NSSize(width: pointSize, height: pointSize / tileAspect)
    : NSSize(width: pointSize * tileAspect, height: pointSize)
let image = NSImage(size: iconPoints)

for scale in scales {
    let rep = makeRep(pixelsWide: Int(pointSize) * scale,
                      pixelsHigh: Int(pointSize) * scale,
                      points: iconPoints)

    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .high

    // `rep.size` is the point size, so the context has a matching scale
    // transform and everything below is in points — 16 units tall whatever the
    // bitmap's resolution.
    let bounds = CGRect(origin: .zero, size: iconPoints)
    let tileRect = CGRect(
        x: bounds.midX - tileSize.width / 2,
        y: bounds.midY - tileSize.height / 2,
        width: tileSize.width,
        height: tileSize.height
    )

    // The tile, centred on the canvas; the rest of the canvas stays transparent.
    NSColor.black.setFill()
    NSBezierPath(
        roundedRect: tileRect,
        xRadius: tileSize.height * cornerFraction,
        yRadius: tileSize.height * cornerFraction
    ).fill()

    // The character, punched back out of it. `.destinationOut` clears the alpha
    // the character covers, which is the only way a template icon can show it.
    // It has to be the *draw operation*: `NSImage.draw` sets the context's blend
    // mode from its own `operation:`, so a blend mode set on the CGContext
    // beforehand is overwritten and the character silently never appears.
    let target = tileSize.height * glyphFraction
    let longer = CGFloat(max(holeWidth, holeHeight))
    let drawn = NSSize(
        width: target * CGFloat(holeWidth) / longer,
        height: target * CGFloat(holeHeight) / longer
    )
    characterImage.draw(
        in: CGRect(
            x: bounds.midX - drawn.width / 2,
            y: bounds.midY - drawn.height / 2,
            width: drawn.width,
            height: drawn.height
        ),
        from: .zero,
        operation: .destinationOut,
        fraction: 1
    )

    NSGraphicsContext.restoreGraphicsState()

    // Enlarging a 14px character to 20px leaves soft edges; a contrast curve on
    // the alpha channel pulls them back to something as crisp as the artwork
    // was, without hardening them into stairsteps.
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            let a = Double(c.alphaComponent)
            let sharpened = min(1, max(0, (a - 0.5) * 2.0 + 0.5))
            rep.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: CGFloat(sharpened)), atX: x, y: y)
        }
    }
    image.addRepresentation(rep)
}

guard let tiff = image.tiffRepresentation else {
    fatalError("could not encode the TIFF")
}
let out = URL(fileURLWithPath: "Resources/MenuIcon.tiff")
try tiff.write(to: out)
print("""
wrote \(out.path) from \(artwork.lastPathComponent) (\(tiff.count) bytes)
  artwork: tile \(tileWidth)×\(tileHeight)px, character \(holeWidth)×\(holeHeight)px, \
analysed at \(analysisWidth)×\(analysisHeight)px
  icon:    \(Int(pointSize))×\(Int(pointSize))pt canvas \
(\(scales.map { "\(Int(pointSize) * $0)px" }.joined(separator: " and "))), \
tile \(String(format: "%.1f×%.1f", tileSize.width, tileSize.height))pt \
(aspect \(String(format: "%.2f", Double(tileWidth) / Double(tileHeight))) kept), \
character \(String(format: "%.1f", tileSize.height * glyphFraction))pt tall \
(Apple's あ: 32×32px tile, character 19×20px)
""")
