// Renders the default 1024px app icon. Compiled together with IconRenderer.swift by make-icns.sh.
import AppKit

@main
enum MakeIcon {
    static func main() {
        let args = CommandLine.arguments
        guard let mask = IconRenderer.loadMask(at: URL(fileURLWithPath: args[1])),
              let image = IconRenderer.render(baseHex: IconRenderer.defaultHex, mask: mask) else { exit(1) }
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        try! data.write(to: URL(fileURLWithPath: args[2]))
    }
}
