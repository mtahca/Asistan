import Cocoa
let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    let n = CGFloat(size)
    NSColor(calibratedRed: 0.11, green: 0.34, blue: 0.88, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: n*0.05, y: n*0.05, width: n*0.9, height: n*0.9), xRadius: n*0.20, yRadius: n*0.20).fill()
    if let image = NSImage(systemSymbolName: "phone.fill", accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white])) {
        image.draw(in: NSRect(x: n*0.23, y: n*0.29, width: n*0.54, height: n*0.54))
    }
    let label = "β" as NSString
    label.draw(at: NSPoint(x: n*0.65, y: n*0.13), withAttributes: [.font: NSFont.boldSystemFont(ofSize: n*0.23), .foregroundColor: NSColor.white])
    NSGraphicsContext.restoreGraphicsState()
    let png = bitmap.representation(using: .png, properties: [:])!
    let names: [String]
    switch size {
    case 16: names = ["icon_16x16.png"]
    case 32: names = ["icon_16x16@2x.png", "icon_32x32.png"]
    case 64: names = ["icon_32x32@2x.png"]
    case 128: names = ["icon_128x128.png"]
    case 256: names = ["icon_128x128@2x.png", "icon_256x256.png"]
    case 512: names = ["icon_256x256@2x.png", "icon_512x512.png"]
    default: names = ["icon_512x512@2x.png"]
    }
    for name in names { try png.write(to: URL(fileURLWithPath: destination).appendingPathComponent(name)) }
}
