import SwiftUI

/// The three versions of InkBridge. Sidecar runs on the Mac, so this app only explains how to start it.
enum InkVersion: CaseIterable, Identifiable {
    case sidecar, screen, library
    var id: Self { self }

    var title: String {
        switch self {
        case .sidecar: "Sidecar"
        case .screen: "맥 화면"
        case .library: "서재"
        }
    }

    var detail: String {
        switch self {
        case .sidecar: "iPad를 맥의 확장 화면으로 쓰고\n맥 앱 위에 바로 필기"
        case .screen: "맥 화면을 받아 PencilKit으로\n필기하고 맥에 함께 표시"
        case .library: "PDF·PPT·Word·HTML 문서를\n책장에 꽂아 두고 꺼내 필기"
        }
    }

    var symbol: String {
        switch self {
        case .sidecar: "macbook.and.ipad"
        case .screen: "display"
        case .library: "books.vertical"
        }
    }
}

struct HomeView: View {
    var open: (InkVersion) -> Void

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height
            VStack(spacing: 0) {
                InkBridgeLogo()
                    .padding(.top, max(geo.safeAreaInsets.top, 24) + 28)
                Spacer(minLength: 32)
                cards(wide: wide)
                    .frame(maxWidth: wide ? 1100 : 560)
                    .padding(.horizontal, 32)
                Spacer(minLength: 32)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(edges: .top)
        }
        .background { InkBackdrop() }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private func cards(wide: Bool) -> some View {
        let layout = wide ? AnyLayout(HStackLayout(spacing: 20)) : AnyLayout(VStackLayout(spacing: 16))
        glassGroup {
            layout {
                ForEach(InkVersion.allCases) { version in
                    VersionCard(version: version, wide: wide) { open(version) }
                }
            }
        }
    }

    @ViewBuilder private func glassGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 20, content: content)
        } else {
            content()
        }
    }
}

private struct VersionCard: View {
    let version: InkVersion
    let wide: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            let layout = wide ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
                              : AnyLayout(HStackLayout(spacing: 20))
            layout {
                Image(systemName: version.symbol)
                    .font(.system(size: 34, weight: .light))
                    .frame(width: 64, height: 64)
                    .background(.white.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 8) {
                    Text(version.title).font(.title2.weight(.semibold))
                    Text(version.detail).font(.callout).foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if !wide { Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.5)) }
            }
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            .padding(wide ? 28 : 22)
            .frame(maxWidth: .infinity, minHeight: wide ? 260 : 0, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: 32))
        }
        .buttonStyle(.plain)
        .glassCard(RoundedRectangle(cornerRadius: 32))
        .accessibilityHint(version.detail.replacingOccurrences(of: "\n", with: " "))
    }
}

/// Ink arch over a baseline, beside the wordmark.
struct InkBridgeLogo: View {
    var body: some View {
        HStack(spacing: 14) {
            BridgeMark()
                .stroke(LinearGradient(colors: [Color(red: 0.55, green: 0.78, blue: 1), Color(red: 0.72, green: 0.6, blue: 1)],
                                       startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
                .frame(width: 52, height: 34)
            (Text("Ink").fontWeight(.heavy) + Text("Bridge").fontWeight(.light))
                .font(.system(size: 40, design: .rounded))
                .foregroundStyle(.white)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("InkBridge")
        .accessibilityAddTraits(.isHeader)
    }
}

private struct BridgeMark: Shape {
    func path(in rect: CGRect) -> Path {
        // A deck across the top, carried by an arch whose crown meets it.
        let deck = rect.minY + rect.height * 0.25
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: deck))
        path.addLine(to: CGPoint(x: rect.maxX, y: deck))
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.14, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - rect.width * 0.14, y: rect.maxY),
                          control: CGPoint(x: rect.midX, y: 2 * deck - rect.maxY))
        return path
    }
}

/// A slow-moving ink wash for the glass to refract.
struct InkBackdrop: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15)) { context in
            let t = Float(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 40) / 40 * 2 * .pi)
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.5 + 0.12 * cos(t), 0.5 + 0.1 * sin(t)], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ], colors: [
                Color(red: 0.05, green: 0.07, blue: 0.16), Color(red: 0.1, green: 0.14, blue: 0.34), Color(red: 0.07, green: 0.09, blue: 0.2),
                Color(red: 0.12, green: 0.3, blue: 0.55), Color(red: 0.32, green: 0.24, blue: 0.62), Color(red: 0.08, green: 0.36, blue: 0.5),
                Color(red: 0.06, green: 0.08, blue: 0.18), Color(red: 0.16, green: 0.12, blue: 0.34), Color(red: 0.04, green: 0.06, blue: 0.14),
            ])
        }
        .ignoresSafeArea()
    }
}

extension View {
    @ViewBuilder func glassCard<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape).overlay(shape.stroke(.white.opacity(0.18)))
        }
    }
}

/// How to start the Sidecar version, which runs on the Mac rather than in this app.
struct SidecarGuide: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("맥에서 InkBridge(Sidecar판)를 엽니다.", systemImage: "1.circle")
                    Label("맥의 제어 센터 → 화면 미러링에서 이 iPad를 고릅니다.", systemImage: "2.circle")
                    Label("iPad에 나타난 도구 막대에서 ‘필기 시작’을 누릅니다.", systemImage: "3.circle")
                } footer: {
                    Text("Sidecar판은 맥에서 실행되고 iPad는 화면과 Pencil 입력으로만 쓰입니다. 이 앱을 따로 켜 둘 필요는 없습니다.")
                }
            }
            .navigationTitle("Sidecar")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
        }
    }
}
