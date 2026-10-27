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
    @State private var settings = false

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
        .overlay(alignment: .topTrailing) {
            Button { settings = true } label: { Image(systemName: "gearshape").font(.title3).frame(width: 48, height: 48) }
                .buttonStyle(.plain)
                .glassCard(Circle())
                .padding(.trailing, 32).padding(.top, 12)
                .accessibilityLabel("설정")
        }
        .background { InkBackdrop() }
        .sheet(isPresented: $settings) { SettingsView() }
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
                    .background(.primary.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 8) {
                    Text(version.title).font(.title2.weight(.semibold))
                    Text(version.detail).font(.callout).foregroundStyle(.primary.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if !wide { Image(systemName: "chevron.right").foregroundStyle(.primary.opacity(0.5)) }
            }
            .foregroundStyle(.primary)
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

extension View {
    /// `interactive` makes the glass respond to touch; off for panels that only hold controls.
    @ViewBuilder func glassCard<S: Shape>(_ shape: S, interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape).overlay(shape.stroke(.primary.opacity(0.12)))
        }
    }
}

/// 화면 모드: follow the iPad, or keep the app light or dark.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    static let key = "appearance"
    var id: Self { self }

    var title: String {
        switch self {
        case .system: "시스템 설정"
        case .light: "라이트"
        case .dark: "다크"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    /// Set on the windows rather than with preferredColorScheme, which doesn't return to the system setting
    /// once a scheme was forced; this way sheets and the reader's web view follow too.
    func apply() {
        let style: UIUserInterfaceStyle = switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.windows.forEach { $0.overrideUserInterfaceStyle = style }
        }
    }
}

struct SettingsView: View {
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    @AppStorage("opaqueTools") private var opaqueTools = false

    var body: some View {
        GlassSheet(title: "설정") {
            GlassSection("화면 모드", footer: "시스템 설정은 iPad의 라이트·다크 모드를 따릅니다.") {
                HStack(spacing: 12) {
                    ForEach(Appearance.allCases) { option in
                        GlassChoice(title: option.title, symbol: option.symbol, selected: appearance == option) { appearance = option }
                    }
                }
            }
            GlassSection("필기 도구", footer: "배경이 복잡해 유리 도구 막대가 잘 안 보일 때 켭니다.") {
                Toggle("불투명 도구 막대", isOn: $opaqueTools)
            }
            GlassSection {
                LabeledContent("버전", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            }
        }
    }
}

/// How to start the Sidecar version, which runs on the Mac rather than in this app.
struct SidecarGuide: View {
    private let steps = [
        "맥에서 InkBridge(Sidecar판)를 엽니다.",
        "맥의 제어 센터 → 화면 미러링에서 이 iPad를 고릅니다.",
        "iPad에 나타난 도구 막대에서 ‘필기 시작’을 누릅니다.",
    ]

    var body: some View {
        GlassSheet(title: "Sidecar") {
            GlassSection("시작하기", footer: "Sidecar판은 맥에서 실행되고 iPad는 화면과 Pencil 입력으로만 쓰입니다. 이 앱을 따로 켜 둘 필요는 없습니다.") {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text("\(index + 1)").font(.headline.monospacedDigit())
                            .frame(width: 30, height: 30)
                            .background(.primary.opacity(0.1), in: Circle())
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
                        Text(step).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
