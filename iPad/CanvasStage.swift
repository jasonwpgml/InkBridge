import UIKit
import PencilKit
import SwiftUI

final class CanvasStageView: UIView {
    let imageView = UIImageView()
    let canvas: PKCanvasView
    var geometry: ScreenGeometry? { didSet { setNeedsLayout() } }

    init(canvas: PKCanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView); addSubview(canvas)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        guard let geometry else { canvas.isHidden = true; return }
        canvas.isHidden = false
        let scale = min(bounds.width / geometry.width, bounds.height / geometry.height)
        canvas.transform = .identity
        canvas.bounds = CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height)
        canvas.contentSize = canvas.bounds.size
        canvas.center = CGPoint(x: bounds.midX, y: bounds.midY)
        canvas.transform = CGAffineTransform(scaleX: scale, y: scale)
    }
}

struct CanvasStage: UIViewRepresentable {
    @ObservedObject var model: PadModel
    func makeUIView(context: Context) -> CanvasStageView {
        let view = CanvasStageView(canvas: model.canvas)
        view.geometry = model.geometry; view.imageView.image = model.lastFrame
        model.stage = view
        return view
    }
    func updateUIView(_ view: CanvasStageView, context: Context) { view.geometry = model.geometry }
}

// This recognizer observes samples without preventing PencilKit's native drawing.
final class PencilPreviewRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var sample: (([UITouch], UIEvent, UIGestureRecognizer.State) -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
        delegate = self
    }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let canvas = view as? PKCanvasView else { return false }
        return touch.type == .pencil || canvas.drawingPolicy == .anyInput
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else { return }
        state = .began; sample?([touch], event, .began)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else { return }
        state = .changed; sample?(event.coalescedTouches(for: touch) ?? [touch], event, .changed)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        sample?(Array(touches), event, .ended); state = .ended
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        sample?(Array(touches), event, .cancelled); state = .cancelled
    }
}
