// Renders every page of a PDF to PNG at a fixed width and prints the page sizes as JSON.
// Built on first use by lib/convert.mjs: xcrun swiftc -O scripts/pdf-pages.swift -o bin/pdf-pages
// Usage: pdf-pages <in.pdf> <out-dir> [width]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else {
  FileHandle.standardError.write("usage: pdf-pages <in.pdf> <out-dir> [width]\n".data(using: .utf8)!)
  exit(2)
}
let input = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
let targetWidth = args.count > 3 ? Double(args[3]) ?? 1600 : 1600

guard let doc = CGPDFDocument(input as CFURL) else {
  FileHandle.standardError.write("cannot open PDF\n".data(using: .utf8)!)
  exit(1)
}
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
var sizes: [[Int]] = []

for index in 1...max(doc.numberOfPages, 1) {
  guard let page = doc.page(at: index) else { continue }
  let box = page.getBoxRect(.cropBox)
  let quarterTurns = ((Int(page.rotationAngle) % 360) + 360) % 360 / 90
  let size = quarterTurns % 2 == 0 ? box.size : CGSize(width: box.height, height: box.width)
  let scale = targetWidth / size.width
  let width = Int((size.width * scale).rounded())
  let height = Int((size.height * scale).rounded())
  guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
  ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
  ctx.interpolationQuality = .high
  // Scale first, then let the page's own transform handle rotation and the crop-box origin at 1:1,
  // because getDrawingTransform never scales up.
  ctx.scaleBy(x: scale, y: scale)
  ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
  ctx.drawPDFPage(page)
  guard let image = ctx.makeImage() else { continue }
  let file = outDir.appendingPathComponent(String(format: "%03d.png", index))
  guard let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
  CGImageDestinationAddImage(dest, image, nil)
  CGImageDestinationFinalize(dest)
  sizes.append([width, height])
}

let json = try JSONSerialization.data(withJSONObject: sizes)
print(String(data: json, encoding: .utf8)!)
