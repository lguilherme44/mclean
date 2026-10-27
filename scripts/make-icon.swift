// Generates Resources/AppIcon.icns: a storage ring (the disk) with one segment lifted out in light
// (the space mclean frees), on the same blue ramp the Space Lens map uses.
// Usage: swift scripts/make-icon.swift <output-dir>
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let iconset = (output as NSString).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(atPath: iconset)
try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body with a soft shadow.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.225
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(shape)
    ctx.setFillColor(color(0x0D366B).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [color(0x2A78D6).cgColor, color(0x0D366B).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY), options: [])
    ctx.restoreGState()

    // The disk: a thick ring, mostly "used" (muted), with one bright freed segment pulled outward.
    let center = CGPoint(x: body.midX, y: body.midY)
    let r = body.width * 0.30
    let w = body.width * 0.13
    ctx.setLineCap(.butt)
    ctx.setLineWidth(w)
    ctx.setStrokeColor(color(0xFFFFFF, 0.28).cgColor)
    let gap: CGFloat = 0.06
    let freedStart: CGFloat = .pi * 0.15, freedEnd: CGFloat = .pi * 0.65
    ctx.addArc(center: center, radius: r, startAngle: freedEnd + gap, endAngle: freedStart - gap + 2 * .pi, clockwise: false)
    ctx.strokePath()

    let lift = body.width * 0.035
    let mid = (freedStart + freedEnd) / 2
    let offset = CGPoint(x: center.x + cos(mid) * lift, y: center.y + sin(mid) * lift)
    ctx.setStrokeColor(color(0xFFFFFF).cgColor)
    ctx.addArc(center: offset, radius: r, startAngle: freedStart, endAngle: freedEnd, clockwise: false)
    ctx.strokePath()

    // Hub.
    let hub = body.width * 0.055
    ctx.setFillColor(color(0xB7D3F6).cgColor)
    ctx.fillEllipse(in: CGRect(x: center.x - hub, y: center.y - hub, width: 2 * hub, height: 2 * hub))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base).png"))
    try render(base * 2).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base)@2x.png"))
}
try render(1024).write(to: URL(fileURLWithPath: (output as NSString).appendingPathComponent("AppIcon-1024.png")))
print(iconset)
