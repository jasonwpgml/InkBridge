import Foundation

enum WritingTool: String, CaseIterable, Codable {
    case pen, highlighter, eraser

    var title: String {
        switch self {
        case .pen: return "펜"
        case .highlighter: return "형광펜"
        case .eraser: return "지우개"
        }
    }

    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        }
    }

    var widths: [Double] { self == .highlighter ? [8, 16, 28] : [2, 4, 8] }
    var widthRange: ClosedRange<Double> { self == .highlighter ? 6...36 : 1...12 }
}

enum PenKind: String, CaseIterable, Codable {
    case gel, ballpoint, fountain

    var title: String {
        switch self {
        case .gel: return "젤펜"
        case .ballpoint: return "볼펜"
        case .fountain: return "만년필"
        }
    }
}

struct InkStyle: Codable, Equatable {
    var color: UInt32
    var width: Double
}

struct WritingTools: Codable, Equatable {
    private(set) var selected: WritingTool = .pen
    private(set) var previousInk: WritingTool = .pen
    private(set) var pen = InkStyle(color: 0x2878EB, width: 4)
    private(set) var highlighter = InkStyle(color: 0xF5CC38, width: 16)
    var penKind: PenKind = .gel
    var fingerDrawing = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case selected, previousInk, pen, highlighter, penKind, fingerDrawing
    }

    // Settings saved before pen kinds existed have no penKind and keep the gel pen.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        selected = try values.decode(WritingTool.self, forKey: .selected)
        previousInk = try values.decode(WritingTool.self, forKey: .previousInk)
        pen = try values.decode(InkStyle.self, forKey: .pen)
        highlighter = try values.decode(InkStyle.self, forKey: .highlighter)
        penKind = try values.decodeIfPresent(PenKind.self, forKey: .penKind) ?? .gel
        fingerDrawing = try values.decode(Bool.self, forKey: .fingerDrawing)
    }

    var inkTool: WritingTool { selected == .eraser ? previousInk : selected }
    var style: InkStyle { inkTool == .highlighter ? highlighter : pen }

    mutating func select(_ tool: WritingTool) {
        if tool != .eraser { previousInk = tool }
        selected = tool
    }

    mutating func toggleEraser() {
        select(selected == .eraser ? previousInk : .eraser)
    }

    mutating func setColor(_ color: UInt32) {
        guard selected != .eraser else { return }
        if selected == .highlighter { highlighter.color = color }
        else { pen.color = color }
    }

    mutating func setWidth(_ width: Double) {
        guard selected != .eraser, width.isFinite else { return }
        let clamped = min(max(width, selected.widthRange.lowerBound), selected.widthRange.upperBound)
        if selected == .highlighter { highlighter.width = clamped }
        else { pen.width = clamped }
    }
}
