import AppKit
import ImageIO

// Resample the approved transparent artwork into native menu bar assets.
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let sourceURL = root.appendingPathComponent("Assets/Icon/Artwork/menu-bar-source.png")
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                              bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let data = context.data?.assumingMemoryBound(to: UInt8.self) else {
    fatalError("Cannot decode transparent artwork at \(sourceURL.path)")
}
context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
var minX = image.width, minY = image.height, maxX = 0, maxY = 0
for y in 0..<image.height {
    for x in 0..<image.width where data[(y * image.width + x) * 4 + 3] > 12 {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX > minX, maxY > minY else { fatalError("No visible artwork in \(sourceURL.path)") }
let bounds = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
guard let cropped = image.cropping(to: bounds) else { fatalError("Cannot crop artwork at \(sourceURL.path)") }
let destination = root.appendingPathComponent("Assets/MenuBar.xcassets/MenuBarIcon.imageset")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for scale in [1, 2] {
    let pixels = 18 * scale
    let canvas = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                           bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    canvas.interpolationQuality = .high
    let factor = CGFloat(17 * scale) / max(bounds.width, bounds.height)
    let size = CGSize(width: bounds.width * factor, height: bounds.height * factor)
    let frame = CGRect(x: (CGFloat(pixels) - size.width) / 2, y: (CGFloat(pixels) - size.height) / 2,
                       width: size.width, height: size.height)
    canvas.draw(cropped, in: frame)
    // Template rendering uses only alpha; keep the stored pigment uniformly black.
    canvas.setBlendMode(.sourceIn)
    canvas.setFillColor(NSColor.black.cgColor)
    canvas.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let bitmap = NSBitmapImageRep(cgImage: canvas.makeImage()!)
    let name = scale == 1 ? "MenuBarIcon.png" : "MenuBarIcon@2x.png"
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode \(name)") }
    try png.write(to: destination.appendingPathComponent(name))
    print("\(name): \(pixels) x \(pixels)")
}
print("Source bounds: \(bounds)")
