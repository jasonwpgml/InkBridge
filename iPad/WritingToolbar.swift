import SwiftUI
import UIKit

extension UIColor {
    convenience init(inkRGB: UInt32) {
        self.init(red: CGFloat((inkRGB >> 16) & 255) / 255,
                  green: CGFloat((inkRGB >> 8) & 255) / 255,
                  blue: CGFloat(inkRGB & 255) / 255, alpha: 1)
    }

    var inkRGB: UInt32 {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let rgb = [red, green, blue].map { UInt32((min(max($0, 0), 1) * 255).rounded()) }
        return rgb[0] << 16 | rgb[1] << 8 | rgb[2]
    }
}

private struct InkSwatch: Identifiable {
    let name: String
    let rgb: UInt32
    var id: UInt32 { rgb }
    var color: Color { Color(UIColor(inkRGB: rgb)) }

    static func isLight(_ rgb: UInt32) -> Bool {
        let red = Double((rgb >> 16) & 255), green = Double((rgb >> 8) & 255), blue = Double(rgb & 255)
        return (0.299 * red + 0.587 * green + 0.114 * blue) / 255 > 0.65
    }

    static let palette: [InkSwatch] = [
        .init(name: "파랑", rgb: 0x2878EB), .init(name: "빨강", rgb: 0xE65353),
        .init(name: "초록", rgb: 0x279D79), .init(name: "노랑", rgb: 0xF5CC38),
        .init(name: "검정", rgb: 0x20232A), .init(name: "흰색", rgb: 0xFFFFFF),
        .init(name: "보라", rgb: 0x9664D8), .init(name: "분홍", rgb: 0xE47FA7),
        .init(name: "주황", rgb: 0xEB903C), .init(name: "하늘", rgb: 0x52BBD4),
        .init(name: "연두", rgb: 0xA4C867), .init(name: "회색", rgb: 0x858A96)
    ]

    /// The first six colors, with the last slot showing the current color when it is not among them.
    static func quick(current: UInt32) -> [InkSwatch] {
        var colors = Array(palette.prefix(6))
        if !colors.contains(where: { $0.rgb == current }) { colors[5] = InkSwatch(name: "선택한 색상", rgb: current) }
        return colors
    }
}

