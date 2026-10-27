import SwiftUI
import MultipeerConnectivity

struct ConnectionView: View {
    @ObservedObject var link: PeerLink
    @Environment(\.dismiss) private var dismiss
    @State private var selected: MCPeerID?
    @State private var code = ""

    var body: some View {
        GlassSheet(title: "맥 연결") {
            GlassSection("가까운 맥") {
                if link.nearby.isEmpty {
                    Text("맥에서 InkBridge Mac을 열어 주세요. 두 기기의 Wi-Fi와 로컬 네트워크 접근을 켜야 합니다.")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) { ProgressView(); Text("맥 찾는 중").foregroundStyle(.secondary) }
                }
                ForEach(link.nearby, id: \.self) { peer in
                    GlassChoice(title: peer.displayName, symbol: "laptopcomputer", selected: selected == peer) { selected = peer }
                }
            }
            GlassSection("맥에 표시된 6자리 코드") {
                TextField("연결 코드", text: $code).keyboardType(.numberPad)
                    .font(.title2.monospacedDigit())
                    .padding(.horizontal, 16).frame(height: 52)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                    .onChange(of: code) { _, value in code = String(value.filter(\.isNumber).prefix(6)) }
                let ready = selected != nil && code.count == 6 && link.connectedName == nil
                Button { if let selected { link.connect(to: selected, code: code) } } label: {
                    Text("연결").font(.headline).frame(maxWidth: .infinity).frame(height: 50)
                }
                .buttonStyle(.plain)
                .glassCard(Capsule())
                .disabled(!ready)
                .opacity(ready ? 1 : 0.45)
            }
            GlassSection(footer: nil) {
                Text(link.status).foregroundStyle(.secondary)
                if link.connectedName != nil {
                    Button(role: .destructive) { link.disconnect() } label: {
                        Text("연결 해제").font(.headline).foregroundStyle(.red).frame(maxWidth: .infinity).frame(height: 48)
                    }
                    .buttonStyle(.plain)
                    .glassCard(Capsule())
                }
            }
        }
        .onChange(of: link.connectedName) { _, name in if name != nil { dismiss() } }
    }
}

struct PadView: View {
    @ObservedObject var model: PadModel
    @ObservedObject var link: PeerLink
    var goHome: () -> Void
    @State private var connectionSheet = false
    @State private var clearConfirmation = false
    @AppStorage("screenBarCollapsed") private var barCollapsed = false

