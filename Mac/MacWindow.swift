import SwiftUI

/// What the Mac does for the iPad: send its screen (iPad 맥 화면), or open a folder as its bookcase (iPad 서재).
enum MacMode: CaseIterable, Identifiable {
    case screen, library
    var id: Self { self }

    init?(argument: String?) {
        switch argument {
        case "screen": self = .screen
        case "library": self = .library
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .screen: "화면 보내기"
        case .library: "책장 열기"
        }
    }

    var detail: String {
        switch self {
        case .screen: "이 맥 화면을 iPad로 보내고\nPencil 필기를 화면 위에 받기"
        case .library: "문서 폴더를 iPad 서재에\n이 맥의 책장으로 세우기"
        }
    }

    var symbol: String {
        switch self {
        case .screen: "display"
        case .library: "books.vertical"
        }
    }
}

/// The start screen with the two modes, like the iPad's; each mode opens its own page.
struct MacWindow: View {
    @ObservedObject var model: HostModel
    @ObservedObject var link: PeerLink
    @ObservedObject var library: LibraryHost
    /// `-macMode screen|library` opens that page at launch, like `-padMode` on the iPad.
    @State private var mode = MacMode(argument: UserDefaults.standard.string(forKey: "macMode"))

    var body: some View {
        Group {
            switch mode {
            case nil: home
            case .screen: ModePage(mode: .screen, back: back) { ScreenPage(model: model, link: link) }
            case .library: ModePage(mode: .library, back: back) { LibraryPage(library: library) }
            }
        }
        .frame(width: 640)
        .background { InkBackdrop(moving: false) }
        .onAppear {
            // `-appearance light|dark` overrides the system look for that launch.
            switch UserDefaults.standard.string(forKey: "appearance") {
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            default: break
            }
        }
    }

    private func back() { withAnimation(.smooth(duration: 0.3)) { mode = nil } }

    private var home: some View {
        VStack(spacing: 34) {
            InkBridgeLogo().padding(.top, 44)
            HStack(spacing: 18) {
                ForEach(MacMode.allCases) { mode in
                    ModeCard(mode: mode, status: status(mode), active: active(mode)) {
                        withAnimation(.smooth(duration: 0.3)) { self.mode = mode }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 36)
        }
        .overlay(alignment: .topTrailing) { SettingsButton().padding(.trailing, 20).padding(.top, 16) }
        .transition(.opacity)
    }

    private func status(_ mode: MacMode) -> String {
        switch mode {
        case .screen:
            if model.streaming { return "보내는 중" }
            return link.connectedName.map { "\($0) 연결됨" } ?? "연결 코드 \(link.code)"
        case .library:
            switch library.state {
            case .running: return "열려 있음 · \(library.folder?.lastPathComponent ?? "")"
            case .starting: return "여는 중…"
            case .failed: return "열지 못함"
            case .stopped: return "닫혀 있음"
            }
        }
    }

    private func active(_ mode: MacMode) -> Bool {
        switch mode {
        case .screen: model.streaming || link.connectedName != nil
        case .library: library.running
        }
    }
}

private struct ModeCard: View {
    let mode: MacMode
    let status: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 28, weight: .light))
                    .frame(width: 56, height: 56)
                    .background(.primary.opacity(0.1), in: Circle())
                VStack(alignment: .leading, spacing: 6) {
                    Text(mode.title).font(.title2.weight(.semibold))
                    Text(mode.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Circle().fill(active ? Color.green : Color.primary.opacity(0.3)).frame(width: 7, height: 7)
                    Text(status).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.primary.opacity(0.07), in: Capsule())
            }
            .foregroundStyle(.primary)
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: 28))
        }
        .buttonStyle(.plain)
        .macSurface(RoundedRectangle(cornerRadius: 28), interactive: true)
    }
}

private struct SettingsButton: View {
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { Image(systemName: "gearshape").font(.title3).frame(width: 36, height: 36) }
            .buttonStyle(.plain)
            .macSurface(Circle(), interactive: true)
            .help("설정")
            .popover(isPresented: $open, arrowEdge: .bottom) { MacSettings() }
    }
}

