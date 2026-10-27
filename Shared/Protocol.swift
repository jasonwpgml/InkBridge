import Foundation

enum MessageKind: UInt8, Hashable {
    case geometry = 1, video, ink, acknowledgement, stopped
}

struct WireMessage {
    static let maximumBytes = 24 * 1024 * 1024
    let kind: MessageKind
    let sequence: UInt64
    let body: Data

    func encoded() -> Data {
        var data = Data([1, kind.rawValue])
        var number = sequence.bigEndian
        withUnsafeBytes(of: &number) { data.append(contentsOf: $0) }
        data.append(body)
        return data
    }

    init(kind: MessageKind, sequence: UInt64 = 0, body: Data = Data()) {
        self.kind = kind; self.sequence = sequence; self.body = body
    }

    init?(data: Data) {
        guard data.count >= 10, data.count <= Self.maximumBytes,
              data[data.startIndex] == 1,
              let kind = MessageKind(rawValue: data[data.startIndex + 1]) else { return nil }
        self.kind = kind
        sequence = data.dropFirst(2).prefix(8).reduce(0) { ($0 << 8) | UInt64($1) }
        body = Data(data.dropFirst(10))
    }
}

struct ScreenGeometry: Codable, Equatable {
    let sourceID: String
    let name: String
    let width: Double
    let height: Double

    var isValid: Bool {
        !sourceID.isEmpty && sourceID.count < 200 && width.isFinite && height.isFinite &&
        width >= 100 && height >= 100 && width <= 4096 && height <= 4096
    }
}

struct ScreenFrame: Codable {
    let sourceID: String
    let jpeg: Data
}

struct InkPoint: Codable {
    let x: Double
    let y: Double
}

struct LiveStroke: Codable {
    var points: [InkPoint]
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double
    let width: Double

    var isValid: Bool {
        points.count <= 16384 && [red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) } &&
        width.isFinite && (0.1...200).contains(width) &&
        points.allSatisfy { $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 8192 && abs($0.y) <= 8192 }
    }
}

// A nil drawing means the receiver keeps the drawing it already has.
// The sender omits it only after an update carrying that drawing has been transmitted.
struct InkUpdate: Codable {
    let sourceID: String
    let revision: UInt64
    let drawing: Data?
    let preview: LiveStroke?

    var isValid: Bool {
        (drawing?.count ?? 0) <= 16 * 1024 * 1024 && (preview?.isValid ?? true)
    }
}

// Each direction keeps one outstanding update and replaces only unsent updates.
// JPEG frames and complete ink states are independent, so replacement is lossless.
// An ink update without its drawing is only lossless once the drawing has left the queue.
struct LatestUpdates {
    private(set) var outstanding: [MessageKind: UInt64] = [:]
    private var pending: [MessageKind: Data] = [:]
    private var sequence: UInt64 = 0

    mutating func submit(_ body: Data, kind: MessageKind) -> WireMessage? {
        pending[kind] = body
        return next(kind)
    }

    mutating func acknowledge(_ sequence: UInt64, kind: MessageKind) -> WireMessage? {
        guard outstanding[kind] == sequence else { return nil }
        outstanding[kind] = nil
        return next(kind)
    }

    private mutating func next(_ kind: MessageKind) -> WireMessage? {
        guard outstanding[kind] == nil, let body = pending.removeValue(forKey: kind) else { return nil }
        sequence += 1
        outstanding[kind] = sequence
        return WireMessage(kind: kind, sequence: sequence, body: body)
    }
}
