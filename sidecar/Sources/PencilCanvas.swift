import AppKit
import SwiftUI

@available(macOS 14.5, *)
struct PencilCanvas: View {
    let canvas: InkCanvas
    let recordPhase: (String) -> Void
    let squeezed: (CGPoint?) -> Void

    var body: some View {
        CanvasView(canvas: canvas)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onPencilSqueeze { phase in
                switch phase {
                case .active: recordPhase("눌림")
                case .ended(let value):
                    recordPhase("완료")
                    squeezed(value.hoverPose?.location)
                case .failed: recordPhase("취소")
                }
            }
    }

    private struct CanvasView: NSViewRepresentable {
        let canvas: InkCanvas
        func makeNSView(context: Context) -> InkCanvas { canvas }
        func updateNSView(_ view: InkCanvas, context: Context) {}
    }
}
