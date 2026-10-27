import SwiftUI

// 서재 (library) mode of InkBridge Pad: the Mac server's documents (library/) on shelves, each opened in a full-screen web view.

enum DocumentServer {
    static let key = "serverURL"

    /// An address given at launch (xcrun devicectl … -serverURL <url>) is kept for later launches from the home screen.
    static func adoptLaunchArgument() {
        if let given = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[key] as? String {
            UserDefaults.standard.set(given, forKey: key)
        }
    }
}

/// Connects the app's toolbar to the page (library/client/overlay.js): ink settings and commands go in,
/// undo state and connection status come back.
final class DocumentSession: ObservableObject {
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var hidden = false
    @Published private(set) var warn = false
    @Published private(set) var status = "연결 중"
    /// The open book is a converted PDF, slide deck or Word file, so it can go out as a PDF with its ink.
    @Published private(set) var canExportPdf = false
    weak var controller: WebViewController?
    private var tools: WritingTools?

    func apply(_ tools: WritingTools) {
        self.tools = tools
        push()
    }

    /// Sends the current pen, color, width and pen kind to the page; also called whenever a page loads.
    func push() {
        guard let tools else { return }
        let ink: [String: Any] = [
            "tool": tools.selected.rawValue, "color": String(format: "#%06X", tools.style.color),
            "width": tools.style.width, "kind": tools.penKind.rawValue, "finger": tools.fingerDrawing,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: ink), let json = String(data: data, encoding: .utf8) else { return }
        controller?.run("window.__pencilReview?.setInk?.(\(json))")
    }

    func run(_ command: String) {
        controller?.run("window.__pencilReview?.command?.('\(command)')")
    }

    func receive(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "ready": push()
        case "state":
            canUndo = message["canUndo"] as? Bool ?? false
            canRedo = message["canRedo"] as? Bool ?? false
            hidden = message["hidden"] as? Bool ?? false
            warn = message["warn"] as? Bool ?? false
            status = message["status"] as? String ?? ""
            canExportPdf = message["pdf"] as? Bool ?? false
        case "pdf":
            // The page made the PDF on the Mac and hands it over for the share sheet (save to Files, AirDrop, mail).
            guard let name = message["name"] as? String, let base64 = message["data"] as? String,
                  let data = Data(base64Encoded: base64) else { return }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent((name as NSString).lastPathComponent)
            do {
                try data.write(to: file, options: .atomic)
                controller?.share(file)
            } catch {
                controller?.run("window.__pencilReview?.toast?.('PDF를 기기에 저장하지 못했습니다')")
            }
        default: break
        }
    }
}

/// 서재: the shelf of books, and the book being written on with the same toolbar, settings and squeeze palette
/// as the Mac screen mode.
struct DocumentModeView: View {
    @ObservedObject var model: PadModel
    @ObservedObject var documents: DocumentSession
    /// An address given at launch (-serverURL) or saved before there were bookcases; it becomes a bookcase.
    @Binding var serverURL: String
    /// Returns to the home screen.
    var leave: () -> Void
    @AppStorage(Bookcases.key) private var stored = ""
    @State private var opened: Bookcase?
    @State private var book: Book?
    @State private var clearConfirmation = false
    @State private var editing: BookcaseEdit?
    @State private var reach: [UUID: BookcaseReach] = [:]

    private var bookcases: [Bookcase] { Bookcases.decode(stored) }

