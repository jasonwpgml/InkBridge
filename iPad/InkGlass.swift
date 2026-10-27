import SwiftUI

/// The clear glass of the Sidecar InkBridge toolbar, with the same "불투명 모드" switch (opaqueTools) for busy backgrounds.
struct InkGlass<S: Shape>: ViewModifier {
    let shape: S
    @AppStorage("opaqueTools") private var opaque = false

    func body(content: Content) -> some View {
        if opaque {
            content
                .background(Color(UIColor.systemBackground), in: shape)
                .overlay(shape.stroke(.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.16), radius: 20, y: 6)
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.clear.interactive(), in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.16), radius: 20, y: 6)
        }
    }
}

extension View {
    func inkGlass<S: Shape>(_ shape: S) -> some View { modifier(InkGlass(shape: shape)) }

    /// Shows the squeeze palette next to the pencil tip in both modes.
    func pencilPalette(model: PadModel, documents: DocumentSession, documentMode: Bool) -> some View {
        overlay { PaletteLayer(model: model, documents: documents, documentMode: documentMode) }
    }
}

private struct PaletteLayer: View {
    @ObservedObject var model: PadModel
    @ObservedObject var documents: DocumentSession
    let documentMode: Bool
    private let size = CGSize(width: 340, height: 196)

    var body: some View {
        GeometryReader { geo in
            if let tip = model.palettePoint {
                let origin = geo.frame(in: .global).origin
                let local = CGPoint(x: tip.x - origin.x, y: tip.y - origin.y)
                // Above the tip when there is room (the hand is below it), otherwise below.
                let above = local.y - size.height / 2 - 32
                let y = above - size.height / 2 > 8 ? above : local.y + size.height / 2 + 32
                let x = min(max(local.x, size.width / 2 + 8), geo.size.width - size.width / 2 - 8)
                ZStack {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { model.palettePoint = nil } }
                    PencilPalette(model: model, documents: documents, documentMode: documentMode)
                        .frame(width: size.width)
                        .position(x: x, y: min(max(y, size.height / 2 + 8), geo.size.height - size.height / 2 - 8))
                        .transition(.scale(scale: 0.85, anchor: UnitPoint(x: (local.x - x) / size.width + 0.5,
                                                                         y: y > local.y ? 0 : 1)).combined(with: .opacity))
                }
            }
        }
        .ignoresSafeArea()
    }
}