    var body: some View {
        ZStack {
            CanvasStage(model: model).ignoresSafeArea()
            if model.geometry == nil {
                ContentUnavailableView("맥 화면 위에 바로 쓰기", systemImage: "pencil.tip.crop.circle",
                                       description: Text("맥을 연결한 뒤 Mac 앱에서 화면 전송을 시작하세요.\n필기는 맥을 거치지 않고 iPad에서 바로 그려져 Sidecar보다 펜 지연이 적습니다. 맥 화면 영상은 조금 늦게 따라옵니다."))
                    .foregroundStyle(.white)
            }
        }
        .overlay(alignment: .topLeading) { topBar.padding(.leading, 16).padding(.top, 12) }
        .overlay(alignment: .bottom) {
            ToolbarDock(model: model, documents: model.documents, clearConfirmation: $clearConfirmation)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .pencilPalette(model: model, documents: model.documents, documentMode: false)
        .sheet(isPresented: $connectionSheet) { ConnectionView(link: link) }
        .confirmationDialog("현재 화면의 필기를 모두 지울까요?", isPresented: $clearConfirmation) {
            Button("모두 지우기", role: .destructive) { model.clear() }
        } message: { Text("실행 취소로 복원할 수 있습니다.") }
        .onAppear { if link.connectedName == nil { connectionSheet = true } }
    }

    /// Floats over the screen; folded it is only the home button, which a long press opens again.
    @ViewBuilder private var topBar: some View {
        Group {
            if barCollapsed { foldedBar } else { openBar }
        }
        .transition(.scale(scale: 0.6, anchor: .topLeading).combined(with: .opacity))
        .padding(.trailing, 16)
        .sensoryFeedback(.impact(weight: .light), trigger: barCollapsed)
    }

    private var foldedBar: some View {
        Image(systemName: "house").font(.system(size: 19, weight: .medium))
            .frame(width: 48, height: 48)
            .contentShape(Circle())
            .inkGlass(Circle())
            .onTapGesture(perform: goHome)
            .onLongPressGesture(minimumDuration: 0.4) { setCollapsed(false) }
            .accessibilityElement()
            .accessibilityLabel("처음 화면으로")
            .accessibilityHint("길게 누르면 상단 막대를 펼칩니다.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { goHome() }
            .accessibilityAction(named: "상단 막대 펼치기") { setCollapsed(false) }
    }

    private var openBar: some View {
        HStack(spacing: 4) {
            Button(action: goHome) { barIcon("house") }
                .accessibilityLabel("처음 화면으로")
            status
            connectionButton
            Button { withAnimation(.snappy) { model.toolsVisible.toggle() } } label: {
                barIcon(model.toolsVisible ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
            }
            .accessibilityLabel(model.toolsVisible ? "필기 도구 접기" : "필기 도구 펼치기")
            Button { setCollapsed(true) } label: { barIcon("chevron.up") }
                .accessibilityLabel("상단 막대 접기")
                .accessibilityHint("접으면 홈 버튼만 남고, 길게 누르면 다시 펼쳐집니다.")
        }
        .padding(4)
        .buttonStyle(.plain)
        .inkGlass(Capsule())
    }

    private var status: some View {
        HStack(spacing: 8) {
            Circle().fill(model.receiving ? Color.green : Color.secondary.opacity(0.6)).frame(width: 8, height: 8)
            Text(model.message).font(.subheadline).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }

    private var connectionButton: some View {
        Button { connectionSheet = true } label: {
            Label(link.connectedName ?? "맥 연결", systemImage: link.connectedName == nil ? "link" : "checkmark.circle")
                .font(.subheadline.weight(.medium)).lineLimit(1)
                .padding(.horizontal, 14).frame(height: 36)
                .background(.primary.opacity(0.08), in: Capsule())
                .contentShape(Capsule())
        }
    }

    private func barIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 19, weight: .medium))
            .frame(width: 44, height: 44).contentShape(Circle())
    }

    private func setCollapsed(_ collapsed: Bool) {
        withAnimation(.snappy) { barCollapsed = collapsed }
    }
}

/// Home picks a version; screen mode receives the Mac's screen; the library (서재) writes on the Mac server's documents (library/).
enum PadMode: String {
    case home, screen, library

    /// `-padMode screen|library` at launch opens that mode directly (for scripted checks); otherwise home.
    static var launch: PadMode {
        (UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["padMode"] as? String)
            .flatMap(PadMode.init(rawValue:)) ?? .home
    }
}

@main struct InkBridgePadApp: App {
    @StateObject private var model = PadModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var mode = PadMode.launch
    @State private var sidecarGuide = false
    @AppStorage(DocumentServer.key) private var serverURL = ""
    @AppStorage(Appearance.key) private var appearance = Appearance.system

    init() { DocumentServer.adoptLaunchArgument() }

    var body: some Scene {
        WindowGroup {
            Group {
                switch mode {
                case .home:
                    HomeView { version in
                        switch version {
                        case .sidecar: sidecarGuide = true
                        case .screen: mode = .screen
                        case .library: mode = .library
                        }
                    }
                case .screen: PadView(model: model, link: model.link, goHome: { mode = .home })
                case .library:
                    DocumentModeView(model: model, documents: model.documents, serverURL: $serverURL, leave: { mode = .home })
                }
            }
            .sheet(isPresented: $sidecarGuide) { SidecarGuide() }
            .onAppear { appearance.apply() }
            .onChange(of: appearance) { _, chosen in chosen.apply() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { model.persist() }
                if phase == .background { model.link.suspend() }
                if phase == .active, mode == .screen { model.link.start() }
            }
            // The Mac screen link stays off in the library; going home keeps it as it is.
            .onChange(of: mode) { _, newMode in
                switch newMode {
                case .library:
                    model.persist()
                    model.link.suspend()
                case .screen: model.link.start()
                case .home: model.persist()
                }
            }
        }
    }
}
