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

/// A sheet laid out as glass panels over the ink wash, titled, with 완료 in the corner.
struct GlassSheet<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text(title).font(.title.bold())
                    Spacer()
                    Button { dismiss() } label: { Text("완료").font(.headline).padding(.horizontal, 22).frame(height: 44) }
                        .buttonStyle(.plain)
                        .glassCard(Capsule())
                }
                content
            }
            .padding(28)
        }
        .scrollIndicators(.hidden)
        .background { InkBackdrop() }
    }
}

/// A glass panel in a GlassSheet, with an optional heading above and note below.
struct GlassSection<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 8) }
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(RoundedRectangle(cornerRadius: 26), interactive: false)
            if let footer { Text(footer).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 8) }
        }
    }
}

/// One of a row of choices inside a GlassSection; the chosen one is inked in.
struct GlassChoice: View {
    let title: String
    var symbol: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18)
        Button(action: action) {
            VStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).font(.title2) }
                Text(title).font(.subheadline.weight(selected ? .semibold : .regular))
            }
            .frame(maxWidth: .infinity, minHeight: 78)
            .background(.primary.opacity(selected ? 0.12 : 0), in: shape)
            .overlay(shape.strokeBorder(.primary.opacity(selected ? 0.55 : 0.14), lineWidth: selected ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
