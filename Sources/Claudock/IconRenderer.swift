import AppKit

/// Draws the app icon (two bursts on a tile) in any base colour. Also used by Scripts/make-icns.sh.
enum IconRenderer {
    static let defaultHex = "#1E4FD0"
    static let colorKey = "iconColor"

    static func render(baseHex: String, mask: CGImage, size: Int = 1024) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

        let base = components(baseHex)
        let luminance = 0.2126 * base[0] + 0.7152 * base[1] + 0.0722 * base[2]
        let isLight = luminance > 0.6
        func shade(_ amount: CGFloat, alpha: CGFloat = 1) -> CGColor {
            CGColor(colorSpace: space, components: base.map { $0 * (1 - amount) } + [alpha])!
        }
        // Light tiles get dark bursts so the mark stays visible.
        func mark(_ alpha: CGFloat) -> CGColor {
            isLight ? shade(0.72, alpha: alpha) : CGColor(colorSpace: space, components: [1, 1, 1, alpha])!
        }

        let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: CGColor(gray: 0, alpha: 0.3))
        ctx.addPath(tile)
        ctx.setFillColor(shade(isLight ? 0.1 : 0.55))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(tile)
        ctx.clip()
        let gradient = CGGradient(colorsSpace: space, colors: [shade(0), shade(isLight ? 0.1 : 0.55)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

        burst(ctx, mask, center: CGPoint(x: 420, y: 600), size: 420, rotation: 24, color: mark(0.45), shadow: false)
        burst(ctx, mask, center: CGPoint(x: 590, y: 450), size: 460, rotation: 0, color: mark(1), shadow: !isLight)
        ctx.restoreGState()
        return ctx.makeImage()
    }

    private static func burst(_ ctx: CGContext, _ mask: CGImage, center: CGPoint, size: CGFloat, rotation: CGFloat, color: CGColor, shadow: Bool) {
        // The burst fills the middle 62% of the mask image.
        let full = size / 0.62
        let rect = CGRect(x: -full / 2, y: -full / 2, width: full, height: full)
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: rotation * .pi / 180)
        if shadow { ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: CGColor(gray: 0, alpha: 0.25)) }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.clip(to: rect, mask: mask)
        ctx.setFillColor(color)
        ctx.fill(rect)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private static func components(_ hex: String) -> [CGFloat] {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x1E4FD0
        return [CGFloat((value >> 16) & 0xFF) / 255, CGFloat((value >> 8) & 0xFF) / 255, CGFloat(value & 0xFF) / 255]
    }

    static func loadMask(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static var currentHex: String {
        UserDefaults.standard.string(forKey: colorKey) ?? defaultHex
    }

    /// Recolours the Dock icon for the running app; the bundled icon is used again after quitting.
    static func applyToDock() {
        guard let url = Bundle.main.url(forResource: "BurstMask", withExtension: "png"),
              let mask = loadMask(at: url),
              let image = render(baseHex: currentHex, mask: mask) else { return }
        NSApp.applicationIconImage = NSImage(cgImage: image, size: NSSize(width: 1024, height: 1024))
    }
}
