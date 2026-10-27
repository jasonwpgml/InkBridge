import SwiftUI
import MultipeerConnectivity

struct ConnectionView: View {
    @ObservedObject var link: PeerLink
    @Environment(\.dismiss) private var dismiss
    @State private var selected: MCPeerID?
    @State private var code = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("가까운 맥") {
                    if link.nearby.isEmpty {
                        Text("맥에서 InkBridge Mac을 열어 주세요. 두 기기의 Wi-Fi와 로컬 네트워크 접근을 켜야 합니다.")
                            .foregroundStyle(.secondary)
                        ProgressView("맥 찾는 중")
                    }
                    ForEach(link.nearby, id: \.self) { peer in
                        Button { selected = peer } label: {
                            HStack {
                                Label(peer.displayName, systemImage: "laptopcomputer")
                                Spacer()
                                if selected == peer { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
                Section("맥에 표시된 6자리 코드") {
                    TextField("연결 코드", text: $code).keyboardType(.numberPad)
                        .onChange(of: code) { _, value in code = String(value.filter(\.isNumber).prefix(6)) }
                    Button("연결") { if let selected { link.connect(to: selected, code: code) } }
                        .disabled(selected == nil || code.count != 6 || link.connectedName != nil)
                }
                Section { Text(link.status).foregroundStyle(.secondary) }
                if link.connectedName != nil { Button("연결 해제", role: .destructive) { link.disconnect() } }
            }
            .navigationTitle("맥 연결")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
            .onChange(of: link.connectedName) { _, name in if name != nil { dismiss() } }
        }
    }
}

struct PadView: View {
    @ObservedObject var model: PadModel
    @ObservedObject var link: PeerLink
    var goHome: () -> Void
    @State private var connectionSheet = false
    @State private var clearConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Button(action: goHome) { Label("InkBridge", systemImage: "house").font(.headline) }
                    .accessibilityLabel("처음 화면으로")
                Text(model.receiving ? "화면 수신 중" : "전송 대기").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { connectionSheet = true } label: {
                    Label(link.connectedName ?? "맥 연결", systemImage: link.connectedName == nil ? "link" : "checkmark.circle")
                }
                Button { model.toolsVisible.toggle() } label: {
                    Image(systemName: model.toolsVisible ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                        .font(.title3).frame(width: 44, height: 44)
                }
                    .accessibilityLabel(model.toolsVisible ? "필기 도구 접기" : "필기 도구 펼치기")
            }.padding(.horizontal, 20).padding(.vertical, 12).inkGlass(Rectangle())
            ZStack {
                CanvasStage(model: model)
                if model.geometry == nil {
                    ContentUnavailableView("맥 화면 위에 바로 쓰기", systemImage: "pencil.tip.crop.circle",
                                           description: Text("맥을 연결한 뒤 Mac 앱에서 화면 전송을 시작하세요."))
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                ToolbarDock(model: model, documents: model.documents, clearConfirmation: $clearConfirmation)
            }
            Text(model.message).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).padding(.horizontal).padding(.vertical, 6)
        }
        .pencilPalette(model: model, documents: model.documents, documentMode: false)
        .sheet(isPresented: $connectionSheet) { ConnectionView(link: link) }
        .confirmationDialog("현재 화면의 필기를 모두 지울까요?", isPresented: $clearConfirmation) {
            Button("모두 지우기", role: .destructive) { model.clear() }
        } message: { Text("실행 취소로 복원할 수 있습니다.") }
        .onAppear { if link.connectedName == nil { connectionSheet = true } }
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
