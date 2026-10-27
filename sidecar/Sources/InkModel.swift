import Foundation

enum InkTool: String, Codable {
    case pen, highlighter, arrow, eraser
}

enum EraserMode: Int { case partial, stroke }

struct InkErasure: Codable, Equatable {
    var id: UUID
    var radius: Double
    var points: [InkPoint]
}

struct InkPoint: Codable, Equatable {
    var x: Double
    var y: Double

    static func curve(from start: InkPoint, control: InkPoint, to end: InkPoint) -> [InkPoint] {
        // Rendering and eraser hits use the same curvature-based subdivision.
        let curvature = hypot(start.x - 2 * control.x + end.x, start.y - 2 * control.y + end.y)
        let steps = max(1, min(256, Int(ceil(sqrt(curvature)))))
        return (1...steps).map { step in
            let t = Double(step) / Double(steps), u = 1 - t
            return InkPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                            y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
        }
    }
}

struct InkColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
}

struct InkToolStyle: Codable, Equatable {
    var color: InkColor
    var width: Double
}

struct InkToolSettings: Codable, Equatable {
    private var pen = InkToolStyle(color: InkColor(red: 0.12, green: 0.36, blue: 0.85), width: 4)
    private var highlighter = InkToolStyle(color: InkColor(red: 0.98, green: 0.77, blue: 0.12), width: 4)
    private var arrow = InkToolStyle(color: InkColor(red: 0.88, green: 0.16, blue: 0.23), width: 4)

    subscript(tool: InkTool) -> InkToolStyle {
        get {
            switch tool {
            case .highlighter: return highlighter
            case .arrow: return arrow
            case .pen, .eraser: return pen
            }
        }
        set {
            switch tool {
            case .pen: pen = newValue
            case .highlighter: highlighter = newValue
            case .arrow: arrow = newValue
            case .eraser: break
            }
        }
    }
}

struct InkStroke: Codable, Equatable {
    var id: UUID = UUID()
    var tool: InkTool
    var color: InkColor
    var width: Double
    var points: [InkPoint]
    var erasures: [InkErasure]?

    func pathPoints(width: Double, height: Double) -> [InkPoint] {
        let vertices = points.map { InkPoint(x: $0.x * width, y: $0.y * height) }
        guard tool != .arrow, vertices.count > 2 else { return vertices }
        var result = [vertices[0]]
        for index in 1..<(vertices.count - 1) {
            let start = result[result.count - 1], control = vertices[index], next = vertices[index + 1]
            let end = InkPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2)
            result.append(contentsOf: InkPoint.curve(from: start, control: control, to: end))
        }
        result.append(vertices[vertices.count - 1])
        return result
    }
}

final class InkDocument {
    private struct FileContents: Codable {
        var version: Int
        var strokes: [InkStroke]
    }

    enum FileError: Error, LocalizedError {
        case tooLarge
        case unsupportedVersion
        case invalidStroke

        var errorDescription: String? {
            switch self {
            case .tooLarge: return "이 필기 파일은 허용된 크기를 초과합니다."
            case .unsupportedVersion: return "지원하지 않는 필기 파일 버전입니다."
            case .invalidStroke: return "필기 파일의 좌표, 색상 또는 선 정보가 올바르지 않습니다."
            }
        }
    }

    private enum Edit {
        case add(InkStroke)
        case replace(before: [InkStroke], after: [InkStroke])
    }

    private static let maximumStrokes = 4_096
    private static let maximumPointsPerStroke = 20_000
    private static let maximumTotalPoints = 250_000
    private static let maximumFileBytes = 16 * 1_024 * 1_024
    private static let maximumHistory = 100

    private(set) var strokes: [InkStroke] = []
    private var undoHistory: [Edit] = []
    private var redoHistory: [Edit] = []
    private var eraseStart: [InkStroke]?
    private var eraseID = UUID()
    private var eraseChanged = false

    var canUndo: Bool { !undoHistory.isEmpty || eraseChanged }
    var canRedo: Bool { !redoHistory.isEmpty && !eraseChanged }

    @discardableResult func add(_ stroke: InkStroke) -> Bool {
        endErase()
        guard Self.isValid(stroke), strokes.count < Self.maximumStrokes,
              !strokes.contains(where: { $0.id == stroke.id }),
              strokes.reduce(Self.pointCount(stroke), { $0 + Self.pointCount($1) }) <= Self.maximumTotalPoints
        else { return false }
        strokes.append(stroke)
        record(.add(stroke))
        return true
    }