struct WritingToolbar: View {
    @ObservedObject var model: PadModel
    /// Undo, redo and the ⋯ commands go to the page in document mode, to PencilKit in screen mode.
    @ObservedObject var documents: DocumentSession
    var documentMode = false
    var leave: (() -> Void)?
    @Binding var clearConfirmation: Bool
    @AppStorage("opaqueTools") private var opaqueTools = false
    @State private var settingsVisible = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ViewThatFits(in: .horizontal) {
            if !dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: 8) {
                    toolButtons
                    separator
                    inkControls
                    separator
                    historyButtons
                }
            }
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    toolButtons
                    Spacer(minLength: 8)
                    historyButtons
                }
                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { inkControls }
                    VStack(spacing: 4) { inkControls }
                }
            }
        }
        .padding(10)
        .inkGlass(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
        .buttonStyle(.plain)
        .popover(isPresented: $settingsVisible, arrowEdge: .bottom) {
            WritingToolOptions(model: model)
                .presentationCompactAdaptation(.popover)
        }
        .onChange(of: model.tools.selected) { _, _ in settingsVisible = false }
    }

    private var separator: some View {
        Rectangle().fill(.primary.opacity(0.1)).frame(width: 1, height: 28)
    }

    private var quickColors: [InkSwatch] { InkSwatch.quick(current: model.tools.style.color) }

    private var toolButtons: some View {
        HStack(spacing: 4) {
            ForEach(WritingTool.allCases, id: \.self) { tool in
                let selected = model.tools.selected == tool
                Button {
                    if selected { settingsVisible.toggle() }
                    else { model.tools.select(tool) }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 21, weight: .medium))
                        HStack(spacing: 2) {
                            Text(tool.title).font(.system(size: 10, weight: .medium))
                            if selected {
                                Image(systemName: "chevron.up").font(.system(size: 6, weight: .bold))
                            }
                        }
                    }
                    .frame(width: 54, height: 54)
                    .background(selected ? Color.primary.opacity(0.08) : .clear,
                                in: RoundedRectangle(cornerRadius: 15))
                    .overlay(alignment: .top) {
                        if selected {
                            Capsule().fill(tool == .eraser ? .secondary : Color(UIColor(inkRGB: model.tools.style.color)))
                                .frame(width: 16, height: 3).offset(y: 3)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(tool.title)
                .accessibilityValue(selected ? "선택됨" : "")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityHint(selected ? "한 번 더 누르면 설정이 열립니다." : "필기 도구를 전환합니다.")
                .accessibilityIdentifier("tool.\(tool.rawValue)")
            }
        }
    }

    @ViewBuilder private var inkControls: some View {
        if model.tools.selected == .eraser {
            HStack(spacing: 10) {
                Image(systemName: "eraser").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("획 단위로 지우기").font(.subheadline.weight(.medium))
                    Text("선을 터치하면 한 획이 지워져요").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { model.tools.toggleEraser() } label: {
                    Label("\(model.tools.previousInk.title)으로", systemImage: "arrow.uturn.backward")
                        .font(.caption.weight(.medium)).padding(.horizontal, 10).frame(minHeight: 44)
                        .background(.primary.opacity(0.06), in: Capsule())
                }.accessibilityIdentifier("returnToInk")
            }.frame(minWidth: 310, idealWidth: 404, maxWidth: 404, minHeight: 44)
        } else {
            HStack(spacing: 0) {
                ForEach(quickColors) { swatch in
                    SwatchButton(swatch: swatch, selected: model.tools.style.color == swatch.rgb) {
                        if model.tools.style.color == swatch.rgb { settingsVisible = true }
                        else { model.tools.setColor(swatch.rgb) }
                    }
                }
            }
            HStack(spacing: 0) {
                ForEach(model.tools.selected.widths, id: \.self) { width in
                    WidthButton(width: width, selected: model.tools.style.width == width,
                                highlighter: model.tools.selected == .highlighter) {
                        if model.tools.style.width == width { settingsVisible = true }
                        else { model.tools.setWidth(width) }
                    }
                }
            }
        }
    }

    private var historyButtons: some View {
        HStack(spacing: 0) {
            Button { documentMode ? documents.run("undo") : model.undo() } label: { actionIcon("arrow.uturn.backward") }
                .disabled(!(documentMode ? documents.canUndo : model.canUndo)).accessibilityLabel("실행 취소")
                .keyboardShortcut("z", modifiers: .command)
            Button { documentMode ? documents.run("redo") : model.redo() } label: { actionIcon("arrow.uturn.forward") }
                .disabled(!(documentMode ? documents.canRedo : model.canRedo)).accessibilityLabel("다시 실행")
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Menu {
                if documentMode { Section(documents.status) {} }
                Button { settingsVisible = true } label: { Label("\(model.tools.selected.title) 설정", systemImage: "slider.horizontal.3") }
                Toggle("손가락으로도 필기", isOn: $model.tools.fingerDrawing)
                Toggle(isOn: $opaqueTools) { Label("불투명 모드", systemImage: "circle.lefthalf.filled") }
                Button { withAnimation(.snappy) { model.toolsVisible = false } } label: { Label("도구 막대 접기", systemImage: "chevron.down") }
                Divider()
                if documentMode { documentCommands }
                else { Button("필기 모두 지우기", role: .destructive) { clearConfirmation = true } }
            } label: { actionIcon("ellipsis").overlay(alignment: .topTrailing) { if documentMode && documents.warn { warnDot } } }
                .accessibilityLabel("필기 도구 더보기")
                .accessibilityIdentifier("tool.more")
        }
    }

    @ViewBuilder private var documentCommands: some View {
        Button { documents.run("toggleHidden") } label: {
            Label(documents.hidden ? "필기 보이기" : "필기 숨기기", systemImage: documents.hidden ? "eye" : "eye.slash")
        }
        Section("저장") {
            Button("이 페이지 필기 저장") { documents.run("savePage") }
            Button("이 문서 필기 전체 저장") { documents.run("saveDocument") }
            if documents.canExportPdf {
                Button { documents.run("exportPdf") } label: { Label("PDF로 내보내기 (필기 포함)", systemImage: "square.and.arrow.up") }
            }
        }
        Section("지우기") {
            Button("이 페이지 필기 지우기", role: .destructive) { documents.run("clearPage") }
            Button("이 문서 필기 전부 지우기", role: .destructive) { documents.run("clearDocument") }
        }
        if let leave { Button(action: leave) { Label("서재로", systemImage: "books.vertical") } }
    }

    // Unsent ink or a lost connection, like the dot on the web toolbar's ⋯.
    private var warnDot: some View {
        Circle().fill(.orange).frame(width: 8, height: 8).offset(x: -8, y: 8)
    }

    private func actionIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 18, weight: .medium))
            .frame(width: 44, height: 44).contentShape(Rectangle())
    }
}

