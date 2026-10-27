import AppKit

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else { fatalError("FAIL: \(message)") }
}
func alpha(_ image: CGImage, x: Int, y: Int) -> UInt8 {
    let bytes = CFDataGetBytePtr(image.dataProvider!.data!)!
    return bytes[(image.height - 1 - y) * image.bytesPerRow + x * 4 + 3]
}
let size = NSSize(width: 100, height: 100)
var stroke = InkStroke(tool: .pen, color: InkColor(red: 0, green: 0, blue: 1), width: 4,
    points: [InkPoint(x: 0.1, y: 0.2), InkPoint(x: 0.5, y: 0.8), InkPoint(x: 0.9, y: 0.2)])
let store = InkBackingStore()
let first = store.image(strokes: [stroke], size: size, scale: 1)!
check(alpha(first, x: 0, y: 0) == 0, "backing is transparent outside ink")
check(alpha(first, x: 10, y: 20) > 0 && alpha(first, x: 90, y: 20) > 0, "curve preserves both input endpoints")
check(alpha(first, x: 50, y: 80) == 0, "sharp sampled corner is smoothed")
check(store.image(strokes: [stroke], size: size, scale: 1) === first, "pointer frames reuse committed ink image")
store.invalidate()
let cleared = store.image(strokes: [], size: size, scale: 1)!
check(alpha(cleared, x: 10, y: 20) == 0, "invalidation removes erased ink")
store.invalidate()
stroke.tool = .highlighter
stroke.points = [InkPoint(x: 0.1, y: 0.5), InkPoint(x: 0.9, y: 0.5)]
let marker = store.image(strokes: [stroke], size: size, scale: 1)!
check((74...78).contains(alpha(marker, x: 50, y: 50)), "highlighter retains translucent alpha")
let retina = store.image(strokes: [stroke], size: size, scale: 2)!
check(retina.width == 200 && retina.height == 200, "cache rebuilds at display backing scale")
let resized = store.image(strokes: [stroke], size: NSSize(width: 200, height: 100), scale: 2)!
check(resized.width == 400 && resized.height == 200, "cache rebuilds after screen resize")
store.invalidate()
stroke.tool = .pen
stroke.points = [InkPoint(x: 0.5, y: 0.5)]
let dot = store.image(strokes: [stroke], size: size, scale: 1)!
check(alpha(dot, x: 50, y: 50) > 250, "single-point taps remain visible")
let document = InkDocument()
stroke.width = 20
stroke.points = [InkPoint(x: 0.1, y: 0.5), InkPoint(x: 0.9, y: 0.5)]
document.add(stroke)
document.erase(at: InkPoint(x: 0.5, y: 0.5), canvasWidth: 100, canvasHeight: 100, radius: 6, mode: .partial)
store.invalidate()
let cut = store.image(strokes: document.strokes, size: size, scale: 1)!
check(alpha(cut, x: 50, y: 50) == 0, "partial eraser makes a transparent hole")
check(alpha(cut, x: 50, y: 58) > 250 && alpha(cut, x: 30, y: 50) > 250,
      "partial eraser preserves ink outside circle including edges of a wide stroke")
var underneath = stroke
underneath.id = UUID()
store.invalidate()
let overlap = store.image(strokes: [underneath] + document.strokes, size: size, scale: 1)!
check(alpha(overlap, x: 50, y: 50) > 250, "one stroke's mask does not cut another stroke below it")
document.undo(); store.invalidate()
check(alpha(store.image(strokes: document.strokes, size: size, scale: 1)!, x: 50, y: 50) > 250,
      "undo restores erased pixels")
document.erase(at: InkPoint(x: 0.7, y: 0.7), from: InkPoint(x: 0.3, y: 0.3),
               canvasWidth: 100, canvasHeight: 100, radius: 3, mode: .partial)
store.invalidate()
let swept = store.image(strokes: document.strokes, size: size, scale: 1)!
check(alpha(swept, x: 50, y: 50) == 0 && alpha(swept, x: 25, y: 50) > 250,
      "fast eraser sweep removes the continuous path, not only event endpoints")
document.replace(with: [InkStroke(tool: .arrow, color: stroke.color, width: 4,
    points: [InkPoint(x: 0.1, y: 0.5), InkPoint(x: 0.9, y: 0.5)])])
document.erase(at: InkPoint(x: 0.81, y: 0.55), canvasWidth: 100, canvasHeight: 100, radius: 4, mode: .partial)
store.invalidate()
let arrowCut = store.image(strokes: document.strokes, size: size, scale: 1)!
check(alpha(arrowCut, x: 81, y: 55) == 0 && alpha(arrowCut, x: 40, y: 50) > 250,
      "partial eraser clips arrowhead while keeping shaft")