    func beginErase() {
        if eraseStart == nil { eraseStart = strokes; eraseID = UUID(); eraseChanged = false }
    }

    @discardableResult func erase(at point: InkPoint, from previous: InkPoint? = nil, canvasWidth: Double, canvasHeight: Double,
                                 radius: Double, mode: EraserMode = .stroke) -> Bool {
        let previous = previous ?? point
        guard Self.unit(point.x), Self.unit(point.y), Self.unit(previous.x), Self.unit(previous.y),
              canvasWidth.isFinite, canvasWidth > 0,
              canvasHeight.isFinite, canvasHeight > 0,
              radius.isFinite, radius >= 0, radius <= 128 else { return false }

        let grouped = eraseStart != nil
        if !grouped { beginErase() }
        let pixelPoint = InkPoint(x: point.x * canvasWidth, y: point.y * canvasHeight)
        let pixelStart = InkPoint(x: previous.x * canvasWidth, y: previous.y * canvasHeight)
        var changed = false
        if mode == .stroke {
            let count = strokes.count
            strokes.removeAll { stroke in
                Self.hits(stroke, from: pixelStart, to: pixelPoint, width: canvasWidth, height: canvasHeight, radius: radius)
            }
            changed = count != strokes.count
        } else if radius > 0 {
            var remaining = Self.maximumTotalPoints - strokes.reduce(0) { $0 + Self.pointCount($1) }
            for index in strokes.indices {
                let continuing = strokes[index].erasures?.last?.id == eraseID
                if continuing {
                    let last = strokes[index].erasures!.count - 1
                    guard remaining > 0, strokes[index].erasures![last].points.count < Self.maximumPointsPerStroke,
                          strokes[index].erasures![last].points.last != point else { continue }
                    strokes[index].erasures![last].points.append(point)
                    remaining -= 1; changed = true
                } else if Self.hits(strokes[index], from: pixelStart, to: pixelPoint,
                                    width: canvasWidth, height: canvasHeight, radius: radius) {
                    let points = previous == point ? [point] : [previous, point]
                    guard remaining >= points.count else { continue }
                    if strokes[index].erasures == nil { strokes[index].erasures = [] }
                    strokes[index].erasures!.append(InkErasure(id: eraseID, radius: radius, points: points))
                    remaining -= points.count; changed = true
                }
            }
        }
        eraseChanged = eraseChanged || changed
        if !grouped { endErase() }
        return changed
    }

    func endErase() {
        guard let initial = eraseStart else { return }
        eraseStart = nil
        guard eraseChanged else { return }
        eraseChanged = false
        record(.replace(before: initial, after: strokes))
    }

    func clear() {
        endErase()
        guard !strokes.isEmpty else { return }
        let before = strokes
        strokes.removeAll()
        record(.replace(before: before, after: []))
    }

    func undo() {
        endErase()
        guard let edit = undoHistory.popLast() else { return }
        switch edit {
        case .add:
            strokes.removeLast()
        case .replace(let before, _): strokes = before
        }
        redoHistory.append(edit)
    }

    func redo() {
        endErase()
        guard let edit = redoHistory.popLast() else { return }
        switch edit {
        case .add(let stroke):
            strokes.append(stroke)
        case .replace(_, let after): strokes = after
        }
        undoHistory.append(edit)
    }

    func replace(with strokes: [InkStroke]) {
        guard (try? Self.validate(strokes)) != nil else { return }
        eraseStart = nil
        eraseChanged = false
        self.strokes = strokes
        undoHistory.removeAll()
        redoHistory.removeAll()
    }

