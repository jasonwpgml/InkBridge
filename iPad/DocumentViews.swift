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
    @Binding var serverURL: String
    /// Returns to the home screen.
    var leave: () -> Void
    @State private var book: Book?
    @State private var clearConfirmation = false

    var body: some View {
        if let server = LibraryServer(serverURL) {
            ZStack {
                LibraryView(server: server, open: { opened in withAnimation(.smooth(duration: 0.3)) { book = opened } },
                            changeServer: { serverURL = "" }, leave: leave)
                if let book {
                    reader(server.pageURL(book))
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .id(serverURL)
        } else {
            SetupView(onSave: { serverURL = $0.absoluteString }, onLeave: leave)
        }
    }

    private func reader(_ url: URL) -> some View {
        let close = { withAnimation(.smooth(duration: 0.3)) { book = nil } }
        return ReviewWebView(startURL: url, session: documents, onPencil: model.handlePencil,
                             onChangeServer: { serverURL = "" }, onLeave: close)
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

struct SetupView: View {
    var onSave: (URL) -> Void
    var onLeave: (() -> Void)?
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("서재").font(.largeTitle.bold())
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
                    Button("처음 화면으로", action: onLeave)
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
