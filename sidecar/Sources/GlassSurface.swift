import AppKit
import QuartzCore

// CAFilter tuning is experimental and confined to the toolbar on macOS 26.
// See RESEARCH.md for the upstream investigation and compatibility limits.
@available(macOS 26.0, *)
final class WaterGlassView: NSGlassEffectView {
    private var displayLink: CADisplayLink?

    private(set) var tuningApplied = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil,
              ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26 else { return }
        let link = displayLink(target: self, selector: #selector(tuneSurface))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tuneSurface() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
              let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tune(layer)
        CATransaction.commit()
    }

    private func tune(_ layer: CALayer) {
        guard layer !== contentView?.layer else { return }
        if let filters = layer.filters {
            var touched = false
            for case let filter as NSObject in filters {
                guard filter.responds(to: NSSelectorFromString("inputKeys")),
                      let keys = filter.value(forKey: "inputKeys") as? [String],
                      keys.contains("inputBlurOpacity0") else { continue }
                tuningApplied = true
                let name = filter.value(forKey: "name") as? String ?? ""
                // Mutating CAFilter alone can leave the render server using its old values.
                // Commit through the layer every frame, including after AppKit changes focus.
                for key in keys where key.hasPrefix("inputBlurOpacity") || key == "inputBlurRadius" || key == "inputFaceOpacity" {
                    let target = key == "inputBlurRadius" ? 1.5 : 0.0
                    filter.setValue(target, forKey: key)
                    if !name.isEmpty {
                        layer.setValue(target, forKeyPath: "filters.\(name).\(key)")
                    }
                }
                touched = true
            }
            if touched { layer.filters = filters }
        }
        for child in layer.sublayers ?? [] { tune(child) }
    }
}


final class GlassGrooveView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        // A shallow inset bevel: a narrow shade above a light-catching lower lip.
        let groove = bounds.insetBy(dx: 3.5, dy: 3.5)
        let shade = NSBezierPath(roundedRect: groove, xRadius: 22.5, yRadius: 22.5)
        shade.lineWidth = 0.65
        NSColor.black.withAlphaComponent(0.085).setStroke()
        shade.stroke()
        let lip = NSBezierPath(roundedRect: groove.offsetBy(dx: 0, dy: -0.8), xRadius: 22.5, yRadius: 22.5)
        lip.lineWidth = 0.65
        NSColor.white.withAlphaComponent(0.5).setStroke()
        lip.stroke()
    }
}
