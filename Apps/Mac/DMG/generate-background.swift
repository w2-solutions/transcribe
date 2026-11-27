#!/usr/bin/env swift
// Draws the background of the Transcribe DMG window ("Night studio").
//
//   swift Apps/Mac/DMG/generate-background.swift [output folder]
//
// Writes background.png (660x400, 72 dpi) and background@2x.png (1320x800,
// 144 dpi) next to this script, or into the folder given. Both are drawn from
// the same vector description at their own resolution (the @2x is never an
// upscale). The output is deterministic: no randomness without a fixed seed,
// and Core Image runs on its software renderer.
//
// Layout contract (points, origin top-left, 660x400 canvas):
//   - Finder draws the Transcribe icon (128 pt) centred at (165, 185) and the
//     Applications folder (128 pt) centred at (495, 185).
//   - Its 13 pt labels sit just below, roughly y 263-276. Over a background
//     picture Finder draws them in near-black (about #303131) with no backing,
//     in light and dark appearance alike (measured on macOS 27), so each label
//     sits on a light silver glass pill: about 6.5:1 for that text.
//   - Nothing busy is drawn inside the icon squares or the label strips.

import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Layout

let canvas = CGSize(width: 660, height: 400)
let appCentre = CGPoint(x: 165, y: 185)
let folderCentre = CGPoint(x: 495, y: 185)
let labelCentreY: CGFloat = 265

/// Glass plate behind each icon and its label.
func plateRect(_ c: CGPoint) -> CGRect {
    CGRect(x: c.x - 86, y: c.y - 92, width: 172, height: 204)
}

/// Label pill: wide enough for "Applications" in 13 pt with room to spare.
func pillRect(_ c: CGPoint) -> CGRect {
    CGRect(x: c.x - 64, y: labelCentreY - 13.5, width: 128, height: 27)
}

// MARK: - Colour

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [
        CGFloat((hex >> 16) & 0xFF) / 255,
        CGFloat((hex >> 8) & 0xFF) / 255,
        CGFloat(hex & 0xFF) / 255,
        a,
    ])!
}

func white(_ a: CGFloat) -> CGColor { rgb(0xFFFFFF, a) }

// Design tokens (CLAUDE.md), and brighter "phosphor" versions of the speaker
// colours for light that glows on a dark ground.
let ink: UInt32 = 0x0E1116
let accent: UInt32 = 0x2457F5
let recordRed: UInt32 = 0xE5484D
let teal: UInt32 = 0x0E7C86, violet: UInt32 = 0x6741D9
let rose: UInt32 = 0xC2255C, amber: UInt32 = 0xB4530A
let glowTeal: UInt32 = 0x2CC6CF
let glowViolet: UInt32 = 0x8F6BFF
let glowRose: UInt32 = 0xFF4F8B
let glowAmber: UInt32 = 0xFF9A3D
let glowBlue: UInt32 = 0x5C86FF

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB,
               colors: stops.map { $0.1 } as CFArray,
               locations: stops.map { $0.0 })!
}

// MARK: - Drawing helpers

/// A bitmap context with a top-left origin measured in points.
/// The final canvas is opaque (the PNGs carry no alpha); glow layers are not.
func makeContext(scale: CGFloat, opaque: Bool = false) -> CGContext {
    let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
    let ctx = CGContext(data: nil,
                        width: Int(canvas.width * scale),
                        height: Int(canvas.height * scale),
                        bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: alpha.rawValue)!
    ctx.translateBy(x: 0, y: canvas.height * scale)
    ctx.scaleBy(x: scale, y: -scale)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    return ctx
}

/// Draws a full-canvas image (made by `makeContext`) into a flipped context.
func drawLayer(_ image: CGImage, into ctx: CGContext,
               blend: CGBlendMode = .normal, alpha: CGFloat = 1) {
    ctx.saveGState()
    ctx.setBlendMode(blend)
    ctx.setAlpha(alpha)
    ctx.translateBy(x: 0, y: canvas.height)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(origin: .zero, size: canvas))
    ctx.restoreGState()
}

let ciContext = CIContext(options: [
    .useSoftwareRenderer: true,
    .workingColorSpace: sRGB,
    .outputColorSpace: sRGB,
])