/// A mode's page: back to the start screen, its title, then its panels.
private struct ModePage<Content: View>: View {
    let mode: MacMode
    let back: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Button(action: back) { Image(systemName: "chevron.left").font(.title3.weight(.medium)).frame(width: 36, height: 36) }
                    .buttonStyle(.plain)
                    .macSurface(Circle(), interactive: true)
                    .help("처음으로")
                Image(systemName: mode.symbol).font(.title2.weight(.light))
                Text(mode.title).font(.largeTitle.bold())
                Spacer()
                SettingsButton()
            }
            content
        }
        .padding(.horizontal, 28)
        .padding(.top, 40)
        .padding(.bottom, 28)
        .transition(.opacity)
    }
}

private struct ScreenPage: View {
    @ObservedObject var model: HostModel
    @ObservedObject var link: PeerLink

    var body: some View {
        MacPanel(link.connectedName == nil ? "iPad에서 입력할 연결 코드" : "연결된 iPad",
                 footer: link.connectedName == nil ? "iPad의 InkBridge Pad → 맥 화면에서 이 맥을 고르고 코드를 넣습니다." : nil) {
            HStack {
                Text(link.connectedName ?? link.code)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                Spacer()
                if link.connectedName != nil { Button("연결 해제") { model.stop(); link.disconnect() } }
            }
        }
        MacPanel("보낼 화면") {
            HStack {
                if model.displays.isEmpty {
                    Button("화면 목록 불러오기") { model.loadDisplays() }
                } else {
                    Picker("보낼 화면", selection: $model.selected) {
                        ForEach(model.displays, id: \.displayID) { display in
                            Text(model.displayName(display)).tag(display.displayID)
                        }
                    }
                    .labelsHidden()
                    .disabled(model.streaming)
                    Button { model.loadDisplays() } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(model.streaming).help("화면 목록 새로고침")
                }
                if model.busy { ProgressView().controlSize(.small) }
            }
            .disabled(model.busy)
            Text(model.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Label(link.status, systemImage: link.connectedName == nil ? "ipad" : "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button(model.streaming ? "보내기 중지" : "화면 보내기") {
                if model.streaming { model.stop() } else { model.start() }
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(model.busy || (!model.streaming && (link.connectedName == nil || model.displays.isEmpty)))
        }
    }
}

private struct LibraryPage: View {
    @ObservedObject var library: LibraryHost
    @State private var copied = false

    var body: some View {
        MacPanel("문서 폴더", footer: "PDF·PowerPoint·Keynote·Word·Pages·HTML 문서가 iPad 서재의 이 맥 책장에 꽂힙니다.") {
            HStack {
                Label(library.folder?.lastPathComponent ?? "폴더를 고르지 않았습니다", systemImage: "folder")
                    .font(.body.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                    .help(library.folder?.path ?? "")
                Spacer()
                if library.folder != nil { Button { library.reveal() } label: { Image(systemName: "magnifyingglass") }.help("Finder에서 보기") }
                Button(library.folder == nil ? "폴더 고르기…" : "폴더 바꾸기…") { library.chooseFolder() }
            }
        }
        switch library.state {
        case .running(let address, let local):
            MacPanel("iPad 서재 → 책장 추가에 넣을 주소",
                     footer: "복사한 주소는 같은 Apple 계정의 iPad에 그대로 붙여 넣을 수 있습니다(유니버설 클립보드). 맥이 잠들면 iPad에서는 연결 안 됨으로 보입니다.") {
                Text(address).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(copied ? "복사됨" : "주소 복사") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(address, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    }
                    Button("맥에서 열기") { if let url = URL(string: local) { NSWorkspace.shared.open(url) } }
                }
            }
        case .failed(let message):
            MacPanel {
                Label { Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                    icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
        case .starting, .stopped:
            EmptyView()
        }
        HStack {
            Label(library.state == .starting ? "여는 중…" : library.running ? "열려 있음" : "닫혀 있음",
                  systemImage: library.running ? "books.vertical.fill" : "books.vertical")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button(library.running ? "책장 닫기" : "책장 열기") {
                if library.running { library.stop() } else { library.start() }
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(library.folder == nil)
        }
    }
}
