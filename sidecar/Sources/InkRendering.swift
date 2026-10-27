import AppKit

extension InkColor {
    var nsColor: NSColor { NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1) }
}

func render(_ stroke: InkStroke, size: NSSize, path: NSBezierPath? = nil) {
    let context = NSGraphicsContext.current!.cgContext
    let erasures = stroke.erasures ?? []
    if !erasures.isEmpty {
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
    }
    defer {
        if !erasures.isEmpty {
            context.setBlendMode(.clear)
            context.setLineCap(.round); context.setLineJoin(.round)
            for erasure in erasures {
                let points = erasure.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                guard let first = points.first else { continue }
                context.setLineWidth(erasure.radius * 2)
                if points.count == 1 {
                    context.fillEllipse(in: CGRect(x: first.x - erasure.radius, y: first.y - erasure.radius,
                                                   width: erasure.radius * 2, height: erasure.radius * 2))
                } else {
                    context.beginPath(); context.move(to: first)
                    for point in points.dropFirst() { context.addLine(to: point) }
                    context.strokePath()
                }
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }
    let path = path ?? inkPath(stroke, size: size)
    let color = stroke.color.nsColor.withAlphaComponent(stroke.tool == .highlighter ? 0.3 : 1)
    color.setStroke()
    color.setFill()
    if stroke.points.count == 1 { path.fill() } else { path.stroke() }
}

private func inkPath(_ stroke: InkStroke, size: NSSize) -> NSBezierPath {
    let path = NSBezierPath()
    path.lineWidth = stroke.width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    let points = stroke.pathPoints(width: size.width, height: size.height).map { NSPoint(x: $0.x, y: $0.y) }
    guard let first = points.first else { return path }
    if points.count == 1 {
        let point = first
        path.appendOval(in: NSRect(x: point.x - stroke.width / 2, y: point.y - stroke.width / 2,
                                  width: stroke.width, height: stroke.width))
    } else if stroke.tool == .arrow {
        let start = points[0], end = points[points.count - 1]
        path.move(to: start)
        path.line(to: end)
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = max(12, stroke.width * 4)
        for offset in [-Double.pi / 6, Double.pi / 6] {
            path.move(to: end)
            path.line(to: NSPoint(x: end.x - cos(angle + offset) * length,
                                 y: end.y - sin(angle + offset) * length))
        }
    } else {
        path.move(to: points[0])
        for point in points.dropFirst() { path.line(to: point) }
    }
    return path
}

final class InkLivePath {
    private(set) var path = NSBezierPath()
    private var strokeID: UUID?
    private var size = NSSize.zero
    private var pointCount = 0
    private var lastPoint: InkPoint?
    private var curveEnd = InkPoint(x: 0, y: 0)

    @discardableResult func update(_ stroke: InkStroke, size: NSSize) -> NSRect {
        if strokeID == stroke.id, self.size == size,
           pointCount == stroke.points.count, lastPoint == stroke.points.last { return .null }
        let padding = stroke.width / 2 + 2
        var dirty = NSRect.null
        if strokeID != stroke.id || self.size != size || stroke.tool == .arrow
            || pointCount < 2 || stroke.points.count < pointCount {
            if strokeID == stroke.id { dirty = path.bounds.insetBy(dx: -padding, dy: -padding) }
            path = inkPath(stroke, size: size)
            dirty = dirty.union(path.bounds.insetBy(dx: -padding, dy: -padding))
            let points = stroke.points
            if points.count > 2 {
                curveEnd = InkPoint(x: (points[points.count - 2].x * size.width + points.last!.x * size.width) / 2,
                                    y: (points[points.count - 2].y * size.height + points.last!.y * size.height) / 2)
            } else if let first = points.first {
                curveEnd = InkPoint(x: first.x * size.width, y: first.y * size.height)
            }
        } else {
            for index in pointCount..<stroke.points.count {
                let control = InkPoint(x: stroke.points[index - 1].x * size.width, y: stroke.points[index - 1].y * size.height)
                let next = InkPoint(x: stroke.points[index].x * size.width, y: stroke.points[index].y * size.height)
                let end = InkPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2)
                let left = min(curveEnd.x, control.x, next.x), bottom = min(curveEnd.y, control.y, next.y)
                let right = max(curveEnd.x, control.x, next.x), top = max(curveEnd.y, control.y, next.y)
                dirty = dirty.union(NSRect(x: left, y: bottom, width: right - left, height: top - bottom)
                    .insetBy(dx: -padding, dy: -padding))
                let samples = InkPoint.curve(from: curveEnd, control: control, to: end)
                // Replace only the provisional last line; earlier curve segments are stable.
                var first = NSPoint(x: samples[0].x, y: samples[0].y)
                path.setAssociatedPoints(&first, at: path.elementCount - 1)
                for sample in samples.dropFirst() { path.line(to: NSPoint(x: sample.x, y: sample.y)) }
                path.line(to: NSPoint(x: next.x, y: next.y))
                curveEnd = end
            }
        }
        strokeID = stroke.id; self.size = size
        pointCount = stroke.points.count; lastPoint = stroke.points.last
        return dirty
    }
}

final class InkBackingStore {
    private var context: CGContext?
    private var cachedImage: CGImage?
    private var cachedSize = NSSize.zero
    private var cachedScale: CGFloat = 0

    func invalidate() { context = nil; cachedImage = nil }

    func append(_ stroke: InkStroke, size: NSSize, scale: CGFloat) {
        guard let context, size == cachedSize, scale == cachedScale else { invalidate(); return }
        cachedImage = nil
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        render(stroke, size: size)
        NSGraphicsContext.restoreGraphicsState()
    }

    func image(strokes: [InkStroke], size: NSSize, scale: CGFloat) -> CGImage? {
        if let cachedImage, size == cachedSize, scale == cachedScale { return cachedImage }
        if context == nil || size != cachedSize || scale != cachedScale {
            invalidate()
            guard size.width > 0, size.height > 0,
              let context = CGContext(data: nil, width: Int(ceil(size.width * scale)),
                height: Int(ceil(size.height * scale)), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.scaleBy(x: scale, y: scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            for stroke in strokes { render(stroke, size: size) }
            NSGraphicsContext.restoreGraphicsState()
            self.context = context
            cachedSize = size
            cachedScale = scale
        }
        cachedImage = context?.makeImage()
        return cachedImage
    }
}
