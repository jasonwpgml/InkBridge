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
        case .screen: "맥 화면을 iPad로 받아 쓰고\n맥 화면에도 함께 표시"
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

    /// The small line at the foot of the card: how quickly ink appears is where the versions differ most.
    var note: (symbol: String, text: String) {
        switch self {
        case .sidecar: ("tortoise", "지연 있음 · 펜 입력이 맥을 거쳐 표시")
        case .screen: ("bolt", "저지연 · 필기는 iPad에서 바로 그림")
        case .library: ("bolt", "저지연 · 필기는 문서별로 맥에 저장")
        }
    }

    var difference: String {
        switch self {
        case .sidecar: "iPad를 맥의 확장 화면으로 쓰고, 맥에 띄운 투명 필기판에 씁니다. 맥 앱 위에 그대로 쓰므로 강의·화면 공유에 좋지만, 펜 입력이 맥으로 갔다가 화면 영상으로 돌아오기 때문에 획이 조금 늦게 따라옵니다."
        case .screen: "맥 화면을 영상으로 받아 iPad에서 PencilKit으로 씁니다. 필기는 맥을 거치지 않고 iPad에서 바로 그려져 지연이 적고, 맥 화면에도 함께 나타납니다. 대신 맥 화면 영상은 조금 늦게 따라옵니다."
        case .library: "맥 폴더의 PDF·PPT·Word·HTML 문서를 책장에서 꺼내 씁니다. 필기는 iPad에서 바로 그려지고 맥 폴더에 문서·페이지별로 저장되어, 다음에 열어도 그대로 있습니다."
        }
    }

    var howTo: [(title: String, text: String)] {
        switch self {
        case .sidecar: [
            ("시작", "맥에서 InkBridge(Sidecar판)를 열고, 맥의 제어 센터 → 화면 미러링에서 이 iPad를 고른 뒤 도구 막대의 ‘필기 시작’을 누릅니다. 이 앱은 켜 둘 필요가 없습니다."),
            ("필기와 조작 전환", "‘필기 시작’ / ‘조작으로’ 또는 ⌥⌘D. Fn을 누르는 동안은 맥 앱을 잠깐 클릭·스크롤할 수 있고, Esc나 마우스 오른쪽 버튼을 누르면 조작으로 돌아갑니다."),
            ("실행 취소와 지우기", "⌥⌘Z 실행 취소, ⌥⇧⌘Z 다시 실행, ⌥⌘⌫ 현재 화면 필기 모두 지우기(실행 취소 가능)."),
            ("Pencil", "더블탭하면 필기 도구와 지우개가 바뀝니다. Pencil Pro를 스퀴즈하면 원형 도구가 열립니다(macOS 14.5 이상)."),
            ("지연 줄이기", "무선보다 USB 케이블로 연결하면 왕복이 빨라질 수 있습니다. 쓰는 동안 획 끝을 조금 앞서 그려 지연의 일부를 가립니다."),
        ]
        case .screen: [
            ("시작", "맥에서 InkBridge Mac을 열고 ‘화면 보내기’를 고릅니다. iPad에서 그 맥을 고르고 맥에 표시된 6자리 코드를 넣은 뒤, 맥에서 보낼 화면을 골라 ‘화면 보내기’를 누릅니다."),
            ("위쪽 막대", "⌃를 누르면 홈 버튼 하나만 남습니다. 홈 버튼을 짧게 누르면 처음 화면으로, 길게 누르면 막대가 다시 펼쳐집니다."),
            ("도구 막대", "같은 도구를 한 번 더 누르면 굵기·색 설정이 열립니다. ⋯에서 손가락으로도 필기, 불투명 모드, 도구 막대 접기, 필기 모두 지우기를 고릅니다."),
            ("Pencil", "더블탭하면 지우개로 바뀌고, Pencil Pro를 스퀴즈하면 펜 끝 옆에 도구 팔레트가 열립니다."),
            ("필기 보관", "필기는 iPad에 저장되고 맥 디스플레이마다 따로 기억됩니다. 연결이 끊겨도 지워지지 않습니다."),
        ]
        case .library: [
            ("시작", "맥에서 InkBridge Mac의 ‘책장 열기’에서 문서 폴더를 고르고 ‘책장 열기’를 누른 뒤 ‘주소 복사’로 주소를 받습니다. iPad 서재의 ‘책장 추가’에 그 주소를 넣습니다."),
            ("책장과 책", "옆으로 밀어 맥 책장을 고르고, 눌러 열고, 책을 눌러 펼칩니다. ‘가져오기’로 iPad의 PDF·Office 파일을 맥 폴더에 넣을 수 있습니다."),
            ("쓰기", "Pencil로 쓰고 손가락으로 스크롤·확대합니다. PDF·PPT·Word 문서는 손가락으로 좌우로 쓸어 쪽을 넘깁니다."),
            ("저장과 내보내기", "필기는 맥에 자동 저장됩니다. 도구 막대의 ⋯에서 페이지·문서 저장, 지우기, PDF로 내보내기(필기 포함)를 고릅니다."),
        ]
        }
    }
}