func blurred(_ image: CGImage, radius points: CGFloat, scale: CGFloat) -> CGImage {
    let input = CIImage(cgImage: image)
    let out = input.clampedToExtent()
        .applyingGaussianBlur(sigma: Double(points * scale))
        .cropped(to: input.extent)
    return ciContext.createCGImage(out, from: input.extent,
                                   format: .RGBA8, colorSpace: sRGB)!
}

/// Renders `draw` into its own layer, blurs it and adds it as light.
func glow(_ ctx: CGContext, scale: CGFloat, radius: CGFloat, alpha: CGFloat,
          _ draw: (CGContext) -> Void) {
    let layer = makeContext(scale: scale)
    draw(layer)
    let img = blurred(layer.makeImage()!, radius: radius, scale: scale)
    drawLayer(img, into: ctx, blend: .plusLighter, alpha: alpha)
}

func radial(_ ctx: CGContext, at c: CGPoint, radius: CGFloat,
            _ color: UInt32, _ a: CGFloat, squash: CGFloat = 1) {
    ctx.saveGState()
    ctx.translateBy(x: c.x, y: c.y)
    ctx.scaleBy(x: 1, y: squash)
    ctx.drawRadialGradient(
        gradient([(0, rgb(color, a)), (0.45, rgb(color, a * 0.42)), (1, rgb(color, 0))]),
        startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius,
        options: [])
    ctx.restoreGState()
}

func systemFont(size: CGFloat, weight: CGFloat, monospacedDigits: Bool = false) -> CTFont {
    let base = CTFontCreateUIFontForLanguage(.system, size, nil)!
    var attrs: [CFString: Any] = [
        kCTFontTraitsAttribute: [kCTFontWeightTrait: weight],
    ]
    if monospacedDigits {
        attrs[kCTFontFeatureSettingsAttribute] = [[
            kCTFontFeatureTypeIdentifierKey: 6, // kNumberSpacingType
            kCTFontFeatureSelectorIdentifierKey: 0, // kMonospacedNumbersSelector
        ]]
    }
    let desc = CTFontDescriptorCreateCopyWithAttributes(
        CTFontCopyFontDescriptor(base), attrs as CFDictionary)
    return CTFontCreateWithFontDescriptor(desc, size, nil)
}

/// Draws one line of text centred on `centre` (its cap height centred on y).
func text(_ ctx: CGContext, _ string: String, font: CTFont, color: CGColor,
          centre: CGPoint, kern: CGFloat = 0, align: CGFloat = 0.5) {
    let attr = NSAttributedString(string: string, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        NSAttributedString.Key(kCTKernAttributeName as String): kern,
    ])
    let line = CTLineCreateWithAttributedString(attr)
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    let cap = CTFontGetCapHeight(font)
    ctx.saveGState()
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = CGPoint(x: centre.x - CGFloat(width) * align, y: centre.y + cap / 2)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

// MARK: - Deterministic noise

struct XorShift {
    var state: UInt64
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

// MARK: - The trace

/// The signal path: a quadratic arc leaving the Transcribe plate and landing on
/// the Applications plate, with a speech-like burst riding on it.
struct Trace {
    let p0 = CGPoint(x: 254, y: 187)
    let c = CGPoint(x: 328, y: 130)
    let p1 = CGPoint(x: 399, y: 185)

    func base(_ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * p0.x + 2 * u * t * c.x + t * t * p1.x,
                       y: u * u * p0.y + 2 * u * t * c.y + t * t * p1.y)
    }

    func tangent(_ t: CGFloat) -> CGPoint {
        let dx = 2 * (1 - t) * (c.x - p0.x) + 2 * t * (p1.x - c.x)
        let dy = 2 * (1 - t) * (c.y - p0.y) + 2 * t * (p1.y - c.y)
        let l = (dx * dx + dy * dy).squareRoot()
        return CGPoint(x: dx / l, y: dy / l)
    }

    /// Burst envelope: quiet at both ends, the signal in between.
    func envelope(_ t: CGFloat) -> CGFloat {
        func smooth(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
            let k = min(max((x - a) / (b - a), 0), 1)
            return k * k * (3 - 2 * k)
        }
        return smooth(0.06, 0.34, t) * (1 - smooth(0.52, 0.80, t))
    }

