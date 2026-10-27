// Puts the icon's background gradient behind a PNG's transparent pixels, in place.
// Run: xcrun swift scripts/flatten-icon.swift <file.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let space = CGColorSpace(name: CGColorSpace.displayP3),
      let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(1) }
let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
let colors = [CGColor(colorSpace: space, components: [0.20, 0.56, 1.00, 1])!, CGColor(colorSpace: space, components: [0.03, 0.18, 0.58, 1])!]
let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.height), end: .zero, options: [])
context.draw(image, in: rect)
guard let flat = context.makeImage(),
      let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, flat, nil)
exit(CGImageDestinationFinalize(dest) ? 0 : 1)
