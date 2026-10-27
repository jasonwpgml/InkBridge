import SwiftUI
import ScreenCaptureKit

final class HostModel: ObservableObject {
    let link = PeerLink(host: true, name: Host.current().localizedName ?? "InkBridge Mac")
    @Published var displays: [SCDisplay] = []
    @Published var selected: CGDirectDisplayID = 0
    @Published var streaming = false
    @Published var busy = false
    @Published var message = "보낼 화면을 고르고, iPad에서 위 연결 코드를 입력하세요."
    private var content: SCShareableContent?
    private let capture = ScreenStreamer()
    private let overlay = InkOverlay()
    private var geometry: ScreenGeometry?
    private var screenObserver: NSObjectProtocol?
    private var startID = UUID()

    init() {
        link.received = { [weak self] kind, data in
            guard let self, kind == .ink, self.streaming else { return }
            do {
                let update = try JSONDecoder().decode(InkUpdate.self, from: data)
                try self.overlay.apply(update)
            } catch { self.message = "필기 수신 실패: \(error.localizedDescription)" }
        }
        link.connectionChanged = { [weak self] connected in
            guard let self else { return }
            if connected { self.sendGeometry() }
            else { self.stop() }
        }
        capture.frameReady = { [weak self] jpeg in
            guard let self, self.streaming, self.link.connectedName != nil, let geometry = self.geometry else { return }
            if let data = try? JSONEncoder().encode(ScreenFrame(sourceID: geometry.sourceID, jpeg: jpeg)) {
                self.link.send(.video, body: data, latest: true)
            }
        }
        capture.failed = { [weak self] error in
            self?.stop(); self?.message = "화면 전송이 중지되었습니다: \(error)"
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self, self.streaming else { return }
                self.stop(); self.message = "화면 구성이 바뀌었습니다. 화면을 다시 선택해 주세요."
            }
        link.start()
    }

    func loadDisplays() {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let value = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                content = value
                displays = value.displays
                if !displays.contains(where: { $0.displayID == selected }) {
                    selected = displays.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 })?.displayID ?? displays.first?.displayID ?? 0
                }
                message = "전송할 화면을 선택한 뒤 시작하세요."
            } catch { message = "화면 목록을 읽지 못했습니다. 시스템 설정의 화면 기록 권한을 확인하세요.\n\(error.localizedDescription)" }
        }
    }

    func displayName(_ display: SCDisplay) -> String {
        let name = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }?.localizedName ?? "디스플레이 \(display.displayID)"
        return "\(name) · \(display.width)×\(display.height)"
    }

    func start() {
        guard let content, let display = displays.first(where: { $0.displayID == selected }), !busy else { return }
        busy = true
        let request = UUID()
        startID = request
        Task { @MainActor in
            defer { busy = false }
            do {
                let scale = min(1, 1600.0 / Double(max(display.width, display.height)))
                let width = (Double(display.width) * scale).rounded()
                let height = (Double(display.height) * scale).rounded()
                let uuid = CGDisplayCreateUUIDFromDisplayID(display.displayID).takeRetainedValue()
                let source = CFUUIDCreateString(nil, uuid) as String
                let value = ScreenGeometry(sourceID: source + "-\(Int(width))x\(Int(height))", name: displayName(display), width: width, height: height)
                geometry = value
                overlay.show(displayID: selected, geometry: value)
                try await capture.start(display: display, content: content, geometry: value)
                guard startID == request, link.connectedName != nil else {
                    try await capture.stop(); overlay.hide(); geometry = nil
                    return
                }
                streaming = true
                sendGeometry()
                message = "맥 화면 전송 중 · iPad에서 필기하면 이 화면에 표시됩니다."
            } catch { overlay.hide(); geometry = nil; message = "화면 전송 실패: \(error.localizedDescription)" }
        }
    }

    private func sendGeometry() {
        guard streaming, let geometry, let data = try? JSONEncoder().encode(geometry) else { return }
        link.send(.geometry, body: data)
    }

    func stop() {
        startID = UUID()
        guard streaming || busy else { return }
        streaming = false; overlay.hide(); geometry = nil
        link.send(.stopped)
        Task { try? await capture.stop() }
        message = "화면 전송 중지 · 필기는 iPad에 보관됩니다."
    }
}

@main struct InkBridgeMacApp: App {
    @StateObject private var model = HostModel()
    @StateObject private var library = LibraryHost()
    var body: some Scene {
        WindowGroup("InkBridge Mac") { MacWindow(model: model, link: model.link, library: library) }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
    }
}
