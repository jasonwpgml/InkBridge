import AppKit

/// Runs the 서재 server (library/server.mjs, bundled with the app) on a folder the user picks, with the Mac's own Node.
final class LibraryHost: ObservableObject {
    enum State: Equatable {
        case stopped
        case starting
        /// `address` is the one to give the iPad (`<name>.local:<port>/?t=<token>`), `local` the one for this Mac.
        case running(address: String, local: String)
        case failed(String)
    }

    @Published private(set) var state = State.stopped
    @Published private(set) var folder: URL?
    private var process: Process?
    private var output = ""
    /// Output and exits of an earlier attempt (a busy port) are ignored.
    private var attempt = UUID()
    private var stopping = false
    /// Start again once the running server has stopped (the folder changed).
    private var restart = false

    private static let folderKey = "libraryFolder"
    private static let portKey = "libraryPort"
    /// Set while the server runs, so it opens again with the app.
    private static let autoStartKey = "libraryAutoStart"
    private static let pidKey = "libraryPID"

    init() {
        folder = UserDefaults.standard.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.process?.terminate()
        }
        if UserDefaults.standard.bool(forKey: Self.autoStartKey) { start() }
    }

    var running: Bool {
        switch state {
        case .starting, .running: true
        default: false
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "이 폴더로 서재 열기"
        panel.message = "서재에 꽂을 문서(PDF·PowerPoint·Word·HTML)가 있는 폴더를 고르세요."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
        UserDefaults.standard.set(url.path, forKey: Self.folderKey)
        if process != nil {
            restart = true
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard let folder, process == nil else { return }
        guard let node = Self.findNode() else {
            state = .failed("이 맥에서 Node.js를 찾지 못했습니다. 터미널에서 brew install node로 설치한 뒤 다시 여세요.")
            return
        }
        let server: URL
        do { server = try Self.prepareServer() } catch {
            state = .failed("서재 서버 파일을 준비하지 못했습니다: \(error.localizedDescription)")
            return
        }
        Self.stopLeftover()
        let saved = UserDefaults.standard.integer(forKey: Self.portKey)
        launch(node: node, server: server, folder: folder, port: saved > 0 ? saved : 5173, tries: 10)
    }

    func stop() {
        UserDefaults.standard.set(false, forKey: Self.autoStartKey)
        guard let process else { state = .stopped; return }
        stopping = true
        process.terminate()
    }

    func reveal() {
        if let folder { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
    }

    private func launch(node: URL, server: URL, folder: URL, port: Int, tries: Int) {
        let process = Process()
        process.executableURL = node
        process.arguments = [server.path, folder.path, "--port", String(port)]
        process.currentDirectoryURL = server.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(node.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let id = UUID()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            DispatchQueue.main.async { if self?.attempt == id { self?.received(text, port: port) } }
        }
        process.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            // What the server printed last (why it stopped) may not have been handed over yet.
            let rest = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async {
                guard let self, self.attempt == id else { return }
                self.received(rest, port: port)
                self.ended(node: node, server: server, folder: folder, port: port, tries: tries)
            }
        }
        attempt = id
        output = ""
        stopping = false
        state = .starting
        do {
            try process.run()
            self.process = process
            UserDefaults.standard.set(Int(process.processIdentifier), forKey: Self.pidKey)
        } catch {
            state = .failed("서재 서버를 열지 못했습니다: \(error.localizedDescription)")
        }
    }

    private func received(_ text: String, port: Int) {
        output += text
        guard state == .starting else { return }
        // server.mjs prints the iPad address on the line after "iPad 권장 주소", and this Mac's on the line after "맥에서".
        let lines = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        func line(after marker: String) -> String? {
            guard let i = lines.firstIndex(where: { $0.hasPrefix(marker) }), i + 1 < lines.count, lines[i + 1].hasPrefix("http") else { return nil }
            return lines[i + 1]
        }
        guard let address = line(after: "iPad 권장 주소"), let local = line(after: "맥에서") else { return }
        state = .running(address: address, local: local)
        UserDefaults.standard.set(port, forKey: Self.portKey)
        UserDefaults.standard.set(true, forKey: Self.autoStartKey)
    }

    private func ended(node: URL, server: URL, folder: URL, port: Int, tries: Int) {
        process = nil
        UserDefaults.standard.removeObject(forKey: Self.pidKey)
        if stopping {
            state = .stopped
            if restart { restart = false; start() }
        } else if state == .starting, output.contains("이미 다른 프로그램이 쓰고 있습니다"), tries > 1 {
            launch(node: node, server: server, folder: folder, port: port + 1, tries: tries - 1)
        } else {
            let tail = output.split(separator: "\n").suffix(4).joined(separator: "\n")
            state = .failed("서재 서버가 멈췄습니다." + (tail.isEmpty ? "" : "\n\(tail)"))
        }
    }

    /// A server this app started and lost (the app crashed or was killed) still holds the port; the iPad's bookcase
    /// keeps that port, so stop it rather than moving to the next one.
    private static func stopLeftover() {
        let pid = pid_t(UserDefaults.standard.integer(forKey: pidKey))
        guard pid > 0 else { return }
        UserDefaults.standard.removeObject(forKey: pidKey)
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
              URL(fileURLWithPath: String(cString: path)).lastPathComponent == "node" else { return }
        kill(pid, SIGTERM)
        usleep(300_000)
    }

    /// Copies the bundled server to Application Support and returns its server.mjs. It cannot run from inside the app:
    /// it compiles its Swift helpers into bin/ next to itself on first use, which would break the app's signature.
    private static func prepareServer() throws -> URL {
        let files = FileManager.default
        guard let bundled = Bundle.main.url(forResource: "library", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "앱 안에 서재 서버가 없습니다. scripts/build-mac.sh로 다시 빌드하세요."])
        }
        let dir = try files.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "InkBridge/library", directoryHint: .isDirectory)
        try files.createDirectory(at: dir, withIntermediateDirectories: true)
        // bin/ is left alone: the helpers are rebuilt only when their sources change.
        for name in try files.contentsOfDirectory(atPath: bundled.path) {
            let target = dir.appending(path: name)
            if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
            try files.copyItem(at: bundled.appending(path: name), to: target)
        }
        return dir.appending(path: "server.mjs")
    }

    /// Apps opened from Finder do not get the shell's PATH, so look where Homebrew, fnm and Volta put Node, then ask a
    /// login shell. fnm hands shells a temporary link, so the real file is used.
    private static func findNode() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let known = [
            "/opt/homebrew/bin/node", "/usr/local/bin/node",
            "\(home)/.local/share/fnm/aliases/default/bin/node",
            "\(home)/Library/Application Support/fnm/aliases/default/bin/node",
            "\(home)/.volta/bin/node",
        ]
        if let path = known.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path).resolvingSymlinksInPath()
        }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v node"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        shell.waitUntilExit()
        let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }
}