    /// Path with the waveform added along the normal. `phase` and `gain` make
    /// the fainter persistence echoes.
    func path(amplitude: CGFloat, phase: CGFloat = 0, gain: CGFloat = 1,
              from t0: CGFloat = 0, to t1: CGFloat = 1) -> CGPath {
        let p = CGMutablePath()
        let steps = 900
        for i in 0...steps {
            let t = t0 + (t1 - t0) * CGFloat(i) / CGFloat(steps)
            let s = t * 190 // roughly arc length in points
            let w = 0.62 * sin(2 * .pi * s / 17 + phase)
                + 0.28 * sin(2 * .pi * s / 8.3 + 1.3 + phase * 1.7)
                + 0.10 * sin(2 * .pi * s / 4.6 + 0.4 - phase)
            let a = amplitude * gain * envelope(t) * w
            let b = base(t), tg = tangent(t)
            let pt = CGPoint(x: b.x - tg.y * a, y: b.y + tg.x * a)
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        return p
    }

    /// Open chevron at the end of the trace, pointing along the tangent.
    func arrowhead(size: CGFloat) -> CGPath {
        let tip = base(1), tg = tangent(1)
        let back = CGPoint(x: -tg.x * size, y: -tg.y * size)
        let side = CGPoint(x: -tg.y * size * 0.62, y: tg.x * size * 0.62)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: tip.x + back.x + side.x, y: tip.y + back.y + side.y))
        p.addLine(to: tip)
        p.addLine(to: CGPoint(x: tip.x + back.x - side.x, y: tip.y + back.y - side.y))
        return p
    }

    var colours: CGGradient {
        gradient([
            (0.00, rgb(glowTeal)), (0.30, rgb(glowTeal)),
            (0.45, rgb(glowViolet)), (0.60, rgb(glowRose)),
            (0.74, rgb(glowAmber)), (0.90, rgb(glowBlue)), (1.0, rgb(glowBlue)),
        ])
    }

    var gradientStart: CGPoint { CGPoint(x: p0.x - 4, y: 0) }
    var gradientEnd: CGPoint { CGPoint(x: p1.x + 4, y: 0) }

    /// Strokes `path` filled with the speaker-colour gradient.
    func strokeColoured(_ ctx: CGContext, _ path: CGPath, width: CGFloat, alpha: CGFloat = 1) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.addPath(path)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(colours, start: gradientStart, end: gradientEnd,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
}

// MARK: - Scene

func drawGround(_ ctx: CGContext) {
    // Deep ink into a blue-black.
    ctx.drawLinearGradient(
        gradient([(0, rgb(0x121826)), (0.55, rgb(ink)), (1, rgb(0x080A0F))]),
        start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: canvas.height), options: [])
    // Atmosphere: soft pools of light in the speaker colours.
    radial(ctx, at: CGPoint(x: 330, y: 150), radius: 260, 0x1C2A55, 0.55, squash: 0.62)
    radial(ctx, at: CGPoint(x: 150, y: 210), radius: 190, teal, 0.20, squash: 0.85)
    radial(ctx, at: CGPoint(x: 510, y: 200), radius: 190, accent, 0.17, squash: 0.85)
    radial(ctx, at: CGPoint(x: 330, y: 120), radius: 120, violet, 0.12, squash: 0.7)
}

/// Oscilloscope graticule, fading out towards the edges.
func drawGraticule(_ ctx: CGContext) {
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    let step: CGFloat = 22
    let origin = CGPoint(x: 330, y: 185)
    ctx.setLineWidth(0.5)
    var x = origin.x.truncatingRemainder(dividingBy: step)
    while x <= canvas.width {
        let major = abs((x - origin.x).truncatingRemainder(dividingBy: step * 5)) < 0.01
        ctx.setStrokeColor(white(major ? 0.075 : 0.04))
        ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: canvas.height))
        ctx.strokePath()
        x += step
    }
    var y = origin.y.truncatingRemainder(dividingBy: step)
    while y <= canvas.height {
        let major = abs((y - origin.y).truncatingRemainder(dividingBy: step * 5)) < 0.01
        ctx.setStrokeColor(white(major ? 0.075 : 0.04))
        ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: canvas.width, y: y))
        ctx.strokePath()
        y += step
    }
    // Minor ticks on the centre axis, as on a scope.
    ctx.setStrokeColor(white(0.09))
    var tx = origin.x.truncatingRemainder(dividingBy: step / 5)
    while tx <= canvas.width {
        ctx.move(to: CGPoint(x: tx, y: origin.y - 1.6))
        ctx.addLine(to: CGPoint(x: tx, y: origin.y + 1.6))
        tx += step / 5
    }
    ctx.strokePath()
    // Fade: keep the graticule in the centre band, gone at the edges.
    ctx.setBlendMode(.destinationIn)
    ctx.saveGState()
    ctx.translateBy(x: origin.x, y: origin.y - 5)
    ctx.scaleBy(x: 1, y: 0.62)
    ctx.drawRadialGradient(
        gradient([(0, white(1)), (0.5, white(0.75)), (1, white(0))]),
        startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 360, options: [])
    ctx.restoreGState()
    ctx.endTransparencyLayer()
}

