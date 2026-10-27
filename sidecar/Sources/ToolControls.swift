import AppKit

extension NSColor {
    var inkIsLight: Bool {
        guard let rgb = usingColorSpace(.deviceRGB) else { return false }
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent > 0.65
    }
}

final class InkToolButton: NSButton {
    var symbol = "pencil.tip"
    var inkTint: NSColor = .labelColor
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let selected = state == .on
        if selected {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 13, yRadius: 13).fill()
            inkTint.setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 8, y: bounds.maxY - 5, width: 16, height: 3),
                         xRadius: 1.5, yRadius: 1.5).fill()
        }
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 21, weight: .medium))?
            .withSymbolConfiguration(.init(paletteColors: [.labelColor]))
        icon?.draw(in: NSRect(x: bounds.midX - 11, y: 21, width: 22, height: 22))
        let text = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: selected ? .semibold : .medium),
            .foregroundColor: NSColor.labelColor
        ])
        text.draw(at: NSPoint(x: (bounds.width - text.size().width) / 2, y: 6))
    }
}

final class InkStylePreview: NSView {
    var inkColor: NSColor = .systemBlue
    var lineWidth: Double = 4
    var highlighter = false

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: inkColor.inkIsLight ? 0.2 : 0.95, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 20, y: bounds.midY - 4))
        path.curve(to: NSPoint(x: bounds.width - 20, y: bounds.midY + 4),
                   controlPoint1: NSPoint(x: bounds.width * 0.33, y: bounds.height - 4),
                   controlPoint2: NSPoint(x: bounds.width * 0.66, y: 4))
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        inkColor.withAlphaComponent(highlighter ? 0.35 : 1).setStroke()
        path.stroke()
    }
}