    var body: some View {
        ZStack {
            LibraryAisle(bookcases: bookcases, reach: reach, opened: opened, open: openBookcase, add: { editing = .add },
                         changeAddress: { editing = .address($0.id) }, rename: rename, remove: remove, leave: leave)
            if let opened, let server = LibraryServer(opened.address) {
                ZStack {
                    LibraryView(server: server, title: opened.title,
                                open: { picked in withAnimation(.smooth(duration: 0.3)) { book = picked } },
                                changeServer: { editing = .address(opened.id) },
                                leave: { withAnimation(.smooth(duration: 0.35)) { self.opened = nil } })
                    if let book {
                        reader(server.pageURL(book))
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .id("\(opened.id)|\(opened.address)")
                .transition(.opacity.combined(with: .scale(scale: 1.04)))
            }
        }
        .sheet(item: $editing) { edit in
            SetupView(title: edit.title, onSave: { save(edit, $0) }, onLeave: { editing = nil }, leaveTitle: "취소")
        }
        .onAppear(perform: adoptServerURL)
        .task {
            // Keeps each bookcase's connection state current while the library is open.
            while !Task.isCancelled {
                await checkAll()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    private func openBookcase(_ bookcase: Bookcase) {
        guard LibraryServer(bookcase.address) != nil else {
            editing = .address(bookcase.id)
            return
        }
        withAnimation(.smooth(duration: 0.35)) { opened = bookcase }
    }

    private func update(_ change: (inout [Bookcase]) -> Void) {
        var list = bookcases
        change(&list)
        stored = Bookcases.encode(list)
        if let id = opened?.id { opened = list.first { $0.id == id } }
    }

    private func save(_ edit: BookcaseEdit, _ url: URL) {
        let address = url.absoluteString
        switch edit {
        case .add:
            let added = Bookcase(address: address)
            update { $0.append(added) }
            Task { await check(added.id) }
        case .address(let id):
            update { list in
                if let i = list.firstIndex(where: { $0.id == id }) { list[i].address = address }
            }
            reach[id] = .checking
            Task { await check(id) }
        }
        editing = nil
    }

    private func rename(_ bookcase: Bookcase, _ name: String?) {
        update { list in
            if let i = list.firstIndex(where: { $0.id == bookcase.id }) { list[i].custom = name?.isEmpty == false ? name : nil }
        }
    }

    private func remove(_ bookcase: Bookcase) {
        update { $0.removeAll { $0.id == bookcase.id } }
    }

    private func adoptServerURL() {
        guard !serverURL.isEmpty else { return }
        if !bookcases.contains(where: { $0.address == serverURL }) {
            let address = serverURL
            update { $0.append(Bookcase(address: address)) }
        }
        serverURL = ""
    }

    private func checkAll() async {
        await withTaskGroup(of: Void.self) { group in
            for bookcase in bookcases { group.addTask { await check(bookcase.id) } }
        }
    }

    /// Asks a bookcase's Mac whether it is there, and picks up its current name for the end of the bookcase.
    private func check(_ id: UUID) async {
        guard let address = bookcases.first(where: { $0.id == id })?.address else { return }
        let info = await Bookcases.probe(address)
        // The address may have changed while asking.
        guard bookcases.first(where: { $0.id == id })?.address == address else { return }
        reach[id] = info == nil ? .offline : .online
        guard let name = info?.name else { return }
        update { list in
            if let i = list.firstIndex(where: { $0.id == id }), list[i].deviceName != name { list[i].deviceName = name }
        }
    }

    private func reader(_ url: URL) -> some View {
        let close = { withAnimation(.smooth(duration: 0.3)) { book = nil } }
        return ReviewWebView(startURL: url, session: documents, onPencil: model.handlePencil,
                             onChangeServer: { if let opened { editing = .address(opened.id) } }, onLeave: close)
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
                ToolbarDock(model: model, documents: documents, documentMode: true, leave: close,
                            clearConfirmation: $clearConfirmation)
            }
            .pencilPalette(model: model, documents: documents, documentMode: true)
            .onAppear { documents.apply(model.tools) }
            .onChange(of: model.tools) { _, tools in documents.apply(tools) }
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
    }
}

/// Adding a bookcase, or changing the server address of one.
enum BookcaseEdit: Identifiable {
    case add
    case address(UUID)

    var id: String {
        switch self {
        case .add: "add"
        case .address(let id): id.uuidString
        }
    }

    var title: String {
        switch self {
        case .add: "책장 추가"
        case .address: "서버 주소 바꾸기"
        }
    }
}

struct SetupView: View {
    var title = "서재"
    var onSave: (URL) -> Void
    var onLeave: (() -> Void)?
    var leaveTitle = "처음 화면으로"
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).font(.largeTitle.bold())
                Spacer()
                ConnectionHelpButton()
            }
            Text("맥에서 서재 서버(`node library/server.mjs <폴더>`)를 켜면 터미널에 ‘iPad 권장 주소’가 나옵니다. 토큰(?t=…)까지 포함한 주소를 넣어 주세요.")
                .foregroundStyle(.secondary)
            TextField("http://맥이름.local:5173/?t=…", text: $text)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(save)
            HStack(spacing: 12) {
                PasteButton(payloadType: String.self) { strings in
                    text = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? text
                }
                Button("연결", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.isEmpty)
                if let onLeave {
                    Button(leaveTitle, action: onLeave)
                }
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: 640)
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else {
            error = "http:// 또는 https://로 시작하는 주소를 넣어 주세요."
            return
        }
        onSave(url)
    }
}

struct ReviewWebView: UIViewControllerRepresentable {
    let startURL: URL
    let session: DocumentSession
    let onPencil: (UIPencilPreferredAction, CGPoint?, UIView?) -> Void
    let onChangeServer: () -> Void
    var onLeave: (() -> Void)?

