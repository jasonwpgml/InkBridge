import SwiftUI

/// 불투명 모드 (on by default): solid panels, easy to read over any wallpaper. Off: Liquid Glass over the ink wash.
enum Surfaces {
    static let opaqueKey = "opaqueSurfaces"
}

private struct MacSurface<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @AppStorage(Surfaces.opaqueKey) private var opaque = true

    func body(content: Content) -> some View {
        if opaque {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.stroke(.primary.opacity(0.1)))
                .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
        } else if #available(macOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape).overlay(shape.stroke(.primary.opacity(0.12)))
        }
    }
}

extension View {
    /// A card or panel of the Mac window; `interactive` makes glass respond to the pointer.
    func macSurface<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        modifier(MacSurface(shape: shape, interactive: interactive))
    }
}

/// A panel on a mode page, with an optional heading above and note below.
struct MacPanel<Content: View>: View {
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
            if let title { Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 6) }
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .macSurface(RoundedRectangle(cornerRadius: 20))
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The settings behind the gear: the surface style.
struct MacSettings: View {
    @AppStorage(Surfaces.opaqueKey) private var opaque = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("불투명 모드", isOn: $opaque).toggleStyle(.switch)
            Text("끄면 카드와 패널이 유리처럼 비칩니다.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 260)
    }
}
