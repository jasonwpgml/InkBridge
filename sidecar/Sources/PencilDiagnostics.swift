import AppKit

final class PencilDiagnostics {
    static let eventMask: NSEvent.EventTypeMask = [.changeMode, .leftMouseDown, .leftMouseDragged,
        .leftMouseUp, .rightMouseDown, .otherMouseDown, .otherMouseUp, .tabletPoint,
        .tabletProximity, .pressure, .systemDefined, .gesture]

    private(set) var summary = "먼저 Pencil 입력 진단을 실행하세요."
    private var panel: PassivePanel?
    private var label: NSTextField?
    private var timer: Timer?
    private var deadline: TimeInterval = 0
    private var counts: [String: Int] = [:]
    private var penSamples = 0
    private var maximumPressure: Float = 0

    func record(_ event: NSEvent) {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return }
        let name: String
        switch event.type {
        case .changeMode: name = "changeMode (더블탭 후보)"
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp: name = "그리기/클릭"
        case .otherMouseDown, .otherMouseUp: name = "기타 버튼 \(event.buttonNumber)"
        case .systemDefined: name = "시스템 이벤트 subtype \(event.subtype.rawValue)"
        default: name = String(describing: event.type)
        }
        counts[name, default: 0] += 1
        if event.type == .tabletPoint || event.subtype == .tabletPoint {
            penSamples += 1
            maximumPressure = max(maximumPressure, event.pressure)
        }
    }

    func recordGesture(_ name: String) {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return }
        counts[name, default: 0] += 1
    }

    func start(below toolbar: NSRect, state: @escaping () -> String) {
        timer?.invalidate()
        panel?.close()
        counts = [:]; penSamples = 0; maximumPressure = 0
        deadline = ProcessInfo.processInfo.systemUptime + 30
        let window = PassivePanel(contentRect: NSRect(x: toolbar.minX, y: toolbar.minY - 360,
                                                       width: 510, height: 340),
                                  styleMask: [.titled, .closable, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        window.title = "Pencil 입력 진단 · 30초"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let text = NSTextField(wrappingLabelWithString: "")
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.frame = NSRect(x: 18, y: 18, width: 474, height: 304)
        window.contentView?.addSubview(text)
        panel = window; label = text
        window.orderFrontRegardless()
        update(state: state())
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.update(state: state())
            if ProcessInfo.processInfo.systemUptime >= self.deadline || self.panel?.isVisible != true {
                self.deadline = 0
                timer.invalidate()
            }
        }
    }

    private func update(state: String) {
        let remaining = max(0, Int(ceil(deadline - ProcessInfo.processInfo.systemUptime)))
        let entries = counts.keys.sorted().map { "\($0): \(counts[$0]!)" }.joined(separator: "\n")
        summary = "\(remaining > 0 ? "수신 확인 중 · \(remaining)초" : "수신 확인 완료")\n필기판에 한 획을 쓰고, 더블탭과 스퀴즈를 차례로 해보세요.\n\n\(state)\n\n펜으로 식별된 입력: \(penSamples) · 최대 압력: \(String(format: "%.2f", maximumPressure))\n\(entries.isEmpty ? "입력 이벤트 없음" : entries)\n\n이 앱에 도착한 입력만 집계합니다. 키보드·화면·필기 좌표는 저장하지 않습니다. SwiftUI 스퀴즈 완료가 표시되면 공식 제스처가 도착한 것입니다."
        label?.stringValue = summary
    }
}
