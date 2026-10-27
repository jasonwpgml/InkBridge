import AppKit
import PencilKit

final class InkOverlayView: NSView {
    var geometry: ScreenGeometry?
    var drawingImage: NSImage?
    var preview: LiveStroke?
    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        drawingImage?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        guard let geometry, let preview, let first = preview.points.first,
              let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.scaleBy(x: bounds.width / geometry.width, y: bounds.height / geometry.height)
        context.setStrokeColor(CGColor(red: preview.red, green: preview.green, blue: preview.blue, alpha: preview.alpha))
        context.setFillColor(CGColor(red: preview.red, green: preview.green, blue: preview.blue, alpha: preview.alpha))
        context.setLineWidth(preview.width); context.setLineCap(.round); context.setLineJoin(.round)
        if preview.points.count == 1 {
            context.fillEllipse(in: CGRect(x: first.x - preview.width / 2, y: first.y - preview.width / 2,
                                          width: preview.width, height: preview.width))
        } else {
            context.move(to: CGPoint(x: first.x, y: first.y))
            for point in preview.points.dropFirst() { context.addLine(to: CGPoint(x: point.x, y: point.y)) }
            context.strokePath()
        }
        context.restoreGState()
    }
}

final class InkOverlay {
    private var window: NSPanel?
    private let view = InkOverlayView()
    private var lastDrawing = Data()
    private var revision: UInt64 = 0

    func show(displayID: CGDirectDisplayID, geometry: ScreenGeometry) {
        hide()
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { return }
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "InkBridge 동기화 필기"
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        view.geometry = geometry; view.frame = CGRect(origin: .zero, size: screen.frame.size)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        panel.orderFrontRegardless()
        window = panel
    }

    func apply(_ update: InkUpdate) throws {
        guard let geometry = view.geometry, update.sourceID == geometry.sourceID,
              update.isValid, update.revision >= revision else { return }
        if let data = update.drawing, data != lastDrawing {
            let drawing = try PKDrawing(data: data)
            view.drawingImage = drawing.image(from: CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height), scale: 2)
            lastDrawing = data
        }
        revision = update.revision
        view.preview = update.preview
        view.needsDisplay = true
    }

    func hide() {
        window?.orderOut(nil); window?.contentView = nil; window?.close(); window = nil
        view.drawingImage = nil; view.preview = nil; view.geometry = nil
        lastDrawing = Data(); revision = 0
    }
}