/// Frosted glass plate for an icon and its label.
func drawPlate(_ ctx: CGContext, scale: CGFloat, centre: CGPoint, tint: UInt32, spill: UInt32) {
    let r = plateRect(centre)
    let shape = CGPath(roundedRect: r, cornerWidth: 30, cornerHeight: 30, transform: nil)

    // Lift: a soft shadow below.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 14 * scale * -1), blur: 34 * scale,
                  color: rgb(0x000000, 0.55))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x10141C, 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Body: dark glass with a tint glowing through from behind.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(0x232A38)), (0.5, rgb(0x171C26)), (1, rgb(0x131720))]),
        start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.maxY), options: [])
    radial(ctx, at: CGPoint(x: centre.x, y: centre.y - 4), radius: 120, tint, 0.20, squash: 0.95)
    // Frost: a faint diagonal sheen.
    ctx.drawLinearGradient(
        gradient([(0, white(0.07)), (0.42, white(0.015)), (0.6, white(0)), (1, white(0.025))]),
        start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
    ctx.restoreGState()

    // Rim: bright along the top, fading down the sides (light from above).
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 29.5,
                       cornerHeight: 29.5, transform: nil))
    ctx.setLineWidth(1)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, white(0.34)), (0.18, white(0.12)), (0.7, white(0.05)), (1, white(0.10))]),
        start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.maxY), options: [])
    ctx.restoreGState()

    // Light spill from the trace on the facing edge.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 29.5,
                       cornerHeight: 29.5, transform: nil))
    ctx.setLineWidth(1.2)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let facing = CGPoint(x: centre.x < canvas.width / 2 ? r.maxX : r.minX, y: centre.y - 8)
    radial(ctx, at: facing, radius: 64, spill, 0.75, squash: 1.2)
    ctx.restoreGState()

    // Specular arc just inside the top edge.
    ctx.saveGState()
    let hi = CGMutablePath()
    hi.move(to: CGPoint(x: r.minX + 34, y: r.minY + 1.6))
    hi.addLine(to: CGPoint(x: r.maxX - 34, y: r.minY + 1.6))
    ctx.addPath(hi)
    ctx.setLineWidth(1.2)
    ctx.setLineCap(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, white(0)), (0.5, white(0.32)), (1, white(0))]),
        start: CGPoint(x: r.minX + 34, y: 0), end: CGPoint(x: r.maxX - 34, y: 0), options: [])
    ctx.restoreGState()
}

/// Light silver glass pill behind a label (Finder's labels are always dark).
/// Relative luminance about 0.47: Finder's #303131 label text reads at about 6.5:1.
func drawPill(_ ctx: CGContext, centre: CGPoint) {
    let r = pillRect(centre)
    let shape = CGPath(roundedRect: r, cornerWidth: r.height / 2,
                       cornerHeight: r.height / 2, transform: nil)
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(0xC6CDDA)), (1, rgb(0xB2BACA))]),
        start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.maxY), options: [])
    ctx.restoreGState()
    // Hairline rim, brighter on top.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: r.height / 2 - 0.5,
                       cornerHeight: r.height / 2 - 0.5, transform: nil))
    ctx.setLineWidth(1)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, white(0.42)), (0.5, white(0.12)), (1, white(0.06))]),
        start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.maxY), options: [])
    ctx.restoreGState()
}

