import SwiftUI
import UIKit
import PencilKit
import Combine
import CryptoKit

final class PadModel: NSObject, ObservableObject, PKCanvasViewDelegate, UIPencilInteractionDelegate {
    let link = PeerLink(host: false, name: UIDevice.current.name)
    let canvas = PKCanvasView()
    @Published private(set) var geometry: ScreenGeometry?
    @Published var toolsVisible = true
    /// Window position of the pencil tip while the squeeze palette is open.
    @Published var palettePoint: CGPoint?
    /// Document mode's link to the page; the toolbar and palette send undo, redo and commands through it.
    let documents = DocumentSession()
    @Published var tools: WritingTools {
        didSet {
            updateTool()
            if let data = try? JSONEncoder().encode(tools) {
                UserDefaults.standard.set(data, forKey: "writingTools")
            }
        }
    }
    @Published var message = "맥을 연결해 화면 전송을 시작하세요."
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var receiving = false
    weak var stage: CanvasStageView?
    private(set) var lastFrame: UIImage?
    private var drawingData = PKDrawing().dataRepresentation() { didSet { drawingUnsent = true } }
    // While true, each ink update carries the full drawing; during a stroke only the preview changes.
    private var drawingUnsent = true
    private var preview: LiveStroke?
    private var previewActive = false
    private var strokeCountAtStart = 0
    private var revision: UInt64 = 0
    private var dirty = false
    private var restoring = false
    private var timer: Timer?
    private var saveWork: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "inkbridge.save")
    private var lastFrameTime = Date.distantPast
    private var expectingFrames = false

    override init() {
        tools = UserDefaults.standard.data(forKey: "writingTools")
            .flatMap { try? JSONDecoder().decode(WritingTools.self, from: $0) } ?? WritingTools()
        super.init()
        canvas.backgroundColor = .clear; canvas.isOpaque = false
        canvas.drawingPolicy = .pencilOnly
        canvas.isScrollEnabled = false
        canvas.minimumZoomScale = 1; canvas.maximumZoomScale = 1
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.delegate = self
        let interaction = UIPencilInteraction(); interaction.delegate = self
        canvas.addInteraction(interaction)
        let recognizer = PencilPreviewRecognizer(target: nil, action: nil)
        recognizer.sample = { [weak self] touches, _, state in self?.observe(touches, phase: state) }
        canvas.addGestureRecognizer(recognizer)
        updateTool()
        link.received = { [weak self] kind, data in self?.receive(kind, data: data) }
        link.connectionChanged = { [weak self] connected in
            guard let self else { return }
            if !connected {
                self.expectingFrames = false; self.receiving = false
                self.message = "연결이 끊겼습니다. 필기는 iPad에 보관됩니다."; self.persist()
            }
        }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.dirty { self.sendInk() }
            if self.receiving && Date().timeIntervalSince(self.lastFrameTime) > 5 {
                self.receiving = false
                self.message = "화면 수신이 지연되고 있습니다. 맥의 전송 상태를 확인하세요."
            }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        link.start()
    }

    func updateTool() {
        switch tools.selected {
        case .highlighter: canvas.tool = PKInkingTool(.marker, color: UIColor(inkRGB: tools.style.color), width: tools.style.width)
        case .eraser: canvas.tool = PKEraserTool(.vector)
        case .pen:
            let ink: PKInkingTool.InkType
            switch tools.penKind {
            case .gel: ink = .pen
            case .ballpoint: ink = .monoline
            case .fountain: ink = .fountainPen
            }
            canvas.tool = PKInkingTool(ink, color: UIColor(inkRGB: tools.style.color), width: tools.style.width)
        }
        canvas.drawingPolicy = tools.fingerDrawing ? .anyInput : .pencilOnly
    }

    private func receive(_ kind: MessageKind, data: Data) {
        do {
            switch kind {
            case .geometry:
                let value = try JSONDecoder().decode(ScreenGeometry.self, from: data)
                guard value.isValid else { return }
                expectingFrames = true
                if value.sourceID != geometry?.sourceID {
                    persist()
                    geometry = value; preview = nil; previewActive = false
                    lastFrame = nil; stage?.imageView.image = nil; receiving = false
                    restoring = true
                    let saved = try? Data(contentsOf: drawingURL(value.sourceID))
                    canvas.drawing = (saved.flatMap { try? PKDrawing(data: $0) }) ?? PKDrawing()
                    drawingData = canvas.drawing.dataRepresentation()
                    canvas.undoManager?.removeAllActions()
                    restoring = false
                    canUndo = false; canRedo = false
                    stage?.geometry = value
                }
                drawingUnsent = true; dirty = true; sendInk()
                message = "\(value.name) · Pencil로 바로 필기하세요."
            case .video:
                guard expectingFrames else { return }
                let frame = try JSONDecoder().decode(ScreenFrame.self, from: data)
                guard frame.sourceID == geometry?.sourceID, let image = UIImage(data: frame.jpeg) else { return }
                lastFrame = image; stage?.imageView.image = image
                lastFrameTime = Date()
                if !receiving { receiving = true; message = "화면 수신 중 · 필기는 iPad에서 즉시 표시됩니다." }
            case .stopped:
                expectingFrames = false; receiving = false
                message = "맥 화면 전송이 멈췄습니다. 필기는 보관됩니다."
                persist()
            default: break
            }
        } catch { message = "수신 데이터를 읽지 못했습니다: \(error.localizedDescription)" }
    }

    private func observe(_ touches: [UITouch], phase: UIGestureRecognizer.State) {
        guard geometry != nil else { return }
        if phase == .began {
            previewActive = true; strokeCountAtStart = canvas.drawing.strokes.count
            if let tool = canvas.tool as? PKInkingTool {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                tool.color.getRed(&r, green: &g, blue: &b, alpha: &a)
                preview = LiveStroke(points: [], red: r, green: g, blue: b,
                                     alpha: tool.inkType == .marker ? 0.35 : a, width: tool.width)
            } else { preview = nil }
        }
        for touch in touches {
            let point = touch.location(in: canvas)
            if let last = preview?.points.last, hypot(point.x - last.x, point.y - last.y) < 0.2 { continue }
            if (preview?.points.count ?? 0) < 16384 { preview?.points.append(InkPoint(x: point.x, y: point.y)) }
        }
        if phase == .ended || phase == .cancelled {
            previewActive = false
            if phase == .cancelled || canvas.drawing.strokes.count > strokeCountAtStart { preview = nil }
        }
        dirty = true
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !restoring else { return }
        drawingData = canvasView.drawing.dataRepresentation()
        if !previewActive { preview = nil }
        dirty = true
        canUndo = canvas.undoManager?.canUndo ?? false
        canRedo = canvas.undoManager?.canRedo ?? false
        scheduleSave()
    }

    func canvasViewDidFinishRendering(_ canvasView: PKCanvasView) {
        if !previewActive, canvasView.drawing.strokes.count > strokeCountAtStart, preview != nil {
            drawingData = canvasView.drawing.dataRepresentation()
            preview = nil; dirty = true
        }
    }

    private func sendInk() {
        guard let geometry, link.connectedName != nil else { return }
        revision += 1
        let update = InkUpdate(sourceID: geometry.sourceID, revision: revision,
                               drawing: drawingUnsent ? drawingData : nil, preview: preview)
        guard update.isValid else { message = "필기가 전송 한도를 넘었습니다. 현재 필기는 기기에 저장됩니다."; dirty = false; return }
        do {
            let data = try JSONEncoder().encode(update)
            // A queued update can still be replaced, so keep sending the drawing until one goes out.
            if link.send(.ink, body: data, latest: true) { drawingUnsent = false }
            dirty = false
        } catch { message = "필기 전송 실패: \(error.localizedDescription)" }
    }

    func undo() { canvas.undoManager?.undo(); canvasViewDrawingDidChange(canvas) }
    func redo() { canvas.undoManager?.redo(); canvasViewDrawingDidChange(canvas) }
    func clear() {
        replaceDrawing(PKDrawing())
    }

    private func replaceDrawing(_ drawing: PKDrawing) {
        let previous = canvas.drawing
        canvas.undoManager?.registerUndo(withTarget: self) { model in model.replaceDrawing(previous) }
        canvas.drawing = drawing; preview = nil
        canvasViewDrawingDidChange(canvas)
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        handlePencil(UIPencilInteraction.preferredTapAction, at: tap.hoverPose?.location, in: interaction.view)
    }
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        handlePencil(UIPencilInteraction.preferredSqueezeAction, at: squeeze.hoverPose?.location, in: interaction.view)
    }

    /// Double-tap and squeeze in both modes, following Settings → Apple Pencil like Notes and Goodnotes:
    /// eraser actions toggle the eraser, palette actions open the palette at the pencil tip.
    func handlePencil(_ action: UIPencilPreferredAction, at location: CGPoint?, in view: UIView?) {
        switch action {
        case .switchEraser, .switchPrevious:
            tools.toggleEraser()
        case .showColorPalette, .showInkAttributes, .showContextualPalette:
            withAnimation(.snappy(duration: 0.22)) {
                if palettePoint != nil { palettePoint = nil; return }
                let window = view?.window
                palettePoint = location.flatMap { view?.convert($0, to: nil) }
                    ?? window.map { CGPoint(x: $0.bounds.midX, y: $0.bounds.midY) } ?? .zero
            }
        default:
            break
        }
    }

    private func drawingURL(_ source: String) -> URL {
        let name = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name + ".drawing")
    }

    private func scheduleSave() {
        saveWork?.cancel()
        guard let geometry else { return }
        let data = drawingData, url = drawingURL(geometry.sourceID)
        let work = DispatchWorkItem { [weak self] in
            do { try data.write(to: url, options: .atomic) }
            catch { DispatchQueue.main.async { self?.message = "필기 저장 실패: \(error.localizedDescription)" } }
        }
        saveWork = work; saveQueue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func persist() {
        saveWork?.cancel()
        guard let geometry else { return }
        let data = canvas.drawing.dataRepresentation(), url = drawingURL(geometry.sourceID)
        let result = saveQueue.sync { Result { try data.write(to: url, options: .atomic) } }
        if case .failure(let error) = result { message = "필기 저장 실패: \(error.localizedDescription)" }
    }
}