func pixels(_ image: CGImage) -> Data { image.dataProvider!.data! as Data }

func bitmap(size: NSSize, scale: CGFloat) -> CGContext {
    let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: scale, y: scale)
    return context
}

let samples = (0..<24).map { index in
    InkPoint(x: 0.5 + 0.48 * sin(Double(index) * 0.41), y: 0.5 + 0.48 * sin(Double(index) * 0.73))
}
for scale: CGFloat in [1, 2] {
    for tool: InkTool in [.pen, .highlighter, .arrow] {
        let live = InkLivePath()
        let context = bitmap(size: size, scale: scale)
        var active = InkStroke(tool: tool, color: stroke.color, width: tool == .highlighter ? 24 : 4, points: [])
        var background = stroke
        background.tool = .highlighter; background.width = 16
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        render(background, size: size)
        for point in samples {
            if tool == .arrow, let first = active.points.first { active.points = [first, point] }
            else { active.points.append(point) }
            let dirty = live.update(active, size: size).integral.intersection(NSRect(origin: .zero, size: size))
            context.saveGState()
            context.clip(to: dirty)
            context.clear(dirty)
            render(background, size: size)
            render(active, size: size, path: live.path)
            context.restoreGState()
            let expected = InkBackingStore().image(strokes: [background, active], size: size, scale: scale)!
            // Quartz rounds edge coverage differently under clipping (up to 2/255).
            let actualPixels = pixels(context.makeImage()!), expectedPixels = pixels(expected)
            check(zip(actualPixels, expectedPixels).allSatisfy { abs(Int($0) - Int($1)) <= 2 },
                  "dirty redraw matches full \(tool) rendering at \(scale)x, sample \(point)")
            let full = bitmap(size: size, scale: scale)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: full, flipped: false)
            render(background, size: size)
            render(active, size: size, path: live.path)
            check(pixels(full.makeImage()!) == expectedPixels, "incremental path matches full path pixel for pixel")
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        }
        check(live.update(active, size: size).isNull, "unchanged input needs no redraw")
        let resizedSize = NSSize(width: 160, height: 80)
        live.update(active, size: resizedSize)
        if tool != .arrow { active.points.append(InkPoint(x: 0.9, y: 0.8)) }
        live.update(active, size: resizedSize)
        let resizedContext = bitmap(size: resizedSize, scale: scale)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: resizedContext, flipped: false)
        render(active, size: resizedSize, path: live.path)
        let expected = InkBackingStore().image(strokes: [active], size: resizedSize, scale: scale)!
        check(pixels(resizedContext.makeImage()!) == pixels(expected), "resize rebuilds live path before further input")
        NSGraphicsContext.restoreGraphicsState()
    }
}

let appended = InkBackingStore()
var committed: [InkStroke] = []
var snapshot: CGImage?
var snapshotPixels: Data?
for index in 0..<12 {
    let old = appended.image(strokes: committed, size: size, scale: 2)!
    if index == 1 { snapshot = old; snapshotPixels = pixels(old) }
    var next = InkStroke(tool: index % 2 == 0 ? .highlighter : .pen, color: stroke.color,
                         width: 12, points: Array(samples.prefix(index + 1)))
    if index == 8 {
        next.erasures = [InkErasure(id: UUID(), radius: 8, points: [InkPoint(x: 0.5, y: 0.5)])]
    }
    committed.append(next)
    appended.append(next, size: size, scale: 2)
    let actual = appended.image(strokes: committed, size: size, scale: 2)!
    let expected = InkBackingStore().image(strokes: committed, size: size, scale: 2)!
    check(pixels(actual) == pixels(expected), "appended ink matches full rebuild, including overlap and erasure masks")
}
check(pixels(snapshot!) == snapshotPixels!, "appending preserves an image already used by a display frame")
appended.invalidate()
committed.removeLast()
check(pixels(appended.image(strokes: committed, size: size, scale: 2)!) ==
      pixels(InkBackingStore().image(strokes: committed, size: size, scale: 2)!), "undo rebuild excludes removed stroke")
let extra = InkStroke(tool: .pen, color: stroke.color, width: 5, points: samples)
committed.append(extra)
appended.append(extra, size: size, scale: 1)
check(pixels(appended.image(strokes: committed, size: size, scale: 1)!) ==
      pixels(InkBackingStore().image(strokes: committed, size: size, scale: 1)!), "scale change before append rebuilds all strokes")
let cold = InkBackingStore()
cold.append(extra, size: size, scale: 1)
check(pixels(cold.image(strokes: [extra], size: size, scale: 1)!) ==
      pixels(InkBackingStore().image(strokes: [extra], size: size, scale: 1)!), "stroke completed before first draw is retained")

print("InkRendering: \(checks) checks passed")
