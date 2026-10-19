// Draws the app icons into AppIcon.appiconset: the cucumber slice lying on
// NEO's ground -- the lavender and grid the site draws behind every page
// (ds.css in oeee-cafe/web), ten cells across, with a soft shadow under the
// slice. The same icon the Android and desktop apps have.
//
//   swift scripts/app-icon/make_app_icons.swift
//
//   light.png  iOS, by day: the site's light ground, full bleed and opaque
//   dark.png   iOS, by night: the slice alone on transparency, on the dark
//              ground iOS draws behind it, which sits better among the other
//              dark icons than the site's night grid did
//   mac.png    the light icon on Apple's macOS template: an 824 squircle on
//              the 1024 canvas, with the shadow under it
//
// grayscale.png, the tinted appearance, is left alone: iOS draws the tinted
// ground itself. slice.png beside this script is the slice on transparency,
// padding and all, which leaves it about 70% across when drawn the icon's size.
import AppKit
import CoreGraphics

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconset = here.appendingPathComponent("../../OeeeCafe/Assets.xcassets/AppIcon.appiconset")
    .standardizedFileURL

let size = 1024.0
let cells = 10.0
let lineWeight = 0.07  // of a cell, the site's 1px in 14

struct Theme {
    let ground: UInt32
    let grid: UInt32
    let shadow: UInt32
    let shadowOpacity: Double
}
let light = Theme(ground: 0xccccff, grid: 0xbbbbff, shadow: 0x1c2811, shadowOpacity: 0.34)
// By night only the shadow is ours; the ground is the system's.
let darkShadow = (color: UInt32(0x000000), opacity: 0.6)

func color(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
    CGColor(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255, alpha: alpha)
}

// A superellipse (n = 5) approximates the continuous corner.
func squircle(in rect: CGRect, n: Double = 5.0) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * Double.pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * copysign(pow(abs(c), 2 / n), c)
        let y = rect.midY + b * copysign(pow(abs(s), 2 / n), s)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

let sliceSource = CGImageSourceCreateWithURL(here.appendingPathComponent("slice.png") as CFURL, nil)!
let slice = CGImageSourceCreateImageAtIndex(sliceSource, 0, nil)!
let space = CGColorSpace(name: CGColorSpace.sRGB)!

// The ground and its grid over `rect`, lines on the cell boundaries so the
// grid is symmetric about the centre, and the slice on it the rect's size.
func drawGround(_ ctx: CGContext, _ rect: CGRect, _ theme: Theme) {
    ctx.setFillColor(color(theme.ground))
    ctx.fill(rect)
    ctx.setFillColor(color(theme.grid))
    let cell = rect.width / cells
    let line = cell * lineWeight
    for k in 1..<Int(cells) {
        let p = Double(k) * cell - line / 2
        ctx.fill(CGRect(x: rect.minX + p, y: rect.minY, width: line, height: rect.height))
        ctx.fill(CGRect(x: rect.minX, y: rect.minY + p, width: rect.width, height: line))
    }
}

func drawSlice(_ ctx: CGContext, _ rect: CGRect, shadow: UInt32, opacity: Double) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -rect.width * 0.024),
                  blur: rect.width * 0.048, color: color(shadow, opacity))
    ctx.interpolationQuality = .high
    ctx.draw(slice, in: rect)
    ctx.restoreGState()
}

func write(_ ctx: CGContext, _ name: String) {
    let url = iconset.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("Couldn't write \(url.path)") }
    print("wrote \(url.path)")
}

// iOS: full bleed, the system rounds the corners. The light icon is opaque,
// as App Store Connect wants it; the dark one is transparent, as Apple asks
// of a dark icon so the system can draw its own ground.
do {
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    drawGround(ctx, rect, light)
    drawSlice(ctx, rect, shadow: light.shadow, opacity: light.shadowOpacity)
    write(ctx, "light.png")
}
do {
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    drawSlice(ctx, rect, shadow: darkShadow.color, opacity: darkShadow.opacity)
    write(ctx, "dark.png")
}

// Mac: the squircle, the shadow a light tile needs to be seen against a
// white Finder window, and a hairline of light just inside its edge.
do {
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let body = 824.0
    let rect = CGRect(x: (size - body) / 2, y: (size - body) / 2, width: body, height: body)
    let shape = squircle(in: rect)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: color(0x000000, 0.3))
    ctx.addPath(shape)
    ctx.setFillColor(color(light.ground))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    drawGround(ctx, rect, light)
    ctx.addPath(shape)
    ctx.setStrokeColor(color(0xffffff, 0.35))
    ctx.setLineWidth(4)
    ctx.strokePath()
    drawSlice(ctx, rect, shadow: light.shadow, opacity: light.shadowOpacity)
    ctx.restoreGState()
    write(ctx, "mac.png")
}
