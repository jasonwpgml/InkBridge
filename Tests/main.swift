import Foundation

var count = 0
func check(_ value: @autoclosure () -> Bool, _ description: String) {
    guard value() else { fatalError("FAIL: " + description) }
    count += 1
}

let original = WireMessage(kind: .ink, sequence: UInt64.max - 1, body: Data([0, 255, 16]))
let decoded = WireMessage(data: original.encoded())!
check(decoded.kind == .ink && decoded.sequence == original.sequence && decoded.body == original.body, "binary packet round trip preserves bytes and sequence")
check(WireMessage(data: Data([1, 3])) == nil, "truncated header rejected")
var invalidVersion = original.encoded(); invalidVersion[0] = 2
check(WireMessage(data: invalidVersion) == nil, "unknown protocol version rejected")
var invalidKind = original.encoded(); invalidKind[1] = 255
check(WireMessage(data: invalidKind) == nil, "unknown message kind rejected")
check(WireMessage(data: Data(repeating: 0, count: WireMessage.maximumBytes + 1)) == nil, "oversize packet rejected")

var flow = LatestUpdates()
let first = flow.submit(Data([1]), kind: .video)!
check(flow.submit(Data([2]), kind: .video) == nil, "no second frame before receipt")
check(flow.submit(Data([3]), kind: .video) == nil, "unsent frame replaced")
check(flow.acknowledge(first.sequence + 100, kind: .video) == nil, "unrelated ack does not release frame")
let latest = flow.acknowledge(first.sequence, kind: .video)!
check(latest.body == Data([3]), "latest frame sent after ack, not stale queued frame")
check(flow.acknowledge(first.sequence, kind: .video) == nil, "duplicate ack does not release newer frame")
let ink = flow.submit(Data([4]), kind: .ink)
check(ink != nil, "ink can travel while video awaits acknowledgement")
check(flow.acknowledge(latest.sequence, kind: .video) == nil && flow.outstanding[.video] == nil, "ack with no pending frame leaves channel idle")

let geometry = ScreenGeometry(sourceID: "test-display", name: "Display", width: 1600, height: 1000)
check(geometry.isValid, "normal screen geometry accepted")
check(!ScreenGeometry(sourceID: "display", name: "", width: .nan, height: 1000).isValid, "nonfinite geometry rejected")
check(!ScreenGeometry(sourceID: "", name: "", width: 1600, height: 0).isValid, "invalid source and dimensions rejected")
let live = LiveStroke(points: [InkPoint(x: 10, y: 20)], red: 0, green: 0.5, blue: 1, alpha: 1, width: 4)
check(live.isValid, "valid preview accepted")
var badLive = live; badLive.points = [InkPoint(x: .infinity, y: 0)]
check(!badLive.isValid, "invalid preview coordinate rejected")
let update = InkUpdate(sourceID: geometry.sourceID, revision: 5, drawing: Data([8, 9]), preview: live)
let restored = try JSONDecoder().decode(InkUpdate.self, from: JSONEncoder().encode(update))
check(restored.sourceID == geometry.sourceID && restored.preview?.points.first?.y == 20 && restored.drawing == update.drawing, "ink state round trip")
let previewOnly = InkUpdate(sourceID: geometry.sourceID, revision: 6, drawing: nil, preview: live)
let restoredPreview = try JSONDecoder().decode(InkUpdate.self, from: JSONEncoder().encode(previewOnly))
check(restoredPreview.isValid && restoredPreview.drawing == nil && restoredPreview.preview?.points.count == 1, "preview-only ink update keeps the receiver's drawing")
check(!InkUpdate(sourceID: geometry.sourceID, revision: 7, drawing: Data(count: 16 * 1024 * 1024 + 1), preview: nil).isValid, "oversize drawing rejected")
var writing = WritingTools()
writing.setColor(0xE65353)
writing.setWidth(2)
writing.select(.highlighter)
check(writing.style.color == 0xF5CC38 && writing.style.width == 16, "highlighter starts with its own yellow ink and broad width")
writing.setColor(0x279D79)
writing.setWidth(28)
writing.select(.pen)
check(writing.style.color == 0xE65353 && writing.style.width == 2, "switching to pen restores its color and width")
writing.select(.highlighter)
writing.toggleEraser()
writing.setColor(0xFFFFFF)
writing.setWidth(8)
writing.toggleEraser()
check(writing.selected == .highlighter && writing.style == InkStyle(color: 0x279D79, width: 28), "eraser returns to the last ink tool without changing its style")
writing.select(.pen)
writing.toggleEraser()
writing.toggleEraser()
check(writing.selected == .pen && writing.style.width == 2, "Pencil eraser toggle restores pen too")
writing.setWidth(100)
check(writing.style.width == 12, "pen width stays within the supported range")
writing.setWidth(.nan)
check(writing.style.width == 12, "nonfinite width cannot enter saved preferences")
writing.fingerDrawing = true
writing.select(.eraser)
let restoredTools = try JSONDecoder().decode(WritingTools.self, from: JSONEncoder().encode(writing))
check(restoredTools == writing, "relaunch preserves both ink styles, input mode, and the eraser return tool")
check(WritingTools().penKind == .gel, "new installs keep the existing gel pen")
writing.penKind = .fountain
let restoredKind = try JSONDecoder().decode(WritingTools.self, from: JSONEncoder().encode(writing))
check(restoredKind.penKind == .fountain, "relaunch preserves the pen kind")
let legacy = Data(#"{"selected":"pen","previousInk":"pen","pen":{"color":15094611,"width":2},"highlighter":{"color":2596217,"width":28},"fingerDrawing":true}"#.utf8)
let legacyTools = try JSONDecoder().decode(WritingTools.self, from: legacy)
check(legacyTools.penKind == .gel && legacyTools.style == InkStyle(color: 0xE65353, width: 2) && legacyTools.fingerDrawing,
      "settings saved before pen kinds keep their styles and use the gel pen")
print("InkBridge: \(count) checks passed")