    func encoded() throws -> Data {
        try Self.validate(strokes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let version = strokes.contains { !($0.erasures ?? []).isEmpty } ? 2 : 1
        let data = try encoder.encode(FileContents(version: version, strokes: strokes))
        guard data.count <= Self.maximumFileBytes else { throw FileError.tooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> [InkStroke] {
        guard data.count <= maximumFileBytes else { throw FileError.tooLarge }
        let file = try JSONDecoder().decode(FileContents.self, from: data)
        guard file.version == 1 || file.version == 2 else { throw FileError.unsupportedVersion }
        try validate(file.strokes)
        return file.strokes
    }

    private func record(_ edit: Edit) {
        undoHistory.append(edit)
        if undoHistory.count > Self.maximumHistory { undoHistory.removeFirst() }
        redoHistory.removeAll()
    }

    private static func validate(_ strokes: [InkStroke]) throws {
        guard strokes.count <= maximumStrokes else { throw FileError.tooLarge }
        var total = 0
        var ids = Set<UUID>()
        for stroke in strokes {
            total += pointCount(stroke)
            guard stroke.points.count <= maximumPointsPerStroke, total <= maximumTotalPoints
            else { throw FileError.tooLarge }
            guard isValid(stroke), ids.insert(stroke.id).inserted else { throw FileError.invalidStroke }
        }
    }

    private static func isValid(_ stroke: InkStroke) -> Bool {
        stroke.tool != .eraser && stroke.width.isFinite && stroke.width > 0 && stroke.width <= 128
            && unit(stroke.color.red) && unit(stroke.color.green) && unit(stroke.color.blue)
            && !stroke.points.isEmpty && stroke.points.count <= maximumPointsPerStroke
            && stroke.points.allSatisfy { unit($0.x) && unit($0.y) }
            && (stroke.erasures ?? []).allSatisfy {
                $0.radius.isFinite && $0.radius > 0 && $0.radius <= 128
                    && !$0.points.isEmpty && $0.points.count <= maximumPointsPerStroke
                    && $0.points.allSatisfy { unit($0.x) && unit($0.y) }
            }
    }

    private static func pointCount(_ stroke: InkStroke) -> Int {
        stroke.points.count + (stroke.erasures ?? []).reduce(0) { $0 + $1.points.count }
    }

    private static func unit(_ value: Double) -> Bool { value.isFinite && (0...1).contains(value) }

    private static func hits(_ stroke: InkStroke, from start: InkPoint, to end: InkPoint,
                             width: Double, height: Double, radius: Double) -> Bool {
        let threshold = radius + stroke.width / 2
        let vertices = stroke.pathPoints(width: width, height: height)
        let masks = (stroke.erasures ?? []).map { erasure in
            (margin: erasure.radius - stroke.width / 2,
             points: erasure.points.map { InkPoint(x: $0.x * width, y: $0.y * height) })
        }
        func intersects(_ a: InkPoint, _ b: InkPoint) -> Bool {
            let dx = end.x - start.x, dy = end.y - start.y
            let ex = b.x - a.x, ey = b.y - a.y
            let cross = dx * ey - dy * ex
            if abs(cross) > 1e-10 {
                let t = ((a.x - start.x) * ey - (a.y - start.y) * ex) / cross
                let u = ((a.x - start.x) * dy - (a.y - start.y) * dx) / cross
                if (0...1).contains(t) && (0...1).contains(u) { return true }
            }
            return min(distance(start, a, b), distance(end, a, b),
                       distance(a, start, end), distance(b, start, end)) <= threshold
        }
        func hitsVisibleInk(_ a: InkPoint, _ b: InkPoint) -> Bool {
            guard intersects(a, b) else { return false }
            guard !masks.isEmpty else { return true }
            let steps = max(1, Int(ceil(hypot(b.x - a.x, b.y - a.y))))
            for step in 0...steps {
                let t = Double(step) / Double(steps)
                let p = InkPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y))
                guard distance(p, start, end) <= threshold else { continue }
                let removed = masks.contains { mask in
                    guard mask.margin >= 0 else { return false }
                    if mask.points.count == 1 { return distance(p, mask.points[0], mask.points[0]) <= mask.margin }
                    return (1..<mask.points.count).contains {
                        distance(p, mask.points[$0 - 1], mask.points[$0]) <= mask.margin
                    }
                }
                if !removed { return true }
            }
            return false
        }
        if vertices.count == 1 { return hitsVisibleInk(vertices[0], vertices[0]) }
        for index in 1..<vertices.count {
            if hitsVisibleInk(vertices[index - 1], vertices[index]) { return true }
        }
        if stroke.tool == .arrow, let start = vertices.first, let end = vertices.last {
            let angle = atan2(end.y - start.y, end.x - start.x)
            let length = max(12, stroke.width * 4)
            for offset in [-Double.pi / 6, Double.pi / 6] {
                let wing = InkPoint(x: end.x - length * cos(angle + offset), y: end.y - length * sin(angle + offset))
                if hitsVisibleInk(end, wing) { return true }
            }
        }
        return false
    }

    private static func distance(_ point: InkPoint, _ start: InkPoint, _ end: InkPoint) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        let fraction = lengthSquared == 0 ? 0 : max(0, min(1,
            ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        return hypot(point.x - (start.x + fraction * dx), point.y - (start.y + fraction * dy))
    }
}