private struct SwatchButton: View {
    let swatch: InkSwatch
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle().fill(swatch.color)
                .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                .frame(width: 24, height: 24)
                .overlay {
                    if selected {
                        Circle().stroke(.primary, lineWidth: 1.5).frame(width: 32, height: 32)
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(InkSwatch.isLight(swatch.rgb) ? .black : .white)
                    }
                }
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel(swatch.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("color.\(swatch.rgb)")
    }
}

private struct WidthButton: View {
    let width: Double
    let selected: Bool
    let highlighter: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Capsule().fill(.primary.opacity(highlighter ? 0.55 : 0.85))
                .frame(width: 22, height: highlighter ? width / 2 : width)
                .frame(width: 40, height: 40)
                .background(selected ? Color.primary.opacity(0.09) : .clear,
                            in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.primary.opacity(0.22) : .clear))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("굵기 \(width.formatted())포인트")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("width.\(Int(width))")
    }
}

private struct WritingToolOptions: View {
    @ObservedObject var model: PadModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label(model.tools.selected.title, systemImage: model.tools.selected.symbol).font(.headline)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }.accessibilityLabel("설정 닫기")
                }
                if model.tools.selected == .eraser {
                    Label("획 단위 지우개", systemImage: "checkmark.circle.fill").font(.subheadline.weight(.medium))
                    Text("선을 터치하면 한 획 전체가 지워집니다. 잘못 지웠다면 실행 취소로 되돌릴 수 있어요.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    if model.tools.selected == .pen {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("펜 종류").font(.subheadline.weight(.medium))
                            Picker("펜 종류", selection: $model.tools.penKind) {
                                ForEach(PenKind.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("penKind")
                        }
                    }
                    strokePreview
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("굵기").font(.subheadline.weight(.medium))
                            Spacer()
                            Text("\(model.tools.style.width.formatted()) pt")
                                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(get: { model.tools.style.width }, set: { model.tools.setWidth($0) }),
                               in: model.tools.selected.widthRange, step: 0.5)
                            .accessibilityLabel("필기 굵기")
                            .accessibilityValue("\(model.tools.style.width.formatted())포인트")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("색상").font(.subheadline.weight(.medium))
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 0), count: 6), spacing: 4) {
                            ForEach(InkSwatch.palette) { swatch in
                                SwatchButton(swatch: swatch, selected: model.tools.style.color == swatch.rgb) {
                                    model.tools.setColor(swatch.rgb)
                                }
                            }
                        }
                        ColorPicker("사용자 색상", selection: Binding(
                            get: { Color(UIColor(inkRGB: model.tools.style.color)) },
                            set: { model.tools.setColor(UIColor($0).inkRGB) }), supportsOpacity: false)
                            .font(.subheadline).frame(minHeight: 44)
                    }
                }
            }.padding(20)
        }
        .frame(width: 304, height: model.tools.selected == .eraser ? 220 : model.tools.selected == .pen ? 550 : 480)
        .presentationBackground(Color(UIColor.systemBackground))
        .buttonStyle(.plain)
    }

    private var strokePreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: InkSwatch.isLight(model.tools.style.color) ? 0.2 : 0.95))
            Path { path in
                path.move(to: CGPoint(x: 25, y: 45))
                path.addCurve(to: CGPoint(x: 235, y: 35),
                              control1: CGPoint(x: 95, y: -5), control2: CGPoint(x: 155, y: 90))
            }
            .stroke(Color(UIColor(inkRGB: model.tools.style.color))
                .opacity(model.tools.selected == .highlighter ? 0.45 : 1),
                    style: StrokeStyle(lineWidth: model.tools.style.width, lineCap: .round, lineJoin: .round))
        }.frame(height: 80)
            .accessibilityLabel("선 미리보기")
    }
}

