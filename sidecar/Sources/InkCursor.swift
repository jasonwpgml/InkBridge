import AppKit

enum InkCursor {
    static func make(tool: InkTool, color: NSColor, width: CGFloat, eraserRadius: CGFloat,
                     eraserMode: EraserMode, showTool: Bool = true) -> NSCursor {
        let diameter = tool == .eraser ? eraserRadius * 2 : width * (tool == .highlighter ? 6 : 1)
        let side = max(40, diameter + 30)
        let center = NSPoint(x: side / 2, y: side / 2)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                                                  width: diameter, height: diameter))
            if tool == .eraser && eraserMode == .stroke { ring.setLineDash([3, 2], count: 2, phase: 0) }
            NSColor.white.withAlphaComponent(0.95).setStroke(); ring.lineWidth = 1.8; ring.stroke()
            NSColor.black.withAlphaComponent(0.8).setStroke(); ring.lineWidth = 0.65; ring.stroke()
            if tool != .eraser {
                let dotSize = min(diameter, 2.5)
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x - dotSize / 2, y: center.y - dotSize / 2,
                                            width: dotSize, height: dotSize)).fill()
            }
            if showTool {
                let name: String
                switch tool {
                case .pen: name = "pencil"
                case .highlighter: name = "highlighter"
                case .arrow: name = "arrow.up.right"
                case .eraser: name = "eraser.fill"
                }
                let offset = diameter / (2 * sqrt(2)) + 3
                let frame = NSRect(x: center.x + offset, y: center.y + offset, width: 12, height: 12)
                let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)
                let outline = symbol?.withSymbolConfiguration(.init(paletteColors: [.white]))
                for dx in [-0.8, 0, 0.8] {
                    for dy in [-0.8, 0, 0.8] where dx != 0 || dy != 0 {
                        outline?.draw(in: frame.offsetBy(dx: dx, dy: dy))
                    }
                }
                symbol?.withSymbolConfiguration(.init(paletteColors: [tool == .eraser ? .systemPink : .black]))?
                    .draw(in: frame)
            }
            return true
        }
        return NSCursor(image: image, hotSpot: center)
    }
}