    func makeUIViewController(context: Context) -> WebViewController {
        let controller = WebViewController(startURL: startURL)
        update(controller)
        return controller
    }

    func updateUIViewController(_ controller: WebViewController, context: Context) {
        update(controller)
        if controller.startURL != startURL { controller.load(startURL) }
    }

    private func update(_ controller: WebViewController) {
        controller.onChangeServer = onChangeServer
        controller.onLeave = onLeave
        controller.onPencil = onPencil
        controller.session = session
        session.controller = controller
    }
}

/// The ? next to a connection problem: how to start the Mac server and get its address onto the iPad.
struct ConnectionHelpButton: View {
    var host: String?
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "questionmark.circle").font(.title2)
        }
        .accessibilityLabel("연결하는 법")
        .sheet(isPresented: $showing) { ConnectionHelpView(host: host) }
    }
}

struct ConnectionHelpView: View {
    var host: String?
    @Environment(\.dismiss) private var dismiss
    private let command = "node library/server.mjs <문서 폴더>"

    var body: some View {
        NavigationStack {
            List {
                Section("처음 연결하기") {
                    step(1, "맥과 iPad를 같은 Wi-Fi에 연결합니다.")
                    step(2, "맥의 터미널에서 InkBridge 폴더로 가서 서버를 켭니다. 필기할 문서가 든 폴더를 지정합니다.")
                    HStack {
                        Text(command).font(.callout.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button("복사") { UIPasteboard.general.string = command }
                    }
                    step(3, "터미널에 나온 ‘iPad 권장 주소’(http://맥이름.local:5173/?t=…)를 복사합니다. 같은 Apple 계정이면 맥에서 복사한 것을 iPad에서 바로 붙여넣을 수 있습니다.")
                    step(4, "서재에서 ‘책장 추가’를 눌러 주소를 붙여넣고 ‘연결’을 누릅니다. 맥마다 책장이 하나씩 서고, 주소는 앱이 기억합니다.")
                }
                Section("연결이 안 될 때") {
                    check("터미널 창이 열려 있고 서버가 켜져 있는지", "창을 닫거나 맥이 잠자기에 들어가면 서버도 멈춥니다.")
                    check("iPad가 로컬 네트워크를 쓸 수 있는지", "설정 → 개인정보 보호 및 보안 → 로컬 네트워크에서 InkBridge Pad를 켭니다.")
                    check("맥 방화벽이 막고 있지 않은지", "처음 켤 때 node의 수신 연결을 묻는 창이 뜨면 허용합니다.")
                    check("주소가 그대로인지", "포트를 바꾸거나 --new-token으로 켜면 주소가 바뀝니다. 터미널의 새 주소를 다시 넣어 주세요.")
                    if let host, !host.isEmpty {
                        LabeledContent("지금 연결하려는 맥", value: host)
                    }
                }
            }
            .navigationTitle("맥 서버에 연결하는 법")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } } }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: "\(n).circle.fill").foregroundStyle(.tint) }
    }

    private func check(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(detail).foregroundStyle(.secondary)
        }
    }
}