/// The toolbar, or the small button that brings it back; the same in screen and document mode.
struct ToolbarDock: View {
    @ObservedObject var model: PadModel
    @ObservedObject var documents: DocumentSession
    var documentMode = false
    var leave: (() -> Void)?
    @Binding var clearConfirmation: Bool

    var body: some View {
        Group {
            if model.toolsVisible {
                WritingToolbar(model: model, documents: documents, documentMode: documentMode, leave: leave,
                               clearConfirmation: $clearConfirmation)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                Button { withAnimation(.snappy) { model.toolsVisible = true } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: model.tools.selected.symbol)
                            .foregroundStyle(model.tools.selected == .eraser ? Color.primary : Color(UIColor(inkRGB: model.tools.style.color)))
                        Text(model.tools.selected.title).font(.subheadline.weight(.medium))
                        Image(systemName: "chevron.up").font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 18).frame(minHeight: 48)
                    .inkGlass(Capsule())
                }.buttonStyle(.plain).accessibilityLabel("필기 도구 펼치기")
            }
        }.padding(.horizontal, 16).padding(.bottom, 16)
    }
}

/// Opens next to the pencil tip on squeeze: tools, the quick colors, widths, pen kind and undo.
struct PencilPalette: View {
    @ObservedObject var model: PadModel
    @ObservedObject var documents: DocumentSession
    let documentMode: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(WritingTool.allCases, id: \.self) { tool in
                    Button {
                        model.tools.select(tool)
                        withAnimation(.snappy(duration: 0.2)) { model.palettePoint = nil }
                    } label: {
                        Image(systemName: tool.symbol).font(.system(size: 20, weight: .medium))
                            .frame(width: 44, height: 44)
                            .background(model.tools.selected == tool ? Color.primary.opacity(0.1) : .clear,
                                        in: RoundedRectangle(cornerRadius: 12))
                            .contentShape(Rectangle())
                    }.accessibilityLabel(tool.title)
                }
                Spacer(minLength: 8)
                Button { documentMode ? documents.run("undo") : model.undo() } label: {
                    Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44).contentShape(Rectangle())
                }.disabled(!(documentMode ? documents.canUndo : model.canUndo)).accessibilityLabel("실행 취소")
                Button { documentMode ? documents.run("redo") : model.redo() } label: {
                    Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 44).contentShape(Rectangle())
                }.disabled(!(documentMode ? documents.canRedo : model.canRedo)).accessibilityLabel("다시 실행")
            }
            HStack(spacing: 0) {
                ForEach(InkSwatch.quick(current: model.tools.style.color)) { swatch in
                    SwatchButton(swatch: swatch, selected: model.tools.style.color == swatch.rgb) {
                        if model.tools.selected == .eraser { model.tools.toggleEraser() }
                        model.tools.setColor(swatch.rgb)
                    }
                }
            }
            HStack(spacing: 0) {
                ForEach(model.tools.inkTool.widths, id: \.self) { width in
                    WidthButton(width: width, selected: model.tools.style.width == width,
                                highlighter: model.tools.inkTool == .highlighter) {
                        if model.tools.selected == .eraser { model.tools.toggleEraser() }
                        model.tools.setWidth(width)
                    }
                }
                if model.tools.inkTool == .pen {
                    Picker("펜 종류", selection: $model.tools.penKind) {
                        ForEach(PenKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).padding(.leading, 8)
                }
            }
        }
        .padding(10)
        .inkGlass(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .buttonStyle(.plain)
    }
}