func drawTrace(_ ctx: CGContext, scale: CGFloat) {
    let trace = Trace()
    let main = trace.path(amplitude: 21)
    let echo1 = trace.path(amplitude: 21, phase: 0.9, gain: 0.8)
    let echo2 = trace.path(amplitude: 21, phase: -1.5, gain: 0.6)
    let arrow = trace.arrowhead(size: 10)

    // Wide bloom, then a tighter glow.
    glow(ctx, scale: scale, radius: 14, alpha: 0.55) { l in
        trace.strokeColoured(l, main, width: 7)
        trace.strokeColoured(l, arrow, width: 7)
    }
    glow(ctx, scale: scale, radius: 4, alpha: 0.9) { l in
        trace.strokeColoured(l, main, width: 3)
        trace.strokeColoured(l, arrow, width: 3)
        trace.strokeColoured(l, echo1, width: 1.4, alpha: 0.5)
    }
    // A faint reflection, as on a glossy desk.
    glow(ctx, scale: scale, radius: 2.5, alpha: 0.22) { l in
        l.saveGState()
        l.translateBy(x: 0, y: 2 * 196)
        l.scaleBy(x: 1, y: -1)
        trace.strokeColoured(l, main, width: 2.2)
        trace.strokeColoured(l, arrow, width: 2.2)
        l.restoreGState()
        l.setBlendMode(.destinationIn)
        l.drawLinearGradient(gradient([(0, white(1)), (1, white(0))]),
                             start: CGPoint(x: 0, y: 196), end: CGPoint(x: 0, y: 250),
                             options: [.drawsBeforeStartLocation])
    }
    // Phosphor persistence: earlier sweeps, fading.
    trace.strokeColoured(ctx, echo2, width: 0.8, alpha: 0.28)
    trace.strokeColoured(ctx, echo1, width: 0.9, alpha: 0.42)
    // The trace itself, with a white-hot core.
    trace.strokeColoured(ctx, main, width: 1.9)
    trace.strokeColoured(ctx, arrow, width: 2.1)
    ctx.saveGState()
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setStrokeColor(white(0.55))
    ctx.setLineWidth(0.7)
    ctx.addPath(main); ctx.addPath(arrow)
    ctx.strokePath()
    ctx.restoreGState()

    // Input node where the signal leaves the Transcribe plate.
    let start = trace.base(0)
    glow(ctx, scale: scale, radius: 5, alpha: 1) { l in
        l.setFillColor(rgb(glowTeal))
        l.fillEllipse(in: CGRect(x: start.x - 4, y: start.y - 4, width: 8, height: 8))
    }
    ctx.setFillColor(rgb(0xD8FBFF))
    ctx.fillEllipse(in: CGRect(x: start.x - 2.2, y: start.y - 2.2, width: 4.4, height: 4.4))
}

/// Recorder detail: a red record dot and a small stereo level meter.
func drawRecorderDetail(_ ctx: CGContext, scale: CGFloat) {
    let dot = CGPoint(x: 36, y: 36)
    glow(ctx, scale: scale, radius: 5, alpha: 0.9) { l in
        l.setFillColor(rgb(recordRed))
        l.fillEllipse(in: CGRect(x: dot.x - 5, y: dot.y - 5, width: 10, height: 10))
    }
    ctx.setFillColor(rgb(recordRed))
    ctx.fillEllipse(in: CGRect(x: dot.x - 4, y: dot.y - 4, width: 8, height: 8))
    ctx.setFillColor(white(0.35))
    ctx.fillEllipse(in: CGRect(x: dot.x - 2.2, y: dot.y - 2.6, width: 2.2, height: 1.6))

    // Two rows of segments; lit ones take the speaker colours, low to high.
    let lit = [13, 10]
    let palette: [UInt32] = [glowTeal, glowTeal, glowTeal, glowTeal, glowTeal, glowViolet,
                             glowViolet, glowViolet, glowViolet, glowRose, glowRose,
                             glowAmber, glowAmber, recordRed, recordRed, recordRed]
    for row in 0..<2 {
        for i in 0..<16 {
            let rect = CGRect(x: 52 + CGFloat(i) * 4.5, y: 32.5 + CGFloat(row) * 4.5,
                              width: 3, height: 2.5)
            if i < lit[row] {
                ctx.setFillColor(rgb(palette[i], 0.85))
            } else {
                ctx.setFillColor(white(0.08))
            }
            ctx.fill(rect)
        }
    }
}

