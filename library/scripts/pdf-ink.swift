// Draws ink over every page of a PDF and writes a new PDF; the original pages stay vector (text selectable).
// Built on first use by lib/pdf-ink.mjs: xcrun swiftc -O scripts/pdf-ink.swift -o bin/pdf-ink
// Usage: pdf-ink <in.pdf> <out.pdf> <strokes.json>
// strokes.json: {"pages": {"<1-based page>": [{"tool", "color": "#rrggbb", "kind"?, "width", "points": [[x, y, pressure]]}]}}
// Lengths are in page widths from the page's top-left corner as shown (after rotation), so they match the PNGs of pdf-pages.
import CoreGraphics
import Foundation

struct Stroke: Decodable {
  let tool: String
  let color: String
  let kind: String?
  let width: Double
  let points: [[Double]]
}

struct Input: Decodable {
  let pages: [String: [Stroke]]
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
  exit(1)
}

let args = CommandLine.arguments
guard args.count >= 4 else {
  FileHandle.standardError.write("usage: pdf-ink <in.pdf> <out.pdf> <strokes.json>\n".data(using: .utf8)!)
  exit(2)
}
guard let doc = CGPDFDocument(URL(fileURLWithPath: args[1]) as CFURL) else { fail("cannot open PDF") }
let input: Input
do {
  input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
} catch {
  fail("bad strokes: \(error)")
}
guard let ctx = CGContext(URL(fileURLWithPath: args[2]) as CFURL, mediaBox: nil, nil) else { fail("cannot write PDF") }

func color(_ hex: String, alpha: Double) -> CGColor {
  let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
  return CGColor(srgbRed: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255, alpha: alpha)
}

// Same pen shapes as client/overlay.js penWidth: gel follows pressure, ballpoint is even, fountain is a 45° broad nib.
func penWidth(_ s: Stroke, _ a: [Double], _ b: [Double]) -> Double {
  let pressure = (a[2] + b[2]) / 2
  switch s.kind {
  case "ballpoint": return s.width * 0.85
  case "fountain":
    let angle = atan2(b[1] - a[1], b[0] - a[0])
    return s.width * (0.3 + 1.2 * abs(sin(angle - .pi / 4))) * (0.6 + 0.8 * pressure)
  default: return s.width * (0.5 + pressure)
  }
}

func point(_ p: [Double]) -> CGPoint { CGPoint(x: p[0], y: p[1]) }
func mid(_ a: [Double], _ b: [Double]) -> CGPoint { CGPoint(x: (a[0] + b[0]) / 2, y: (a[1] + b[1]) / 2) }

func draw(_ s: Stroke) {
  let pts = s.points.filter { $0.count >= 3 }
  guard !pts.isEmpty else { return }
  ctx.setLineCap(.round)
  ctx.setLineJoin(.round)
  if s.tool == "highlighter" {
    ctx.setStrokeColor(color(s.color, alpha: 0.35))
    ctx.setLineWidth(s.width)
    ctx.move(to: point(pts[0]))
    for p in pts.dropFirst() { ctx.addLine(to: point(p)) }
    if pts.count == 1 { ctx.addLine(to: CGPoint(x: pts[0][0] + 0.0001, y: pts[0][1])) }
    ctx.strokePath()
    return
  }
  ctx.setStrokeColor(color(s.color, alpha: 1))
  if pts.count == 1 {
    let r = s.width * (0.5 + pts[0][2]) / 2
    ctx.setFillColor(color(s.color, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: pts[0][0] - r, y: pts[0][1] - r, width: 2 * r, height: 2 * r))
    return
  }
  // Quadratic segments through midpoints, each with its own width, as the page draws them.
  for i in 1..<pts.count {
    let p0 = i >= 2 ? pts[i - 2] : pts[i - 1]
    ctx.setLineWidth(penWidth(s, pts[i - 1], pts[i]))
    ctx.move(to: mid(p0, pts[i - 1]))
    ctx.addQuadCurve(to: mid(pts[i - 1], pts[i]), control: point(pts[i - 1]))
    ctx.strokePath()
  }
  ctx.move(to: mid(pts[pts.count - 2], pts[pts.count - 1]))
  ctx.addLine(to: point(pts[pts.count - 1]))
  ctx.strokePath()
}

for index in 1...max(doc.numberOfPages, 1) {
  guard let page = doc.page(at: index) else { continue }
  let box = page.getBoxRect(.cropBox)
  let quarterTurns = ((Int(page.rotationAngle) % 360) + 360) % 360 / 90
  let size = quarterTurns % 2 == 0 ? box.size : CGSize(width: box.height, height: box.width)
  var media = CGRect(origin: .zero, size: size)
  ctx.beginPage(mediaBox: &media)
  ctx.saveGState()
  ctx.concatenate(page.getDrawingTransform(.cropBox, rect: media, rotate: 0, preserveAspectRatio: true))
  ctx.drawPDFPage(page)
  ctx.restoreGState()
  if let strokes = input.pages[String(index)], !strokes.isEmpty {
    ctx.saveGState()
    ctx.clip(to: media)
    // Top-left origin, one unit per page width.
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: size.width, y: -size.width)
    strokes.forEach(draw)
    ctx.restoreGState()
  }
  ctx.endPage()
}
ctx.closePDF()