struct HomeView: View {
    var open: (InkVersion) -> Void
    @State private var settings = false
    @State private var help = false

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
            HStack(spacing: 12) {
                Button { help = true } label: { Image(systemName: "questionmark").font(.title3.weight(.medium)).frame(width: 48, height: 48) }
                    .glassCard(Circle())
                    .accessibilityLabel("도움말")
                Button { settings = true } label: { Image(systemName: "gearshape").font(.title3).frame(width: 48, height: 48) }
                    .glassCard(Circle())
                    .accessibilityLabel("설정")
            }
            .buttonStyle(.plain)
            .padding(.trailing, 32).padding(.top, 12)
        }
        .background { InkBackdrop() }
        .sheet(isPresented: $settings) { SettingsView() }
        .sheet(isPresented: $help) { HelpView() }
    }

    @ViewBuilder private func cards(wide: Bool) -> some View {
        let layout = wide ? AnyLayout(HStackLayout(spacing: 20)) : AnyLayout(VStackLayout(spacing: 16))
        glassGroup {
            layout {
                ForEach(InkVersion.allCases) { version in
                    VersionCard(version: version, wide: wide) { open(version) }
                }
            }
            // Side by side, the cards share the tallest one's height instead of filling the screen.
            .fixedSize(horizontal: false, vertical: wide)
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
            Group {
                if wide {
                    VStack(alignment: .leading, spacing: 18) {
                        icon
                        text
                        Spacer(minLength: 0)
                        note
                    }
                } else {
                    HStack(spacing: 20) {
                        icon
                        VStack(alignment: .leading, spacing: 12) { text; note }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").foregroundStyle(.primary.opacity(0.5))
                    }
                }
            }
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .padding(wide ? 28 : 22)
            .frame(maxWidth: .infinity, minHeight: wide ? 240 : 0, maxHeight: wide ? .infinity : nil, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: 32))
        }
        .buttonStyle(.plain)
        .glassCard(RoundedRectangle(cornerRadius: 32))
        .accessibilityHint(version.detail.replacingOccurrences(of: "\n", with: " ") + ". " + version.note.text)
    }

    private var icon: some View {
        Image(systemName: version.symbol)
            .font(.system(size: 34, weight: .light))
            .frame(width: 64, height: 64)
            .background(.primary.opacity(0.12), in: Circle())
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(version.title).font(.title2.weight(.semibold))
            Text(version.detail).font(.callout).foregroundStyle(.primary.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var note: some View {
        Label(version.note.text, systemImage: version.note.symbol)
            .font(.caption).foregroundStyle(.primary.opacity(0.6))
            .accessibilityHidden(true)
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

/// What sets the three versions apart, and how each one is used.
struct HelpView: View {
    @State private var version = InkVersion.screen

    var body: some View {
        GlassSheet(title: "도움말") {
            GlassSection("세 버전의 차이") {
                ForEach(InkVersion.allCases) { option in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Image(systemName: option.symbol).frame(width: 30)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.title).font(.headline)
                            Label(option.note.text, systemImage: option.note.symbol).font(.caption).foregroundStyle(.secondary)
                            Text(option.difference).font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            GlassSection("쓰는 법") {
                HStack(spacing: 12) {
                    ForEach(InkVersion.allCases) { option in
                        GlassChoice(title: option.title, symbol: option.symbol, selected: version == option) { version = option }
                    }
                }
                ForEach(version.howTo, id: \.title) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.subheadline.weight(.semibold))
                        Text(item.text).font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
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