/// Speaker chips, as in the app: named voices filled, an unnamed one dashed.
func drawSpeakerChips(_ ctx: CGContext, scale: CGFloat) {
    let y: CGFloat = 36
    let named: [UInt32] = [teal, violet, rose]
    let xs: [CGFloat] = [588, 600, 612]
    glow(ctx, scale: scale, radius: 4, alpha: 0.7) { l in
        for (x, c) in zip(xs, [glowTeal, glowViolet, glowRose]) {
            l.setFillColor(rgb(c, 0.8))
            l.fillEllipse(in: CGRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7))
        }
    }
    for (x, c) in zip(xs, named) {
        ctx.setFillColor(rgb(c))
        ctx.fillEllipse(in: CGRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7))
        ctx.setStrokeColor(white(0.25))
        ctx.setLineWidth(0.5)
        ctx.strokeEllipse(in: CGRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7))
    }
    ctx.saveGState()
    ctx.setStrokeColor(rgb(glowAmber, 0.9))
    ctx.setLineWidth(1)
    ctx.setLineDash(phase: 0, lengths: [1.6, 1.3])
    ctx.strokeEllipse(in: CGRect(x: 624 - 3, y: y - 3, width: 6, height: 6))
    ctx.restoreGState()
}

/// Viewfinder corner marks.
func drawCorners(_ ctx: CGContext) {
    ctx.saveGState()
    ctx.setStrokeColor(white(0.16))
    ctx.setLineWidth(1)
    ctx.setLineCap(.square)
    let inset: CGFloat = 18, len: CGFloat = 12
    let w = canvas.width, h = canvas.height
    let corners: [(CGPoint, CGFloat, CGFloat)] = [
        (CGPoint(x: inset, y: inset), 1, 1), (CGPoint(x: w - inset, y: inset), -1, 1),
        (CGPoint(x: inset, y: h - inset), 1, -1), (CGPoint(x: w - inset, y: h - inset), -1, -1),
    ]
    for (p, sx, sy) in corners {
        ctx.move(to: CGPoint(x: p.x, y: p.y + sy * len))
        ctx.addLine(to: p)
        ctx.addLine(to: CGPoint(x: p.x + sx * len, y: p.y))
    }
    ctx.strokePath()
    ctx.restoreGState()
}

func drawCopy(_ ctx: CGContext) {
    text(ctx, "Drag Transcribe to Applications",
         font: systemFont(size: 17, weight: 0.3), color: white(0.92),
         centre: CGPoint(x: 330, y: 60), kern: 0.1)
    text(ctx, "Speech is processed on your Mac",
         font: systemFont(size: 11, weight: 0.0), color: white(0.46),
         centre: CGPoint(x: 330, y: 352), kern: 0.2)
}

/// Monochrome film grain, from a fixed seed.
func addGrain(_ ctx: CGContext, scale: CGFloat) {
    guard let data = ctx.data else { return }
    let w = ctx.width, h = ctx.height, row = ctx.bytesPerRow
    let px = data.bindMemory(to: UInt8.self, capacity: row * h)
    var rng = XorShift(state: 0x7A5C_0FFE_E15D_2026)
    let amount = 7.0 / scale.squareRoot()
    for y in 0..<h {
        for x in 0..<w {
            let n = Int(((rng.unit() + rng.unit()) - 1) * amount)
            let o = y * row + x * 4
            for c in 0..<3 {
                px[o + c] = UInt8(clamping: Int(px[o + c]) + n)
            }
        }
    }
}

func render(scale: CGFloat) -> CGImage {
    let ctx = makeContext(scale: scale, opaque: true)
    drawGround(ctx)
    drawGraticule(ctx)
    drawCorners(ctx)
    drawPlate(ctx, scale: scale, centre: appCentre, tint: teal, spill: glowTeal)
    drawPlate(ctx, scale: scale, centre: folderCentre, tint: accent, spill: glowBlue)
    drawTrace(ctx, scale: scale)
    drawPill(ctx, centre: appCentre)
    drawPill(ctx, centre: folderCentre)
    drawRecorderDetail(ctx, scale: scale)
    drawSpeakerChips(ctx, scale: scale)
    drawCopy(ctx)
    addGrain(ctx, scale: scale)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL, dpi: CGFloat) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, [
        kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
    ] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write("could not write \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
    print(url.path)
}

let outDir: URL = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    : URL(fileURLWithPath: #filePath).deletingLastPathComponent()
writePNG(render(scale: 1), to: outDir.appendingPathComponent("background.png"), dpi: 72)
writePNG(render(scale: 2), to: outDir.appendingPathComponent("background@2x.png"), dpi: 144)
